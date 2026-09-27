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
static BOOL GSPolling;
// Google Photos begins UIKit background tasks continuously while it runs. Once
// our continued-processing grant keeps a backgrounded process alive, they draw
// on the ~30 s FinishTask budget; a task begun after it is spent must end
// within seconds or RunningBoard kills the whole process (0x2182BAD2, "Shared
// Background Assertion"), leaving no crash report. dasd already holds the
// process during the grant, so account begin/end locally, then hand tasks that
// are still open back to UIKit when the grant ends, restoring their expiry.
static const UIBackgroundTaskIdentifier GSDeferredBase=(UIBackgroundTaskIdentifier)1<<40;
static NSObject *GSDeferredLock;
static BOOL GSDeferring;
static NSMutableDictionary<NSNumber *,NSArray *> *GSDeferred; // local ID -> @[name, handler]
static NSMutableDictionary<NSNumber *,NSNumber *> *GSHandedBack; // local ID -> UIKit ID
static NSUInteger GSDeferredNext,GSDeferredTotal,GSHandedBackTotal;
static UIBackgroundTaskIdentifier (*GSOriginalBeginNamed)(id,SEL,NSString *,void (^)(void));
static UIBackgroundTaskIdentifier (*GSOriginalBegin)(id,SEL,void (^)(void));
static void (*GSOriginalEnd)(id,SEL,UIBackgroundTaskIdentifier);
static UIBackgroundTaskIdentifier GSDeferTask(NSString *name,void (^handler)(void)){
 // Caller holds GSDeferredLock.
 UIBackgroundTaskIdentifier local=GSDeferredBase+(++GSDeferredNext);GSDeferredTotal++;
 GSDeferred[@(local)]=@[name?:(id)NSNull.null,handler?[handler copy]:(id)NSNull.null];
 return local;
}
static UIBackgroundTaskIdentifier GSBeginNamed(id app,SEL selector,NSString *name,void (^handler)(void)){
 @synchronized(GSDeferredLock){if(GSDeferring)return GSDeferTask(name,handler);}
 return GSOriginalBeginNamed(app,selector,name,handler);
}
static UIBackgroundTaskIdentifier GSBegin(id app,SEL selector,void (^handler)(void)){
 @synchronized(GSDeferredLock){if(GSDeferring)return GSDeferTask(nil,handler);}
 return GSOriginalBegin(app,selector,handler);
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
   UIBackgroundTaskIdentifier real=GSOriginalBeginNamed(UIApplication.sharedApplication,@selector(beginBackgroundTaskWithName:expirationHandler:),name,handler);
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
    GSTask.progress.totalUnitCount=MAX(1,GSCount*2);
    GSTask.progress.completedUnitCount=finished?GSCount*2:MIN(GSCount*2-1,prepared+uploaded);
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
 GSFinishBackground(NO,@"replaced");GSCount=count;NSUInteger epoch=GSEpoch;
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
   if(deferrable)@synchronized(GSDeferredLock){GSDeferring=YES;}
   task.expirationHandler=^{dispatch_async(dispatch_get_main_queue(),^{
    if(epoch!=GSEpoch)return;
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
NSDictionary *GSBackgroundUploadSnapshot(void){
 NSDictionary *snapshot;
 @synchronized(GSBackgroundUploadChanged){snapshot=GSSnapshot?:@{@"granted":@NO,@"status":@"idle"};}
#if GS_JAILED
 if(GSDeferredLock)@synchronized(GSDeferredLock){
  if(GSDeferredTotal){
   NSMutableDictionary *merged=[snapshot mutableCopy];
   merged[@"deferredTasks"]=@{@"begun":@(GSDeferredTotal),@"open":@(GSDeferred.count),@"handedBack":@(GSHandedBackTotal),@"handedBackOpen":@(GSHandedBack.count)};
   snapshot=merged;
  }
 }
#endif
 return snapshot;
}
