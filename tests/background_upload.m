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
static dispatch_semaphore_t SummaryStarted,SummaryRelease;
static NSUInteger Stops,ShortEnds,RequestCancels,RealNext,ShortNext;
static NSMutableDictionary *RealTasks; // UIKit ID -> expiration handler
static NSObject *RealLock;
static BOOL SealDuringSummary,InvalidBegin;
static void (^BeginHook)(NSString *,UIBackgroundTaskIdentifier,void (^)(void));
static void Await(dispatch_semaphore_t signal){assert(dispatch_semaphore_wait(signal,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);}
static NSUInteger RawCount(void){@synchronized(RealLock){return RealTasks.count;}}
static BOOL RawOpen(UIBackgroundTaskIdentifier task){@synchronized(RealLock){return RealTasks[@(task)]!=nil;}}
static void (^RawExpiration(UIBackgroundTaskIdentifier task))(void){@synchronized(RealLock){return RealTasks[@(task)];}}
static UIBackgroundTaskIdentifier FixtureBegin(BOOL named,NSString *name,void (^handler)(void)){
 UIBackgroundTaskIdentifier task;void (^hook)(NSString *,UIBackgroundTaskIdentifier,void (^)(void));
 @synchronized(RealLock){
  if(NoTime)return UIBackgroundTaskInvalid;
  task=InvalidBegin?UIBackgroundTaskInvalid:(named?100+(++RealNext):1000000+(++ShortNext));
  if(task!=UIBackgroundTaskInvalid)RealTasks[@(task)]=handler?[handler copy]:NSNull.null;
  if(!named)ShortExpiration=[handler copy];
  hook=[BeginHook copy];
 }
 if(hook)hook(name,task,handler);
 return task;
}
@implementation GSFixtureBundle
+ (instancetype)mainBundle{return [self new];}
- (NSString *)bundleIdentifier{return @"dev.fixture";}
- (id)objectForInfoDictionaryKey:(NSString *)key{return Configured?@[@"dev.fixture.gotohp.upload.*"]:@[];}
@end
@implementation UIApplication
+ (instancetype)sharedApplication{static id app;static dispatch_once_t once;dispatch_once(&once,^{app=[self new];});return app;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler{return FixtureBegin(NO,nil,handler);}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler{return FixtureBegin(YES,name,handler);}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier{
 @synchronized(RealLock){assert(RealTasks[@(identifier)]);ShortEnds++;[RealTasks removeObjectForKey:@(identifier)];}
}
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
@property(nonatomic,copy) void (^expirationHandler)(void);
@property(nonatomic,strong) NSProgress *progress;
@property NSUInteger completions;
@property BOOL success;
@end
@implementation FixtureTask
- (instancetype)init{if((self=[super init]))_progress=[NSProgress progressWithTotalUnitCount:1];return self;}
- (void)setTaskCompletedWithSuccess:(BOOL)success{self.completions++;self.success=success;}
- (void)updateTitle:(NSString *)title subtitle:(NSString *)subtitle{}
@end
NSDictionary *GSRequest(NSDictionary *request,NSError **error){
 NSDictionary *summary;dispatch_semaphore_t started,release;
 @synchronized(RealLock){
  if(SealDuringSummary){SealDuringSummary=NO;Batch=@{@"active":@NO,@"stage":@"finished",@"processed":@10,@"failed":@0};}
  summary=Summary;started=SummaryStarted;release=SummaryRelease;
 }
 if(release){dispatch_semaphore_signal(started);Await(release);}
 return summary;
}
NSDictionary *GSBatchImportSnapshot(void){@synchronized(RealLock){return Batch;}}
void GSStopBatchImport(BOOL expired){assert(expired);Stops++;}
static void Drain(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:0.1];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];}
static void Wait(NSTimeInterval seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];}
static void Foreground(void){UIApplication.sharedApplication.applicationState=UIApplicationStateActive;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];Drain();}
static void SetWork(BOOL active,NSUInteger pending){
 @synchronized(RealLock){
  Batch=@{@"active":@(active),@"stage":active?@"exporting":@"finished",@"processed":active?@1:@10,@"failed":@0};
  Summary=@{@"profiles":@{@"original":@{@"states":@{@"pending":@(pending)}}},@"conditions":@{@"paused":@NO}};
 }
}
static void TestBeginRace(BOOL foregroundReset){
 Foreground();UIApplication *app=UIApplication.sharedApplication;
 __block NSUInteger callbacks=0;
 UIBackgroundTaskIdentifier sibling=[app beginBackgroundTaskWithName:@"race-sibling" expirationHandler:^{assert(NSThread.isMainThread);callbacks++;}];
 dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
 __block UIBackgroundTaskIdentifier raw=UIBackgroundTaskInvalid,result=0;
 BeginHook=^(NSString *name,UIBackgroundTaskIdentifier identifier,void (^handler)(void)){
  if(![name isEqual:@"race-worker"])return;
  raw=identifier;dispatch_semaphore_signal(entered);Await(release);
 };
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{
  result=[app beginBackgroundTaskWithName:@"race-worker" expirationHandler:^{callbacks++;}];dispatch_semaphore_signal(done);
 }});
 Await(entered);RawExpiration(sibling)();assert(callbacks==1&&!RawOpen(sibling)&&RawOpen(raw));
 UIBackgroundTaskIdentifier fresh=UIBackgroundTaskInvalid;
 if(foregroundReset){Foreground();fresh=[app beginBackgroundTaskWithName:@"new-budget" expirationHandler:nil];assert(RawOpen(fresh));}
 dispatch_semaphore_signal(release);Await(done);
 assert(result==UIBackgroundTaskInvalid&&!RawOpen(raw)&&callbacks==1);
 assert(RawCount()==(foregroundReset?1:0));
 BeginHook=nil;if(foregroundReset)[app endBackgroundTask:fresh];
 Drain();assert(callbacks==1);
}
static void TestEarlyExpiration(BOOL invalid){
 Foreground();UIApplication *app=UIApplication.sharedApplication;
 __block NSUInteger callbacks=0,entries=0;__block void (^stale)(void);
 NSUInteger before=ShortEnds;InvalidBegin=invalid;
 BeginHook=^(NSString *name,UIBackgroundTaskIdentifier identifier,void (^handler)(void)){
  entries++;stale=[handler copy];handler();
  assert(GSExpiring&&[app beginBackgroundTaskWithName:@"retry-before-publication" expirationHandler:nil]==UIBackgroundTaskInvalid);
 };
 UIBackgroundTaskIdentifier result=[app beginBackgroundTaskWithName:@"early-expiry" expirationHandler:^{callbacks++;}];
 BeginHook=nil;InvalidBegin=NO;
 assert(result==UIBackgroundTaskInvalid&&RawCount()==0&&entries==1&&callbacks==0);
 assert(ShortEnds==before+(invalid?0:1));
 Drain();assert(callbacks==0&&entries==1);
 Foreground();stale();assert(!GSExpiring&&RawCount()==0);
}
static void TestWorkerExpiration(void){
 Foreground();UIApplication *app=UIApplication.sharedApplication;__block NSUInteger callbacks=0;
 UIBackgroundTaskIdentifier task=[app beginBackgroundTaskWithName:@"expire-on-worker" expirationHandler:^{assert(NSThread.isMainThread&&RawCount()==0);callbacks++;}];
 void (^expire)(void)=RawExpiration(task);dispatch_semaphore_t done=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{expire();dispatch_semaphore_signal(done);}});
 Await(done);assert(!RawOpen(task)&&callbacks==0);
 Drain();assert(callbacks==1);expire();assert(callbacks==1);
 NSUInteger ends=ShortEnds;[app endBackgroundTask:task];[app endBackgroundTask:task];assert(ShortEnds==ends);
}
static void TestHandBackEndRace(void){
 Foreground();UIApplication *app=UIApplication.sharedApplication;SetWork(YES,1);GSBeginBackgroundUpload(10);
 FixtureTask *task=[FixtureTask new];Launch(task);Drain();__block NSUInteger callbacks=0;
 UIBackgroundTaskIdentifier local=[app beginBackgroundTaskWithName:@"hand-back-race" expirationHandler:^{callbacks++;}];
 __block UIBackgroundTaskIdentifier raw=UIBackgroundTaskInvalid;
 BeginHook=^(NSString *name,UIBackgroundTaskIdentifier identifier,void (^handler)(void)){
  if(![name isEqual:@"hand-back-race"])return;
  raw=identifier;dispatch_semaphore_t ended=dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{[app endBackgroundTask:local];dispatch_semaphore_signal(ended);}});
  Await(ended);
 };
 GSFinishBackground(YES,@"test_hand_back");BeginHook=nil;
 assert(task.completions==1&&task.success&&raw!=UIBackgroundTaskInvalid&&!RawOpen(raw)&&callbacks==0&&RawCount()==0);
 NSUInteger ends=ShortEnds;[app endBackgroundTask:local];assert(ends==ShortEnds);
}
static void TestHandBackReplacement(void){
 Foreground();UIApplication *app=UIApplication.sharedApplication;SetWork(YES,1);GSBeginBackgroundUpload(10);
 FixtureTask *old=[FixtureTask new],*replacement=[FixtureTask new];Launch(old);Drain();
 __block NSUInteger callbacks=0;__block UIBackgroundTaskIdentifier fresh=UIBackgroundTaskInvalid;
 for(NSUInteger i=0;i<3;i++)[app beginBackgroundTaskWithName:@"hand-back-replacement" expirationHandler:^{
  assert(old.completions==0);callbacks++;
  if(callbacks==1){GSBeginBackgroundUpload(20);Launch(replacement);fresh=[app beginBackgroundTaskWithName:@"new-budget-deferred" expirationHandler:nil];}
 }];
 BeginHook=^(NSString *name,UIBackgroundTaskIdentifier identifier,void (^handler)(void)){if([name isEqual:@"hand-back-replacement"])handler();};
 NSUInteger before=RealNext;GSFinishBackground(YES,@"test_hand_back_replacement");BeginHook=nil;
 assert(RealNext==before+1&&callbacks==3&&old.completions==1&&GSTask==replacement&&replacement.completions==0);
 assert(GSDeferred[@(fresh)]&&RawCount()==0);[app endBackgroundTask:fresh];GSFinishBackground(YES,@"test_replacement_end");
}
static void TestBeginNotificationReplacement(void){
 Foreground();SetWork(YES,1);__block BOOL replaced=NO;
 id observer=[NSNotificationCenter.defaultCenter addObserverForName:GSBackgroundUploadChanged object:nil queue:nil usingBlock:^(NSNotification *note){
  if(!replaced&&[GSBackgroundUploadSnapshot()[@"status"]isEqual:@"replaced"]){replaced=YES;GSBeginBackgroundUpload(20);}
 }];
 GSBeginBackgroundUpload(10);[NSNotificationCenter.defaultCenter removeObserver:observer];
 assert(replaced&&GSCount==20&&GSIdentifier&&GSTimer&&RawOpen(GSShortTask));
 GSFinishBackground(YES,@"test_notification_end");assert(RawCount()==0);
}
static void TestForegroundCancellation(BOOL budgetExpired){
 Foreground();UIApplication *app=UIApplication.sharedApplication;SetWork(YES,1);
 UIBackgroundTaskIdentifier host=[app beginBackgroundTaskWithName:@"foreground-host" expirationHandler:nil];
 GSBeginBackgroundUpload(10);FixtureTask *task=[FixtureTask new];Launch(task);Drain();
 __block NSUInteger callbacks=0;
 [app beginBackgroundTaskWithName:@"foreground-deferred" expirationHandler:^{assert(NSThread.isMainThread&&task.completions==0);callbacks++;}];
 if(budgetExpired)RawExpiration(host)();
 NSUInteger before=RealNext;task.expirationHandler();
 assert(callbacks==1&&task.completions==1&&RealNext==before);
 UIBackgroundTaskIdentifier fresh=[app beginBackgroundTaskWithName:@"foreground-after-cancel" expirationHandler:nil];
 if(budgetExpired)assert(fresh==UIBackgroundTaskInvalid&&RawCount()==0);
 else{assert(RawOpen(fresh)&&RawOpen(host));[app endBackgroundTask:fresh];[app endBackgroundTask:host];}
}
static void TestDeferredReplacement(BOOL launchReplacement){
 Foreground();UIApplication *app=UIApplication.sharedApplication;SetWork(YES,1);GSBeginBackgroundUpload(10);
 FixtureTask *old=[FixtureTask new],*replacement=[FixtureTask new];Launch(old);Drain();
 __block NSUInteger callbacks=0,stopsAtReplacement=0,cancelsAtReplacement=0;
 __block UIBackgroundTaskIdentifier fresh=UIBackgroundTaskInvalid;
 [app beginBackgroundTaskWithName:@"replace-from-deferred" expirationHandler:^{
  assert(old.completions==0&&NSThread.isMainThread);callbacks++;
  GSBeginBackgroundUpload(20);
  if(launchReplacement){Launch(replacement);fresh=[app beginBackgroundTaskWithName:@"new-deferred" expirationHandler:nil];}
  else fresh=GSShortTask;
  stopsAtReplacement=Stops;cancelsAtReplacement=RequestCancels;
 }];
 old.expirationHandler();
 assert(callbacks==1&&old.completions==1&&Stops==stopsAtReplacement&&RequestCancels==cancelsAtReplacement);
 assert(GSIdentifier&&GSTimer&&GSCount==20&&replacement.completions==0);
 if(launchReplacement){assert(GSTask==replacement&&GSDeferred[@(fresh)]);[app endBackgroundTask:fresh];}
 else assert(!GSTask&&GSShortTask==fresh&&RawOpen(fresh));
 GSFinishBackground(YES,@"test_replacement_end");assert(RawCount()==0);
}
static void TestSweepReplacement(void){
 Foreground();UIApplication *app=UIApplication.sharedApplication;SetWork(YES,1);
 FixtureTask *old=[FixtureTask new],*replacement=[FixtureTask new];
 __block NSUInteger callbacks=0,stopsAtReplacement=0,cancelsAtReplacement=0;
 __block UIBackgroundTaskIdentifier fresh=UIBackgroundTaskInvalid;
 [app beginBackgroundTaskWithName:@"replace-from-real-sweep" expirationHandler:^{
  assert(old.completions==0&&RawCount()==0);callbacks++;
  GSBeginBackgroundUpload(20);Launch(replacement);
  fresh=[app beginBackgroundTaskWithName:@"replacement-deferred" expirationHandler:nil];
  stopsAtReplacement=Stops;cancelsAtReplacement=RequestCancels;
 }];
 GSBeginBackgroundUpload(10);Launch(old);Drain();
 [app beginBackgroundTaskWithName:@"old-deferred" expirationHandler:^{assert(old.completions==0);callbacks++;}];
 app.applicationState=UIApplicationStateBackground;old.expirationHandler();
 assert(callbacks==2&&old.completions==1&&GSTask==replacement&&replacement.completions==0);
 assert(Stops==stopsAtReplacement&&RequestCancels==cancelsAtReplacement&&GSCount==20&&GSDeferred[@(fresh)]);
 [app endBackgroundTask:fresh];GSFinishBackground(YES,@"test_sweep_end");assert(RawCount()==0);
}
static void TestShortReplacement(void){
 Foreground();UIApplication *app=UIApplication.sharedApplication;SetWork(YES,1);GSBeginBackgroundUpload(10);
 FixtureTask *replacement=[FixtureTask new];__block NSUInteger stopsAtReplacement=0;
 UIBackgroundTaskIdentifier host=[app beginBackgroundTaskWithName:@"replace-with-old-short" expirationHandler:^{
  GSBeginBackgroundUpload(20);Launch(replacement);stopsAtReplacement=Stops;
 }];
 RawExpiration(host)();
 assert(GSTask==replacement&&replacement.completions==0&&GSCount==20&&Stops==stopsAtReplacement);
 GSFinishBackground(YES,@"test_short_end");assert(RawCount()==0);
}
static void TestPreparationProgress(void){
 Foreground();SetWork(YES,1);
 @synchronized(RealLock){
  Batch=@{@"active":@YES,@"processed":@0,@"activePreparations":@12};Summary=nil;
  SummaryStarted=dispatch_semaphore_create(0);SummaryRelease=dispatch_semaphore_create(0);
 }
 GSBeginBackgroundUpload(10);FixtureTask *task=[FixtureTask new];Launch(task);
 assert(task.progress.totalUnitCount==20000&&task.progress.completedUnitCount==0);
 Await(SummaryStarted);
 @synchronized(RealLock){Batch=@{@"active":@YES,@"processed":@0,@"activePreparations":@12,@"cloudProgressUnits":@100};}
 GSPollBackground();assert(task.progress.completedUnitCount==1&&GSPolling);
 GSPollBackground();assert(task.progress.completedUnitCount==1);
 @synchronized(RealLock){Batch=@{@"active":@YES,@"processed":@0,@"activePreparations":@12,@"cloudProgressUnits":@100,@"exportedBytes":@1048576};}
 CFRunLoopAddCommonMode(CFRunLoopGetMain(),CFSTR("FixtureTrackingMode"));
 GSTimer.fireDate=NSDate.date;
 [NSRunLoop.mainRunLoop runMode:@"FixtureTrackingMode" beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
 assert(task.progress.completedUnitCount==2&&GSPolling);
 // A multi-GB original is still copying after PhotoKit finishes and before seal.
 // Upload summary remains blocked, no item completes, but each successful copy advances progress.
 for(NSUInteger tick=1;tick<=40;tick++){
  @synchronized(RealLock){Batch=@{@"active":@YES,@"processed":@0,@"exportedBytes":@(9ULL<<30),@"cloudProgressUnits":@100,@"stagedBytes":@(tick*(128ULL<<20))};}
  GSPollBackground();assert(task.progress.completedUnitCount==2+(int64_t)tick&&GSPolling&&task.completions==0);
  GSPollBackground();assert(task.progress.completedUnitCount==2+(int64_t)tick); // Waiting is not progress.
 }
 dispatch_semaphore_t oldRelease=SummaryRelease;
 // Cloud ranges may arrive slowly or out of order before any complete chunk
 // reaches staging. Those actual bytes must reach the system while summary is blocked.
 for(NSUInteger tick=1;tick<=40;tick++){
  @synchronized(RealLock){Batch=@{@"active":@YES,@"processed":@0,@"sourceReadBytes":@(tick*131072)};}
  GSPollBackground();assert(task.progress.completedUnitCount==42+(int64_t)tick&&GSPolling&&task.completions==0);
  GSPollBackground();assert(task.progress.completedUnitCount==42+(int64_t)tick);
 }
 @synchronized(RealLock){SummaryStarted=dispatch_semaphore_create(0);SummaryRelease=dispatch_semaphore_create(0);Batch=@{@"active":@YES,@"processed":@0};}
 GSBeginBackgroundUpload(20);FixtureTask *replacement=[FixtureTask new];Launch(replacement);Await(SummaryStarted);
 dispatch_semaphore_signal(oldRelease);Drain();
 assert(GSPolling&&replacement.progress.completedUnitCount==0&&task.completions==1);
 dispatch_semaphore_t release=SummaryRelease;
 @synchronized(RealLock){SummaryRelease=nil;SummaryStarted=nil;}
 dispatch_semaphore_signal(release);Drain();assert(!GSPolling&&replacement.completions==0);
 @synchronized(RealLock){Batch=@{@"active":@YES,@"processed":@0,@"stagedBytes":@1048576};}
 GSPollBackground();Drain();assert(replacement.progress.completedUnitCount==1&&replacement.completions==0);
 GSPollBackground();Drain();assert(replacement.progress.completedUnitCount==1);
 @synchronized(RealLock){Batch=@{@"active":@YES,@"processed":@0,@"stagedBytes":@1048576,@"scannedItems":@256};}
 GSPollBackground();Drain();assert(replacement.progress.completedUnitCount==2&&replacement.completions==0);
 GSPollBackground();Drain();assert(replacement.progress.completedUnitCount==2);
 GSFinishBackground(NO,@"test_progress_end");
}
int main(void){@autoreleasepool{
 RealLock=[NSObject new];RealTasks=[NSMutableDictionary dictionary];UIApplication *app=UIApplication.sharedApplication;
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
 @synchronized(RealLock){Summary=@{@"profiles":@{@"original":@{@"states":@{@"pending":@2}}},@"conditions":@{@"paused":@NO},@"transport":@{@"uploadBodyBytesRead":@4096}};}
 GSPollBackground();Drain();int64_t moving=first.progress.completedUnitCount;
 GSPollBackground();Drain();assert(first.progress.completedUnitCount==moving);
 @synchronized(RealLock){NSMutableDictionary *updated=[Summary mutableCopy];updated[@"transport"]=@{@"uploadBodyBytesRead":@8192};Summary=updated;}
 GSPollBackground();Drain();assert(first.progress.completedUnitCount==moving+1);
 SetWork(YES,2);GSPollBackground();Drain();GSPollBackground();Drain();assert(first.progress.completedUnitCount==moving+1);
 SetWork(YES,0);@synchronized(RealLock){SealDuringSummary=YES;}GSPollBackground();Drain();assert(first.completions==0); // Final seal racing a summary cannot complete the task.
 SetWork(NO,2);GSPollBackground();Drain();assert(first.completions==0); // Prepared is not uploaded.
 @synchronized(RealLock){Batch=@{@"active":@NO,@"stage":@"stopped",@"stopReason":@"queue_rejected",@"processed":@5};}
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
 [app beginBackgroundTaskWithName:@"late" expirationHandler:^{assert(spent.completions==0&&NSThread.isMainThread);hostExpired++;}];
 NoTime=YES;GSFinishBackground(NO,@"test_end");Drain();NoTime=NO;assert(hostExpired==2&&spent.completions==1);
 SetWork(YES,1);GSBeginBackgroundUpload(10);FixtureTask *second=[FixtureTask new];Launch(second);Drain();
 NSUInteger beforeExpiry=RealNext;__block NSUInteger deferredExpired=0;
 for(NSUInteger i=0;i<600;i++){
  __block UIBackgroundTaskIdentifier local=UIBackgroundTaskInvalid;
  void (^handler)(void)=i%2?nil:^{
   assert(NSThread.isMainThread&&second.completions==0);deferredExpired++;
   [app endBackgroundTask:local];
   assert([app beginBackgroundTaskWithExpirationHandler:nil]==UIBackgroundTaskInvalid);
  };
  local=[app beginBackgroundTaskWithName:@"deferred-at-expiry" expirationHandler:handler];
 }
 app.applicationState=UIApplicationStateBackground;
 second.expirationHandler();assert(deferredExpired==300&&Stops==1&&second.completions==1&&!second.success);
 Drain();assert(deferredExpired==300);
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
 Reject=NO;Configured=YES;GSFinishBackground(NO,@"test_reset");
 TestBeginRace(NO);TestBeginRace(YES);
 TestEarlyExpiration(NO);TestEarlyExpiration(YES);TestWorkerExpiration();
 TestHandBackEndRace();TestHandBackReplacement();TestBeginNotificationReplacement();
 TestForegroundCancellation(NO);TestForegroundCancellation(YES);
 TestDeferredReplacement(NO);TestDeferredReplacement(YES);TestSweepReplacement();TestShortReplacement();TestPreparationProgress();
 Foreground();assert(RawCount()==0&&GSDeferred.count==0&&GSHandedBack.count==0&&!GSTask&&!GSTimer);
 NSLog(@"PASS background grant, progress, synchronous raw expiry, pending begin races, hand-back races, foreground cancellation and reentrant epoch isolation");
}}
