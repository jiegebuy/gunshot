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

@interface NSObject (GSUploadLiveActivityABI)
+ (void)startWithIdentifier:(NSString *)identifier language:(NSString *)language;
+ (void)updateWithPayload:(NSDictionary *)payload;
+ (void)markUnavailable;
+ (void)finishWithSuccess:(BOOL)success;
+ (NSDictionary *)snapshot;
@end

static NSDictionary *GSSnapshot;
#if GS_JAILED
static id<GSContinuedTask> GSTask;
static NSString *GSIdentifier;
static NSString *GSCurrentUploadID;
static NSTimer *GSTimer;
static UIBackgroundTaskIdentifier GSShortTask;
static NSUInteger GSEpoch,GSCount;
// Leave room for measured byte movement during long originals. The old 1,000
// units per phase could fill after ~33 minutes and stop reporting real work.
static const int64_t GSProgressScale=1000000;
static int64_t GSProgressUnits;
static NSTimeInterval GSLastProgress;
static unsigned long long GSExportedBytes,GSCloudProgressUnits,GSStagedBytes,GSSourceReadBytes,GSScannedItems,GSUploadBytes;
static BOOL GSPolling,GSUploadBaseline;
static Class GSVisualBridge;
static NSDictionary *GSVisualSnapshot;
static void GSVisualRecord(void){
 @synchronized(GSBackgroundUploadChanged){GSVisualSnapshot=GSVisualBridge?[GSVisualBridge snapshot]:@{@"status":@"unavailable",@"active":@NO};}
}
static void GSStartVisualActivity(NSUInteger epoch){
#if !GS_TEST_BACKGROUND
 static dispatch_once_t once;dispatch_once(&once,^{
  NSString *framework=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"GoToHPActivity.framework/GoToHPActivity"];
  if([NSBundle.mainBundle objectForInfoDictionaryKey:@"NSSupportsLiveActivities"]&&[NSFileManager.defaultManager fileExistsAtPath:framework]){
   dlopen(framework.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
   GSVisualBridge=NSClassFromString(@"GSUploadLiveActivity");
  }
 });
#endif
 [GSVisualBridge startWithIdentifier:[NSString stringWithFormat:@"%lu",(unsigned long)epoch] language:GSLanguage()];GSVisualRecord();
}
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
@property UIBackgroundTaskIdentifier identifier,local;
@property(copy) void (^handler)(void);
@property(copy) NSString *name,*caller;
@property NSUInteger generation;
@property BOOL expired,ended;
@end
@implementation GSTaskRecord @end
static const UIBackgroundTaskIdentifier GSDeferredBase=(UIBackgroundTaskIdentifier)1<<40;
static NSObject *GSDeferredLock;
static BOOL GSDeferring,GSExpiring;
static NSMutableDictionary<NSNumber *,GSTaskRecord *> *GSDeferred,*GSHandedBack,*GSLive;
static NSMutableDictionary<NSString *,NSNumber *> *GSForcedCallers;
static NSMutableSet<NSNumber *> *GSForcedIDs;
static NSUInteger GSBudgetGeneration,GSDeferredNext,GSDeferredTotal,GSHandedBackTotal,GSForcedEnds,GSLateExpired,GSExpiryWindows,GSRejectedLate;
static UIBackgroundTaskIdentifier (*GSOriginalBeginNamed)(id,SEL,NSString *,void (^)(void));
static UIBackgroundTaskIdentifier (*GSOriginalBegin)(id,SEL,void (^)(void));
static void (*GSOriginalEnd)(id,SEL,UIBackgroundTaskIdentifier);
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
static GSTaskRecord *GSNewTask(NSString *name,void (^handler)(void)){
 GSTaskRecord *record=[GSTaskRecord new];record.identifier=UIBackgroundTaskInvalid;record.name=name;record.handler=handler;
 NSArray *stack=NSThread.callStackReturnAddresses;
 record.caller=GSCallerKey([stack subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)12,stack.count))]);
 return record;
}
static void GSCloseBudget(void){
 // Caller holds GSDeferredLock. The generation also rejects begins still inside UIKit.
 if(!GSExpiring){GSExpiring=YES;GSBudgetGeneration++;GSExpiryWindows++;}
}
static void GSCountForced(GSTaskRecord *record){
 @synchronized(GSDeferredLock){
  GSForcedEnds++;NSString *key=record.caller;
  if(GSForcedCallers[key]||GSForcedCallers.count<16)GSForcedCallers[key]=@([GSForcedCallers[key]unsignedIntegerValue]+1);
 }
}
static void GSDeliverExpirations(NSArray *handlers){
 if(!handlers.count)return;
 void (^deliver)(void)=^{for(void (^handler)(void) in handlers)handler();};
 if(NSThread.isMainThread)deliver();else dispatch_async(dispatch_get_main_queue(),deliver);
}
static NSArray *GSReleaseExpired(NSArray<GSTaskRecord *> *records,GSTaskRecord *trigger){
 NSMutableArray *released=[NSMutableArray array],*handlers=[NSMutableArray array];
 @synchronized(GSDeferredLock){
  for(GSTaskRecord *record in records){
   if(record.ended)continue;
   record.expired=YES;record.ended=YES;if(record!=trigger)GSLateExpired++;
   [GSLive removeObjectForKey:@(record.identifier)];
   if(record.local)[GSHandedBack removeObjectForKey:@(record.local)];else [GSForcedIDs addObject:@(record.identifier)];
   if(record.handler)[handlers addObject:record.handler];record.handler=nil;
   [released addObject:record];
  }
 }
 // Release every raw assertion before running any owner code or diagnostic aggregation.
 for(GSTaskRecord *record in released)GSOriginalEnd(UIApplication.sharedApplication,@selector(endBackgroundTask:),record.identifier);
 for(GSTaskRecord *record in released)GSCountForced(record);
 return handlers;
}
static void GSExpireTask(GSTaskRecord *record){
 NSArray *open;
 @synchronized(GSDeferredLock){
  if(record.ended||record.expired)return;
  record.expired=YES;
  if(record.identifier==UIBackgroundTaskInvalid&&record.generation!=GSBudgetGeneration)return;
  GSCloseBudget();open=GSLive.allValues;
 }
 // Pending IDs are settled by the returning begin call, never by a main-queue retry.
 GSDeliverExpirations(GSReleaseExpired(open,record));
}
static UIBackgroundTaskIdentifier GSCreateReal(id app,BOOL named,GSTaskRecord *record){
 @synchronized(GSDeferredLock){
  if(record.ended)return UIBackgroundTaskInvalid;
  if(GSExpiring||record.expired||(record.local&&record.generation!=GSBudgetGeneration)){GSRejectedLate++;record.expired=YES;return UIBackgroundTaskInvalid;}
  record.generation=GSBudgetGeneration;
 }
 void (^expire)(void)=^{GSExpireTask(record);};
 UIBackgroundTaskIdentifier real=named?GSOriginalBeginNamed(app,@selector(beginBackgroundTaskWithName:expirationHandler:),record.name,expire):
  GSOriginalBegin(app,@selector(beginBackgroundTaskWithExpirationHandler:),expire);
 if(real==UIBackgroundTaskInvalid)return real;
 BOOL rejected;
 @synchronized(GSDeferredLock){
  rejected=record.ended||GSExpiring||record.expired||record.generation!=GSBudgetGeneration;
  if(rejected){record.expired=YES;GSRejectedLate++;}
  else{record.identifier=real;GSLive[@(real)]=record;[GSForcedIDs removeObject:@(real)];}
 }
 if(rejected){
  // UIKit begin/end are thread-safe. An unpublished ID has no owner to notify.
  GSOriginalEnd(app,@selector(endBackgroundTask:),real);GSCountForced(record);return UIBackgroundTaskInvalid;
 }
 return real;
}
static UIBackgroundTaskIdentifier GSBeginTask(id app,BOOL named,NSString *name,void (^handler)(void)){
 @synchronized(GSDeferredLock){if(!GSDeferring&&GSExpiring){GSRejectedLate++;return UIBackgroundTaskInvalid;}}
 GSTaskRecord *record=GSNewTask(name,handler);
 @synchronized(GSDeferredLock){
  if(GSDeferring){
   record.local=GSDeferredBase+(++GSDeferredNext);GSDeferredTotal++;GSDeferred[@(record.local)]=record;return record.local;
  }
 }
 UIBackgroundTaskIdentifier real=GSCreateReal(app,named,record);
 if(real==UIBackgroundTaskInvalid)@synchronized(GSDeferredLock){record.ended=YES;record.handler=nil;}
 return real;
}
static UIBackgroundTaskIdentifier GSBeginNamed(id app,SEL selector,NSString *name,void (^handler)(void)){
 return GSBeginTask(app,YES,name,handler);
}
static UIBackgroundTaskIdentifier GSBegin(id app,SEL selector,void (^handler)(void)){
 return GSBeginTask(app,NO,nil,handler);
}
static void GSEnd(id app,SEL selector,UIBackgroundTaskIdentifier identifier){
 if(identifier==UIBackgroundTaskInvalid)return;
 @synchronized(GSDeferredLock){
  GSTaskRecord *record;
  if(identifier>=GSDeferredBase){
   record=GSDeferred[@(identifier)]?:GSHandedBack[@(identifier)];
   if(!record)return;
   [GSDeferred removeObjectForKey:@(identifier)];[GSHandedBack removeObjectForKey:@(identifier)];
   identifier=record.identifier;
  }else{
   if([GSForcedIDs containsObject:@(identifier)])return;
   record=GSLive[@(identifier)];
  }
  if(record.ended)return;
  record.ended=YES;record.handler=nil;
  if(identifier==UIBackgroundTaskInvalid)return; // An in-flight hand-back will release its own raw ID.
  [GSLive removeObjectForKey:@(identifier)];
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
   @synchronized(GSDeferredLock){GSExpiring=NO;GSBudgetGeneration++;}
  }];
  GSOriginalEnd=(void *)method_setImplementation(end,(IMP)GSEnd);
  GSOriginalBeginNamed=(void *)method_setImplementation(named,(IMP)GSBeginNamed);
  GSOriginalBegin=(void *)method_setImplementation(plain,(IMP)GSBegin);
  installed=YES;
 });
 return installed;
}
static NSArray<GSTaskRecord *> *GSDetachDeferredTasks(void){
 @synchronized(GSDeferredLock){
  GSDeferring=NO;NSArray *tasks=GSDeferred.allValues;
  // A reentrant replacement must not lend its fresh budget to this detached hand-back.
  for(GSTaskRecord *record in tasks)record.generation=GSBudgetGeneration;
  [GSHandedBack addEntriesFromDictionary:GSDeferred];[GSDeferred removeAllObjects];return tasks;
 }
}
static void GSFinishDeferredTasks(NSArray<GSTaskRecord *> *tasks,BOOL expired){
 for(GSTaskRecord *record in tasks){
  if(!expired&&GSCreateReal(UIApplication.sharedApplication,YES,record)!=UIBackgroundTaskInvalid){
   @synchronized(GSDeferredLock){GSHandedBackTotal++;}
  }else{
   void (^handler)(void)=nil;
   @synchronized(GSDeferredLock){
    if(!record.ended){record.ended=YES;record.expired=YES;handler=record.handler;record.handler=nil;}
    [GSHandedBack removeObjectForKey:@(record.local)];
   }
   if(handler)handler();
  }
 }
}
static void GSBackgroundRecord(NSDictionary *state){
 NSMutableDictionary *record=[state mutableCopy];
 record[@"progress"]=@{@"completed":@(GSProgressUnits),@"total":@((int64_t)GSCount*GSProgressScale*2),
  @"secondsSinceMovement":@(GSLastProgress?MAX(0,NSProcessInfo.processInfo.systemUptime-GSLastProgress):0)};
 @synchronized(GSBackgroundUploadChanged){GSSnapshot=[record copy];}
 [NSNotificationCenter.defaultCenter postNotificationName:GSBackgroundUploadChanged object:nil];
}
static void GSEndShortTask(void){
 UIBackgroundTaskIdentifier task=GSShortTask;GSShortTask=UIBackgroundTaskInvalid;
 if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];
}
static NSUInteger GSFinishBackgroundWithExpiry(BOOL success,NSString *status,BOOL expired){
 NSUInteger epoch=++GSEpoch;[GSTimer invalidate];GSTimer=nil;GSPolling=NO;
 id<GSContinuedTask> task=GSTask;GSTask=nil;
 [GSVisualBridge finishWithSuccess:success];GSVisualRecord();
 NSString *identifier=GSIdentifier;GSIdentifier=nil;
 UIBackgroundTaskIdentifier shortTask=GSShortTask;GSShortTask=UIBackgroundTaskInvalid;
 NSArray *deferred=GSDetachDeferredTasks(),*open=nil;
 if(expired&&UIApplication.sharedApplication.applicationState==UIApplicationStateBackground){
  @synchronized(GSDeferredLock){GSCloseBudget();open=GSLive.allValues;}
 }
 task.expirationHandler=nil;
 NSArray *handlers=GSReleaseExpired(open,nil);
 if(identifier)[[NSClassFromString(@"BGTaskScheduler") sharedScheduler] cancelTaskRequestWithIdentifier:identifier];
 if(expired&&epoch==GSEpoch)GSStopBatchImport(YES);
 GSDeliverExpirations(handlers);
 GSFinishDeferredTasks(deferred,expired);
 // Everything above can reenter and start a replacement; only detached old state is released below.
 if(task)[task setTaskCompletedWithSuccess:success];
 if(shortTask!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:shortTask];
 if(epoch==GSEpoch)GSBackgroundRecord(@{@"granted":@NO,@"status":status});
 return epoch;
}
static NSUInteger GSFinishBackground(BOOL success,NSString *status){return GSFinishBackgroundWithExpiry(success,status,NO);}
static int64_t GSBackgroundTotal(void){return (int64_t)MAX((NSUInteger)1,MIN(GSCount,(NSUInteger)(INT64_MAX/(GSProgressScale*2))))*GSProgressScale*2;}
static void GSReportProgress(int64_t units){
 if(units>GSProgressUnits)GSLastProgress=NSProcessInfo.processInfo.systemUptime;
 GSProgressUnits=units;
 if(GSTask.progress.completedUnitCount!=units)GSTask.progress.completedUnitCount=units;
 @synchronized(GSBackgroundUploadChanged){
  NSMutableDictionary *record=[GSSnapshot mutableCopy];
  record[@"progress"]=@{@"completed":@(units),@"total":@(GSBackgroundTotal()),
   @"secondsSinceMovement":@(GSLastProgress?MAX(0,NSProcessInfo.processInfo.systemUptime-GSLastProgress):0)};
  GSSnapshot=record;
 }
}
static void GSUpdatePreparationProgress(void){
 if(!GSTask)return;
 NSDictionary *batch=GSBatchImportSnapshot();
 unsigned long long bytes=[batch[@"exportedBytes"]unsignedLongLongValue],cloud=[batch[@"cloudProgressUnits"]unsignedLongLongValue];
 unsigned long long staged=[batch[@"stagedBytes"]unsignedLongLongValue];
 unsigned long long received=[batch[@"sourceReadBytes"]unsignedLongLongValue];
 unsigned long long scanned=[batch[@"scannedItems"]unsignedLongLongValue];
 BOOL moved=bytes>GSExportedBytes||cloud>GSCloudProgressUnits||staged>GSStagedBytes||received>GSSourceReadBytes||scanned>GSScannedItems;
 GSExportedBytes=MAX(GSExportedBytes,bytes);GSCloudProgressUnits=MAX(GSCloudProgressUnits,cloud);GSStagedBytes=MAX(GSStagedBytes,staged);
 GSScannedItems=MAX(GSScannedItems,scanned);
 GSSourceReadBytes=MAX(GSSourceReadBytes,received);
 int64_t prepared=(int64_t)MIN(GSCount,[batch[@"processed"]unsignedIntegerValue])*GSProgressScale;
 GSReportProgress(MIN(GSBackgroundTotal()-1,MAX(GSProgressUnits+(moved?1:0),prepared)));
}
static NSString *GSUploadActivitySubtitle(NSDictionary *item){
 NSString *state=item[@"state"];
 int64_t sent=MAX((int64_t)0,[item[@"uploaded"]longLongValue]),total=MAX((int64_t)0,[item[@"total"]longLongValue]);
 if(total>0)sent=MIN(sent,total);
 NSString *bytes=[NSByteCountFormatter stringFromByteCount:sent countStyle:NSByteCountFormatterCountStyleFile];
 NSString *amount=total>0?[NSString stringWithFormat:@"%ld%% · %@ / %@",(long)(100.0*(double)sent/(double)total),bytes,[NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile]]:bytes;
 NSString *phase=[item[@"measurement"]isEqual:@"acknowledged"]?GSL(@"Server received"):GSL(@"Sent");
 if([state isEqual:@"committing"]||([state isEqual:@"uploading"]&&total>0&&sent==total))phase=GSL(@"Waiting for server confirmation");
 else if([state isEqual:@"retrying"])phase=GSL(@"Retrying upload");
 else if([state isEqual:@"waiting_source"])phase=GSL(@"Waiting for original data");
 else if([state isEqual:@"preparing"])return GSL(@"Preparing uploads");
 return [NSString stringWithFormat:@"%@ · %@",phase,amount];
}
static void GSPollBackground(void){
 // PhotoKit and queue-copy progress must reach dasd even while the upload service is busy.
 GSUpdatePreparationProgress();
 if(GSPolling)return;GSPolling=YES;NSUInteger epoch=GSEpoch;
 NSString *preferred=GSCurrentUploadID?:@"";
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  // Read the producer first: a finished batch has sealed its last job before
  // we inspect the queue. Reversing these reads can observe an empty queue
  // just before the final seal and prematurely release the background grant.
  NSDictionary *batch=GSBatchImportSnapshot();
  NSDictionary *summary=GSRequest(@{@"op":@"upload_activity",@"id":preferred},nil);
  NSUInteger outstanding=0;
  for(NSDictionary *profile in [summary[@"profiles"]allValues])for(NSString *key in @[@"importing",@"pending",@"preparing",@"uploading",@"committing"])
   outstanding+=[profile[@"states"][key]unsignedIntegerValue];
  dispatch_async(dispatch_get_main_queue(),^{
   if(epoch!=GSEpoch)return;GSPolling=NO;
   NSString *reason=batch[@"stopReason"];
   if([reason isEqual:@"account_changed"]||[reason isEqual:@"background_expired"]||[summary[@"conditions"][@"paused"]boolValue]){GSFinishBackground(NO,@"stopped");return;}
   if(!summary){
    // Never present an old file's percentage as a fresh reading.
    [GSTask updateTitle:@"GoToHP" subtitle:GSL(@"Upload progress unavailable")];
    [GSVisualBridge markUnavailable];GSVisualRecord();
    return; // An unavailable service is never treated as completion.
   }
   BOOL finished=![batch[@"active"]boolValue]&&outstanding==0;
   NSUInteger prepared=MIN(GSCount,[batch[@"processed"]unsignedIntegerValue]);
   NSUInteger uploaded=prepared>outstanding?prepared-outstanding:0;
   [GSVisualBridge updateWithPayload:summary];GSVisualRecord();
   if(GSTask){
    // Item counts can stand still during a large upload; only moving bytes
    // advance intermediate units. A waiting preparation is not progress.
    const int64_t scale=GSProgressScale,total=GSBackgroundTotal();
    unsigned long long bytes=[summary[@"transport"][@"uploadBodyBytesRead"]unsignedLongLongValue];
    BOOL active=GSUploadBaseline&&bytes>GSUploadBytes;GSUploadBytes=bytes;GSUploadBaseline=YES;
    BOOL allPrepared=finished&&!reason.length&&[batch[@"remaining"]unsignedIntegerValue]==0&&[batch[@"failed"]unsignedIntegerValue]==0;
    GSTask.progress.totalUnitCount=total;
    GSReportProgress(allPrepared?total:MIN(total-1,MAX(GSProgressUnits+(active?1:0),(int64_t)(prepared+uploaded)*scale)));
    // NSProgress covers the whole preparation/upload grant. The per-file
    // percentage is independent of those scheduling units and uses real bytes.
    NSDictionary *item=summary[@"currentUpload"];
    GSCurrentUploadID=item[@"id"];
    if(item){
     NSString *name=item[@"name"]?:@"GoToHP";
     name=[[name componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet]componentsJoinedByString:@" "];
     NSString *title=[item[@"livePhoto"]boolValue]?[NSString stringWithFormat:GSL(@"Live Photo · %@"),name]:name;
     [GSTask updateTitle:title subtitle:GSUploadActivitySubtitle(item)];
    }else [GSTask updateTitle:@"GoToHP" subtitle:[NSString stringWithFormat:GSL(@"Prepared %lu / %lu · %lu pending"),(unsigned long)prepared,(unsigned long)GSCount,(unsigned long)outstanding]];
   }
   if(finished)GSFinishBackground(!reason.length&&[batch[@"remaining"]unsignedIntegerValue]==0&&[batch[@"failed"]unsignedIntegerValue]==0,reason?:@"finished");
  });
 }});
}
#endif
void GSBeginBackgroundUpload(NSUInteger count){
#if GS_JAILED
 NSCAssert(NSThread.isMainThread,@"Start a user-requested background upload on main");
 static dispatch_once_t once;dispatch_once(&once,^{GSShortTask=UIBackgroundTaskInvalid;});
 if(!count)return;
 NSUInteger epoch=GSFinishBackground(NO,@"replaced");if(epoch!=GSEpoch)return;
 GSCount=MIN(count,(NSUInteger)(INT64_MAX/(GSProgressScale*2)));GSProgressUnits=0;GSLastProgress=0;GSExportedBytes=0;GSCloudProgressUnits=0;GSStagedBytes=0;GSScannedItems=0;
 GSSourceReadBytes=0;
 GSUploadBytes=0;GSUploadBaseline=NO;
 GSCurrentUploadID=nil;
 GSStartVisualActivity(epoch);
 GSBackgroundRecord(@{@"granted":@NO,@"status":@"foreground_only"});if(epoch!=GSEpoch)return;
 UIBackgroundTaskIdentifier shortTask=[UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
  if(epoch!=GSEpoch)return;
  GSEndShortTask();
  if(!GSTask)GSFinishBackgroundWithExpiry(NO,@"expired",YES);
 }];
 if(epoch!=GSEpoch){[UIApplication.sharedApplication endBackgroundTask:shortTask];return;}
 GSShortTask=shortTask;
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
   if(GSTask){if(GSTask!=task)[task setTaskCompletedWithSuccess:NO];return;}
   GSTask=task;task.progress.totalUnitCount=GSBackgroundTotal();task.progress.completedUnitCount=GSProgressUnits;
   if(deferrable)@synchronized(GSDeferredLock){GSDeferring=YES;GSExpiring=NO;GSBudgetGeneration++;}
   __weak id<GSContinuedTask> owner=task;
   task.expirationHandler=^{
    void (^expire)(void)=^{if(epoch==GSEpoch&&owner&&GSTask==owner)GSFinishBackgroundWithExpiry(NO,@"expired",YES);};
    if(NSThread.isMainThread)expire();else dispatch_async(dispatch_get_main_queue(),expire);
   };
   GSBackgroundRecord(@{@"granted":@YES,@"status":@"running"});if(epoch!=GSEpoch)return;
   GSEndShortTask();GSPollBackground();
  }];
  if(epoch!=GSEpoch)return;
  if(registered){
   id<GSContinuedRequest> request=[(id<GSContinuedRequest>)[requestClass alloc] initWithIdentifier:GSIdentifier title:@"GoToHP" subtitle:GSL(@"Preparing uploads")];
   NSError *error=nil;
   BOOL accepted=[scheduler submitTaskRequest:request error:&error];
   if(epoch!=GSEpoch)return;
   if(!GSTask)GSBackgroundRecord(@{@"granted":@NO,@"status":accepted?@"requested":@"rejected",@"errorCode":@(error.code)});
  }else GSBackgroundRecord(@{@"granted":@NO,@"status":@"registration_failed"});
 }
 if(epoch==GSEpoch){
  GSTimer=[NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){if(epoch==GSEpoch)GSPollBackground();}];
  [NSRunLoop.mainRunLoop addTimer:GSTimer forMode:NSRunLoopCommonModes];
 }
#endif
}
void GSInstallBackgroundTaskGuard(void){
#if GS_JAILED
 GSInstallDeferredTasks();
#endif
}
NSDictionary *GSBackgroundUploadSnapshot(void){
 NSDictionary *snapshot;
 @synchronized(GSBackgroundUploadChanged){
  snapshot=GSSnapshot?:@{@"granted":@NO,@"status":@"idle"};
#if GS_JAILED
  if(GSVisualSnapshot){NSMutableDictionary *merged=[snapshot mutableCopy];merged[@"visualActivity"]=GSVisualSnapshot;snapshot=merged;}
#endif
 }
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
