#import "GSBackgroundUpload.h"
#import "GSBatchImport.h"
#import "../Shared/IPCProtocol.h"
#import "../Shared/GSLocalization.h"
#if GS_TEST_BACKGROUND
#import "../tests/background_upload_shim.h"
#else
#import <UIKit/UIKit.h>
#endif
#include <dlfcn.h>
#include <objc/runtime.h>

NSString *const GSBackgroundUploadChanged=@"GoToHPBackgroundUploadChanged";
// Runtime binding keeps the tweak usable on iOS 15 and older build SDKs.
// These are public BackgroundTasks selectors, available since iOS 26.
@protocol GSContinuedTask <NSObject>
@property(nonatomic,copy) void (^expirationHandler)(void);
@property(nonatomic,readonly) NSProgress *progress;
- (void)setTaskCompletedWithSuccess:(BOOL)success;
- (void)updateTitle:(NSString *)title subtitle:(NSString *)subtitle;
@end
@protocol GSContinuedRequest <NSObject>
- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title subtitle:(NSString *)subtitle;
@end
@interface NSObject (GSBackgroundSchedulerABI)
+ (id)sharedScheduler;
- (BOOL)registerForTaskWithIdentifier:(NSString *)identifier usingQueue:(dispatch_queue_t)queue launchHandler:(void (^)(id<GSContinuedTask>))handler;
- (BOOL)submitTaskRequest:(id)request error:(NSError **)error;
- (void)cancelTaskRequestWithIdentifier:(NSString *)identifier;
@end

static NSDictionary *GSSnapshot;
#if GS_JAILED
static id<GSContinuedTask> GSTask;
static NSString *GSIdentifier;
static NSTimer *GSTimer;
static UIBackgroundTaskIdentifier GSShortTask;
static NSUInteger GSEpoch,GSCount;
static int64_t GSProgressUnits;
static BOOL GSPolling;
// Google Photos begins UIKit background tasks continuously while it runs, and
// one of them is begun again at the instant the background budget expires and
// is never ended. RunningBoard then kills the whole process (0x2182BAD2,
// "Shared Background Assertion N"), leaving no crash report, instead of
// suspending it. Two measures, both on UIKit's public begin/end contract:
// - While our continued-processing grant holds the process, dasd already keeps
//   it running: account begin/end locally, and hand still-open tasks back to
//   UIKit when the grant ends, restoring their expiry.
// - Always: finish expired tasks before returning to UIKit, and reject new
//   assertions once the budget is spent. A delayed cleanup can never run if
//   iOS suspends us first, and a retrying owner must not reopen the assertion.
@interface GSTaskRecord : NSObject
@property UIBackgroundTaskIdentifier identifier; // UIKit ID once begin returns
@property(copy) void (^handler)(void);
@property BOOL expired,ended;
@property(strong) NSArray<NSNumber *> *callers;
@end
@implementation GSTaskRecord @end
static const UIBackgroundTaskIdentifier GSDeferredBase=(UIBackgroundTaskIdentifier)1<<40;
static NSObject *GSDeferredLock;
static BOOL GSDeferring,GSExpiring;
static NSMutableDictionary<NSNumber *,NSArray *> *GSDeferred; // local ID -> @[name, handler]
static NSMutableDictionary<NSNumber *,NSNumber *> *GSHandedBack; // local ID -> UIKit ID
static NSMutableDictionary<NSNumber *,GSTaskRecord *> *GSLive; // UIKit ID -> record
static NSMutableDictionary<NSString *,NSNumber *> *GSForcedCallers;
static NSMutableSet<NSNumber *> *GSForcedIDs; // force-ended; the owner's later end is dropped
static NSUInteger GSDeferredNext,GSDeferredTotal,GSHandedBackTotal,GSForcedEnds,GSLateExpired,GSExpiryWindows,GSRejectedLate;
static UIBackgroundTaskIdentifier (*GSOriginalBeginNamed)(id,SEL,NSString *,void (^)(void));
static UIBackgroundTaskIdentifier (*GSOriginalBegin)(id,SEL,void (^)(void));
static void (*GSOriginalEnd)(id,SEL,UIBackgroundTaskIdentifier);
static void GSExpireTask(GSTaskRecord *record,BOOL late);
static NSString *GSCallerKey(NSArray<NSNumber *> *callers){
 // First frames outside this dylib and the system task plumbing name the owner.
 Dl_info own={0};dladdr((const void *)GSCallerKey,&own);
 NSMutableArray *frames=[NSMutableArray array];
 for(NSNumber *address in callers){
  Dl_info info={0};
  if(!dladdr((const void *)address.unsignedLongValue,&info)||!info.dli_fname||info.dli_fbase==own.dli_fbase)continue;
  NSString *image=[@(info.dli_fname) lastPathComponent];
  if([@[@"UIKitCore",@"libdispatch.dylib",@"Foundation",@"CoreFoundation",@"libsystem_pthread.dylib"]containsObject:image])continue;
  [frames addObject:[NSString stringWithFormat:@"%@+0x%lx",image,(unsigned long)(address.unsignedLongValue-(uintptr_t)info.dli_fbase)]];
  if(frames.count==2)break;
 }
 return frames.count?[frames componentsJoinedByString:@" < "]:@"unknown";
}
static void GSForceEnd(GSTaskRecord *record){
 @synchronized(GSDeferredLock){
  if(record.ended)return;
  record.ended=YES;[GSLive removeObjectForKey:@(record.identifier)];[GSForcedIDs addObject:@(record.identifier)];GSForcedEnds++;
  NSString *key=GSCallerKey(record.callers);
  if(GSForcedCallers[key]||GSForcedCallers.count<16)GSForcedCallers[key]=@([GSForcedCallers[key]unsignedIntegerValue]+1);
 }
 GSOriginalEnd(UIApplication.sharedApplication,@selector(endBackgroundTask:),record.identifier);
}
static void GSSweepExpiring(void){
 NSArray *open;@synchronized(GSDeferredLock){if(!GSExpiring)return;open=GSLive.allValues;}
 for(GSTaskRecord *record in open)GSExpireTask(record,YES);
}
static void GSExpireTask(GSTaskRecord *record,BOOL late){
 if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{GSExpireTask(record,late);});return;}
 BOOL sweep=NO;
 @synchronized(GSDeferredLock){
  if(record.ended||record.expired||(late&&!GSExpiring))return; // Late expiry ends at foreground.
  // UIKit may expire a task before begin has returned its identifier.
  if(record.identifier==UIBackgroundTaskInvalid){dispatch_async(dispatch_get_main_queue(),^{GSExpireTask(record,late);});return;}
  record.expired=YES;if(late)GSLateExpired++;
  if(!GSExpiring){GSExpiring=YES;GSExpiryWindows++;sweep=YES;}
 }
 // Tasks begun around the expiry warning may never see a handler; expire them too.
 if(record.handler)record.handler();
 GSForceEnd(record);
 if(sweep)GSSweepExpiring();
}
static UIBackgroundTaskIdentifier GSBeginReal(id app,BOOL named,NSString *name,void (^handler)(void)){
 @synchronized(GSDeferredLock){if(GSExpiring){GSRejectedLate++;return UIBackgroundTaskInvalid;}}
 GSTaskRecord *record=[GSTaskRecord new];record.identifier=UIBackgroundTaskInvalid;record.handler=handler;
 NSArray *stack=NSThread.callStackReturnAddresses;record.callers=[stack subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)12,stack.count))];
 void (^expire)(void)=^{GSExpireTask(record,NO);};
 UIBackgroundTaskIdentifier real=named?GSOriginalBeginNamed(app,@selector(beginBackgroundTaskWithName:expirationHandler:),name,expire):
  GSOriginalBegin(app,@selector(beginBackgroundTaskWithExpirationHandler:),expire);
 if(real==UIBackgroundTaskInvalid)return real;
 BOOL late;
 @synchronized(GSDeferredLock){record.identifier=real;GSLive[@(real)]=record;late=GSExpiring;}
 if(late)GSExpireTask(record,YES); // Expiry raced the begin call; do not delay cleanup.
 return real;
}
static UIBackgroundTaskIdentifier GSDeferTask(NSString *name,void (^handler)(void)){
 // Caller holds GSDeferredLock.
 UIBackgroundTaskIdentifier local=GSDeferredBase+(++GSDeferredNext);GSDeferredTotal++;
 GSDeferred[@(local)]=@[name?:(id)NSNull.null,handler?[handler copy]:(id)NSNull.null];
 return local;
}
static UIBackgroundTaskIdentifier GSBeginNamed(id app,SEL selector,NSString *name,void (^handler)(void)){
 @synchronized(GSDeferredLock){if(GSDeferring)return GSDeferTask(name,handler);}
 return GSBeginReal(app,YES,name,handler);
}
static UIBackgroundTaskIdentifier GSBegin(id app,SEL selector,void (^handler)(void)){
 @synchronized(GSDeferredLock){if(GSDeferring)return GSDeferTask(nil,handler);}
 return GSBeginReal(app,NO,nil,handler);
}
static void GSEnd(id app,SEL selector,UIBackgroundTaskIdentifier identifier){
 if(identifier>=GSDeferredBase&&identifier!=UIBackgroundTaskInvalid){
  NSNumber *handed=nil;
  @synchronized(GSDeferredLock){
   if(GSDeferred[@(identifier)]){[GSDeferred removeObjectForKey:@(identifier)];return;}
   handed=GSHandedBack[@(identifier)];[GSHandedBack removeObjectForKey:@(identifier)];
  }
  if(!handed)return; // Already ended; UIKit likewise ignores a stale identifier.
  identifier=handed.unsignedIntegerValue;
 }
 @synchronized(GSDeferredLock){
  if([GSForcedIDs containsObject:@(identifier)]){[GSForcedIDs removeObject:@(identifier)];return;}
  GSLive[@(identifier)].ended=YES;[GSLive removeObjectForKey:@(identifier)];
 }
 GSOriginalEnd(app,selector,identifier);
}
static BOOL GSInstallDeferredTasks(void){
 static BOOL installed;static dispatch_once_t once;
 dispatch_once(&once,^{
  Class app=UIApplication.class;
  Method named=class_getInstanceMethod(app,@selector(beginBackgroundTaskWithName:expirationHandler:));
  Method plain=class_getInstanceMethod(app,@selector(beginBackgroundTaskWithExpirationHandler:));
  Method end=class_getInstanceMethod(app,@selector(endBackgroundTask:));
  if(!named||!plain||!end)return;
  GSDeferredLock=[NSObject new];GSDeferred=[NSMutableDictionary dictionary];GSHandedBack=[NSMutableDictionary dictionary];
  GSLive=[NSMutableDictionary dictionary];GSForcedCallers=[NSMutableDictionary dictionary];GSForcedIDs=[NSMutableSet set];
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
   @synchronized(GSDeferredLock){GSExpiring=NO;} // A new background budget starts on the next exit.
  }];
  GSOriginalEnd=(void *)method_setImplementation(end,(IMP)GSEnd);
  GSOriginalBeginNamed=(void *)method_setImplementation(named,(IMP)GSBeginNamed);
  GSOriginalBegin=(void *)method_setImplementation(plain,(IMP)GSBegin);
  installed=YES;
 });
 return installed;
}
static void GSStopDeferringTasks(void){
 if(!GSDeferredLock)return;
 // Held under the (recursive) lock so an end racing the hand-back is never lost.
 @synchronized(GSDeferredLock){
  GSDeferring=NO;
  for(NSNumber *local in GSDeferred.allKeys){
   NSArray *task=GSDeferred[local];
   NSString *name=task[0]==NSNull.null?nil:task[0];
   void (^handler)(void)=task[1]==NSNull.null?nil:task[1];
   UIBackgroundTaskIdentifier real=GSBeginReal(UIApplication.sharedApplication,YES,name,handler);
   if(real!=UIBackgroundTaskInvalid){GSHandedBack[local]=@(real);GSHandedBackTotal++;}
   else if(handler)dispatch_async(dispatch_get_main_queue(),handler); // No time left: expire as UIKit would.
  }
  [GSDeferred removeAllObjects];
 }
}
static void GSBackgroundRecord(NSDictionary *state){
 @synchronized(GSBackgroundUploadChanged){GSSnapshot=[state copy];}
 [NSNotificationCenter.defaultCenter postNotificationName:GSBackgroundUploadChanged object:nil];
}
static void GSEndShortTask(void){if(GSShortTask!=UIBackgroundTaskInvalid){[UIApplication.sharedApplication endBackgroundTask:GSShortTask];GSShortTask=UIBackgroundTaskInvalid;}}
static void GSFinishBackground(BOOL success,NSString *status){
 GSEpoch++;[GSTimer invalidate];GSTimer=nil;
 id<GSContinuedTask> task=GSTask;GSTask=nil;
 if(GSIdentifier)[[NSClassFromString(@"BGTaskScheduler") sharedScheduler] cancelTaskRequestWithIdentifier:GSIdentifier];
 GSIdentifier=nil;GSBackgroundRecord(@{@"granted":@NO,@"status":status});
 GSStopDeferringTasks(); // Before completing: UIKit must hold them before dasd releases the process.
 if(task){task.expirationHandler=nil;[task setTaskCompletedWithSuccess:success];}
 GSEndShortTask();
}
static void GSPollBackground(void){
 if(GSPolling)return;GSPolling=YES;NSUInteger epoch=GSEpoch;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  // Read the producer first: a finished batch has sealed its last job before
  // we inspect the queue. Reversing these reads can observe an empty queue
  // just before the final seal and prematurely release the background grant.
  NSDictionary *batch=GSBatchImportSnapshot();
  NSDictionary *summary=GSRequest(@{@"op":@"upload_summary"},nil);
  NSUInteger outstanding=0;
  for(NSDictionary *profile in [summary[@"profiles"]allValues])for(NSString *key in @[@"importing",@"pending",@"preparing",@"uploading",@"committing"])
   outstanding+=[profile[@"states"][key]unsignedIntegerValue];
  dispatch_async(dispatch_get_main_queue(),^{
   GSPolling=NO;if(epoch!=GSEpoch)return;
   NSString *reason=batch[@"stopReason"];
   if([reason isEqual:@"account_changed"]||[reason isEqual:@"background_expired"]||[summary[@"conditions"][@"paused"]boolValue]){GSFinishBackground(NO,@"stopped");return;}
   if(!summary)return; // An unavailable service is never treated as completion.
   BOOL finished=![batch[@"active"]boolValue]&&outstanding==0;
   NSUInteger prepared=MIN(GSCount,[batch[@"processed"]unsignedIntegerValue]);
   NSUInteger uploaded=prepared>outstanding?prepared-outstanding:0;
   if(GSTask){
    // dasd cancels a grant whose progress stops advancing ("marking stalled").
    // One item can upload for minutes, so advance a unit per poll while bytes
    // actually move or originals are being prepared; a real stall still stops it.
    const int64_t scale=1000,total=(int64_t)MAX((NSUInteger)1,GSCount*2)*scale;
    BOOL active=[summary[@"transport"][@"recentUploadBodyBytesPerSecond"]doubleValue]>0||[batch[@"activePreparations"]unsignedIntegerValue]>0;
    GSProgressUnits=finished?total:MIN(total-1,MAX(GSProgressUnits+(active?1:0),(int64_t)(prepared+uploaded)*scale));
    GSTask.progress.totalUnitCount=total;
    GSTask.progress.completedUnitCount=GSProgressUnits;
    [GSTask updateTitle:@"GoToHP" subtitle:[NSString stringWithFormat:GSL(@"Prepared %lu / %lu · %lu pending"),(unsigned long)prepared,(unsigned long)GSCount,(unsigned long)outstanding]];
   }
   if(finished)GSFinishBackground([batch[@"failed"]unsignedIntegerValue]==0,@"finished");
  });
 }});
}
#endif
void GSBeginBackgroundUpload(NSUInteger count){
#if GS_JAILED
 NSCAssert(NSThread.isMainThread,@"Start a user-requested background upload on main");
 static dispatch_once_t once;dispatch_once(&once,^{GSShortTask=UIBackgroundTaskInvalid;});
 if(!count)return;
 GSFinishBackground(NO,@"replaced");GSCount=count;GSProgressUnits=0;NSUInteger epoch=GSEpoch;
 GSBackgroundRecord(@{@"granted":@NO,@"status":@"foreground_only"});
 GSShortTask=[UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
  if(epoch!=GSEpoch)return;
  GSEndShortTask();
  if(!GSTask){GSStopBatchImport(YES);GSFinishBackground(NO,@"expired");}
 }];
 dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks",RTLD_LAZY|RTLD_LOCAL);
 Class requestClass=NSClassFromString(@"BGContinuedProcessingTaskRequest");
 id scheduler=[NSClassFromString(@"BGTaskScheduler") sharedScheduler];
 NSString *prefix=[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".gotohp.upload"];
 NSArray *permitted=[NSBundle.mainBundle objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"];
 if(requestClass&&[permitted containsObject:[prefix stringByAppendingString:@".*"]]){
  BOOL deferrable=GSInstallDeferredTasks();
  GSIdentifier=[prefix stringByAppendingFormat:@".%@",NSUUID.UUID.UUIDString];
  BOOL registered=[scheduler registerForTaskWithIdentifier:GSIdentifier usingQueue:dispatch_get_main_queue() launchHandler:^(id<GSContinuedTask> task){
   if(epoch!=GSEpoch){[task setTaskCompletedWithSuccess:NO];return;}
   GSTask=task;
   if(deferrable)@synchronized(GSDeferredLock){GSDeferring=YES;GSExpiring=NO;}
   task.expirationHandler=^{dispatch_async(dispatch_get_main_queue(),^{
    if(epoch!=GSEpoch)return;
    // The continued-processing budget is spent too. Handing hundreds of host
    // tasks back as fresh UIKit assertions here creates another expiry storm.
    @synchronized(GSDeferredLock){if(!GSExpiring){GSExpiring=YES;GSExpiryWindows++;}}
    GSSweepExpiring();
    GSStopBatchImport(YES);GSFinishBackground(NO,@"expired");
   });};
   GSBackgroundRecord(@{@"granted":@YES,@"status":@"running"});GSEndShortTask();GSPollBackground();
  }];
  if(registered){
   id<GSContinuedRequest> request=[(id<GSContinuedRequest>)[requestClass alloc] initWithIdentifier:GSIdentifier title:@"GoToHP" subtitle:GSL(@"Preparing uploads")];
   NSError *error=nil;
   BOOL accepted=[scheduler submitTaskRequest:request error:&error];
   if(!GSTask)GSBackgroundRecord(@{@"granted":@NO,@"status":accepted?@"requested":@"rejected",@"errorCode":@(error.code)});
  }else GSBackgroundRecord(@{@"granted":@NO,@"status":@"registration_failed"});
 }
 GSTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){GSPollBackground();}];
#endif
}
void GSInstallBackgroundTaskGuard(void){
#if GS_JAILED
 GSInstallDeferredTasks();
#endif
}
NSDictionary *GSBackgroundUploadSnapshot(void){
 NSDictionary *snapshot;
 @synchronized(GSBackgroundUploadChanged){snapshot=GSSnapshot?:@{@"granted":@NO,@"status":@"idle"};}
#if GS_JAILED
 if(GSDeferredLock)@synchronized(GSDeferredLock){
  NSMutableDictionary *merged=[snapshot mutableCopy];
  if(GSDeferredTotal)merged[@"deferredTasks"]=@{@"begun":@(GSDeferredTotal),@"open":@(GSDeferred.count),@"handedBack":@(GSHandedBackTotal),@"handedBackOpen":@(GSHandedBack.count)};
  if(GSExpiryWindows)merged[@"expiryGuard"]=@{@"windows":@(GSExpiryWindows),@"forcedEnds":@(GSForcedEnds),@"lateExpired":@(GSLateExpired),@"rejectedLate":@(GSRejectedLate),@"forcedCallers":[GSForcedCallers copy]};
  snapshot=merged;
 }
#endif
 return snapshot;
}
