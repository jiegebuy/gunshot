#import <Foundation/Foundation.h>
#include <assert.h>
// Only replace the bundle and UIKit environment. The manager implementation,
// epoch checks, scheduler callbacks and progress/completion logic run unchanged.
@interface GSFixtureBundle : NSObject
+ (instancetype)mainBundle;
@property(readonly) NSString *bundleIdentifier;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
#define NSBundle GSFixtureBundle
#import "../UI/GSBackgroundUpload.m"
#undef NSBundle
static BOOL Configured=YES,Reject=NO,NoTime=NO;
static void (^Launch)(id<GSContinuedTask>);
static void (^ShortExpiration)(void);
static NSDictionary *Batch,*Summary;
static NSUInteger Stops,ShortEnds,RequestCancels,RealNext;
static NSMutableDictionary *RealTasks; // UIKit ID -> expiration handler
static BOOL SealDuringSummary;
@implementation GSFixtureBundle
+ (instancetype)mainBundle{return [self new];}
- (NSString *)bundleIdentifier{return @"dev.fixture";}
- (id)objectForInfoDictionaryKey:(NSString *)key{return Configured?@[@"dev.fixture.gotohp.upload.*"]:@[];}
@end
@implementation UIApplication
+ (instancetype)sharedApplication{static id app;static dispatch_once_t once;dispatch_once(&once,^{app=[self new];});return app;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler{ShortExpiration=[handler copy];return 1;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler{
 if(NoTime)return UIBackgroundTaskInvalid;
 UIBackgroundTaskIdentifier task=100+(++RealNext);RealTasks[@(task)]=handler?[handler copy]:NSNull.null;return task;
}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier{ShortEnds++;[RealTasks removeObjectForKey:@(identifier)];}
@end
@interface BGContinuedProcessingTaskRequest : NSObject <GSContinuedRequest> @end
@implementation BGContinuedProcessingTaskRequest
- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title subtitle:(NSString *)subtitle{return [super init];}
@end
@interface BGTaskScheduler : NSObject @end
@implementation BGTaskScheduler
+ (id)sharedScheduler{return [self new];}
- (BOOL)registerForTaskWithIdentifier:(NSString *)identifier usingQueue:(dispatch_queue_t)queue launchHandler:(void (^)(id<GSContinuedTask>))handler{Launch=[handler copy];return YES;}
- (BOOL)submitTaskRequest:(id)request error:(NSError **)error{if(Reject&&error)*error=[NSError errorWithDomain:@"BGTaskSchedulerErrorDomain" code:1 userInfo:nil];return !Reject;}
- (void)cancelTaskRequestWithIdentifier:(NSString *)identifier{RequestCancels++;}
@end
@interface FixtureTask : NSObject <GSContinuedTask>
@property(copy) void (^expirationHandler)(void);
@property(strong) NSProgress *progress;
@property NSUInteger completions;
@property BOOL success;
@end
@implementation FixtureTask
- (instancetype)init{if((self=[super init]))_progress=[NSProgress progressWithTotalUnitCount:1];return self;}
- (void)setTaskCompletedWithSuccess:(BOOL)success{self.completions++;self.success=success;}
- (void)updateTitle:(NSString *)title subtitle:(NSString *)subtitle{}
@end
NSDictionary *GSRequest(NSDictionary *request,NSError **error){
 if(SealDuringSummary){SealDuringSummary=NO;Batch=@{@"active":@NO,@"stage":@"finished",@"processed":@10,@"failed":@0};}
 return Summary;
}
NSDictionary *GSBatchImportSnapshot(void){return Batch;}
void GSStopBatchImport(BOOL expired){assert(expired);Stops++;}
static void Drain(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:0.1];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];}
static void Wait(NSTimeInterval seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];}
static void Foreground(void){[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];Drain();}
static void SetWork(BOOL active,NSUInteger pending){
 Batch=@{@"active":@(active),@"stage":active?@"exporting":@"finished",@"processed":active?@1:@10,@"failed":@0};
 Summary=@{@"profiles":@{@"original":@{@"states":@{@"pending":@(pending)}}},@"conditions":@{@"paused":@NO}};
}
int main(void){@autoreleasepool{
 RealTasks=[NSMutableDictionary dictionary];UIApplication *app=UIApplication.sharedApplication;
 SetWork(YES,2);GSBeginBackgroundUpload(10);assert([GSBackgroundUploadSnapshot()[@"status"]isEqual:@"requested"]);
 assert(![GSBackgroundUploadSnapshot()[@"granted"]boolValue]);
 FixtureTask *first=[FixtureTask new];Launch(first);Drain();assert([GSBackgroundUploadSnapshot()[@"granted"]boolValue]&&ShortEnds==1);
 // During the grant, host tasks are accounted locally and never reach UIKit.
 __block NSUInteger hostExpired=0;
 UIBackgroundTaskIdentifier ended=[app beginBackgroundTaskWithName:@"ended" expirationHandler:^{hostExpired++;}];
 UIBackgroundTaskIdentifier open=[app beginBackgroundTaskWithExpirationHandler:nil];
 __block UIBackgroundTaskIdentifier expiring=UIBackgroundTaskInvalid;
 expiring=[app beginBackgroundTaskWithName:@"expiring" expirationHandler:^{hostExpired++;[app endBackgroundTask:expiring];}];
 assert(ended>=GSDeferredBase&&open>=GSDeferredBase&&expiring>=GSDeferredBase&&!RealNext);
 [app endBackgroundTask:ended];[app endBackgroundTask:ended];assert(ShortEnds==1); // Local and stale ends stay local.
 assert([GSBackgroundUploadSnapshot()[@"deferredTasks"]isEqual:(@{@"begun":@3,@"open":@2,@"handedBack":@0,@"handedBackOpen":@0})]);
 // Moving bytes advance progress even while item counts stand still; idleness does not.
 Summary=@{@"profiles":@{@"original":@{@"states":@{@"pending":@2}}},@"conditions":@{@"paused":@NO},@"transport":@{@"recentUploadBodyBytesPerSecond":@4096}};
 GSPollBackground();Drain();int64_t moving=first.progress.completedUnitCount;
 GSPollBackground();Drain();assert(first.progress.completedUnitCount==moving+1);
 SetWork(YES,2);GSPollBackground();Drain();GSPollBackground();Drain();assert(first.progress.completedUnitCount==moving+1);
 SetWork(YES,0);SealDuringSummary=YES;GSPollBackground();Drain();assert(first.completions==0); // Final seal racing a summary cannot complete the task.
 SetWork(NO,2);GSPollBackground();Drain();assert(first.completions==0); // Prepared is not uploaded.
 Batch=@{@"active":@NO,@"stage":@"stopped",@"stopReason":@"queue_rejected",@"processed":@5};
 GSPollBackground();Drain();assert(first.completions==0); // One preparation failure must not abandon already queued uploads.
 SetWork(NO,0);GSPollBackground();Drain();assert(first.completions==1&&first.success&&first.progress.fractionCompleted==1);
 assert(![GSBackgroundUploadSnapshot()[@"granted"]boolValue]);
 // Ending the grant hands still-open host tasks back to UIKit, which again owns their expiry.
 assert(RealNext==2&&RealTasks.count==2&&hostExpired==0);
 NSUInteger ends=ShortEnds;[app endBackgroundTask:open];assert(ShortEnds==ends+1&&RealTasks.count==1);
 [app endBackgroundTask:open];assert(ShortEnds==ends+1); // A repeated end is not forwarded.
 void (^expire)(void)=RealTasks.allValues.firstObject;expire();assert(hostExpired==1&&RealTasks.count==0&&ShortEnds==ends+2);
 Foreground();
 UIBackgroundTaskIdentifier after=[app beginBackgroundTaskWithName:@"after" expirationHandler:nil];assert(after==100+RealNext); // Outside a grant: plain UIKit.
 [app endBackgroundTask:after];
 // With no background time left, a deferred task expires as UIKit would have expired it.
 SetWork(YES,1);GSBeginBackgroundUpload(10);FixtureTask *spent=[FixtureTask new];Launch(spent);Drain();
 [app beginBackgroundTaskWithName:@"late" expirationHandler:^{hostExpired++;}];
 NoTime=YES;GSFinishBackground(NO,@"test_end");Drain();NoTime=NO;assert(hostExpired==2&&spent.completions==1);
 SetWork(YES,1);GSBeginBackgroundUpload(10);FixtureTask *second=[FixtureTask new];Launch(second);Drain();
 NSUInteger beforeExpiry=RealNext;
 for(NSUInteger i=0;i<600;i++)[app beginBackgroundTaskWithName:@"deferred-at-expiry" expirationHandler:nil];
 second.expirationHandler();Drain();assert(Stops==1&&second.completions==1&&!second.success);
 assert(RealNext==beforeExpiry); // Expired grants must not hand back fresh UIKit assertions.
 assert(![GSBackgroundUploadSnapshot()[@"granted"]boolValue]);
 Foreground();
 GSBeginBackgroundUpload(10);void (^late)(id<GSContinuedTask>)=[Launch copy];
 GSBeginBackgroundUpload(10);FixtureTask *stale=[FixtureTask new];late(stale);assert(stale.completions==1&&!stale.success&&!GSTask);
 ShortExpiration();assert(Stops==2&&[GSBackgroundUploadSnapshot()[@"status"]isEqual:@"expired"]);
 Reject=YES;GSBeginBackgroundUpload(10);assert([GSBackgroundUploadSnapshot()[@"status"]isEqual:@"rejected"]);
 assert(![GSBackgroundUploadSnapshot()[@"granted"]boolValue]);GSFinishBackground(NO,@"test_end");
 Configured=NO;GSBeginBackgroundUpload(10);assert([GSBackgroundUploadSnapshot()[@"status"]isEqual:@"foreground_only"]);GSFinishBackground(NO,@"test_end");
 // Expiry cleanup must finish synchronously: UIKit may suspend the process as
 // soon as the handler returns. Reentrant begin attempts must not create a new
 // assertion (the device's 0x2182BAD2 termination left assertion 543 alive).
 Foreground();
 __block NSUInteger ignored=0;
 UIBackgroundTaskIdentifier sibling=[app beginBackgroundTaskWithName:@"sibling" expirationHandler:nil];
 __block UIBackgroundTaskIdentifier reentrant=0;
 UIBackgroundTaskIdentifier stuck=[app beginBackgroundTaskWithName:@"stuck" expirationHandler:^{ignored++;reentrant=[app beginBackgroundTaskWithName:@"retry-from-expiry" expirationHandler:^{ignored++;}];}];
 void (^uikitExpiry)(void)=RealTasks[@(stuck)];uikitExpiry();
 assert(ignored==1&&!RealTasks[@(stuck)]&&!RealTasks[@(sibling)]&&reentrant==UIBackgroundTaskInvalid);
 NSUInteger beforeLate=RealNext;
 UIBackgroundTaskIdentifier spentTask=[app beginBackgroundTaskWithName:@"spent" expirationHandler:nil];
 assert(spentTask==UIBackgroundTaskInvalid&&RealNext==beforeLate);
 for(NSUInteger i=0;i<600;i++)assert([app beginBackgroundTaskWithExpirationHandler:^{ignored++;}]==UIBackgroundTaskInvalid);
 assert(RealNext==beforeLate&&ignored==1); // Rejected begins never schedule expiration callbacks.
 NSUInteger forced=ShortEnds;[app endBackgroundTask:stuck];assert(ShortEnds==forced);
 NSDictionary *guard=GSBackgroundUploadSnapshot()[@"expiryGuard"];
 assert([guard[@"forcedEnds"]unsignedIntegerValue]>=2&&[guard[@"lateExpired"]unsignedIntegerValue]>=1&&[guard[@"rejectedLate"]unsignedIntegerValue]>=602&&[guard[@"forcedCallers"]count]>=1);
 // Returning to the foreground closes the expiry window for new tasks.
 Foreground();
 UIBackgroundTaskIdentifier fresh=[app beginBackgroundTaskWithName:@"fresh" expirationHandler:nil];Wait(2.5);assert(RealTasks[@(fresh)]);
 [app endBackgroundTask:fresh];assert(!RealTasks[@(fresh)]);
 NSLog(@"PASS background grant, queue drain, expiration, rejection, fallback, stale handler isolation, host task deferral, progress heartbeat and expiry guard");
}}
