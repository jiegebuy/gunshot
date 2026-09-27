#import "GSBackgroundUpload.h"
#import "GSBatchImport.h"
#import "../Shared/IPCProtocol.h"
#if GS_TEST_BACKGROUND
#import "../tests/background_upload_shim.h"
#else
#import <UIKit/UIKit.h>
#endif
#include <dlfcn.h>

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
static id<GSContinuedTask> GSTask;
static NSString *GSIdentifier;
static NSTimer *GSTimer;
static UIBackgroundTaskIdentifier GSShortTask=UIBackgroundTaskInvalid;
static NSUInteger GSEpoch,GSCount;
static BOOL GSPolling;
NSDictionary *GSBackgroundUploadSnapshot(void){@synchronized(GSBackgroundUploadChanged){return GSSnapshot?:@{@"granted":@NO,@"status":@"idle"};}}
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
 if(task){task.expirationHandler=nil;[task setTaskCompletedWithSuccess:success];}
 GSEndShortTask();
}
static void GSPollBackground(void){
 if(GSPolling)return;GSPolling=YES;NSUInteger epoch=GSEpoch;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  NSDictionary *summary=GSRequest(@{@"op":@"upload_summary"},nil);
  NSDictionary *batch=GSBatchImportSnapshot();
  NSUInteger outstanding=0;
  for(NSDictionary *profile in [summary[@"profiles"]allValues])for(NSString *key in @[@"importing",@"pending",@"preparing",@"uploading",@"committing"])
   outstanding+=[profile[@"states"][key]unsignedIntegerValue];
  dispatch_async(dispatch_get_main_queue(),^{
   GSPolling=NO;if(epoch!=GSEpoch)return;
   if([batch[@"stage"]isEqual:@"stopped"]||[summary[@"conditions"][@"paused"]boolValue]){GSFinishBackground(NO,@"stopped");return;}
   if(!summary)return; // An unavailable service is never treated as completion.
   BOOL finished=![batch[@"active"]boolValue]&&outstanding==0;
   NSUInteger prepared=MIN(GSCount,[batch[@"processed"]unsignedIntegerValue]);
   NSUInteger uploaded=prepared>outstanding?prepared-outstanding:0;
   if(GSTask){
    GSTask.progress.totalUnitCount=MAX(1,GSCount*2);
    GSTask.progress.completedUnitCount=finished?GSCount*2:MIN(GSCount*2-1,prepared+uploaded);
    [GSTask updateTitle:@"GoToHP" subtitle:[NSString stringWithFormat:@"%lu / %lu · %lu pending",(unsigned long)prepared,(unsigned long)GSCount,(unsigned long)outstanding]];
   }
   if(finished)GSFinishBackground([batch[@"failed"]unsignedIntegerValue]==0,@"finished");
  });
 }});
}
void GSBeginBackgroundUpload(NSUInteger count){
 NSCAssert(NSThread.isMainThread,@"Start a user-requested background upload on main");
#if GS_JAILED
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
  GSIdentifier=[prefix stringByAppendingFormat:@".%@",NSUUID.UUID.UUIDString];
  BOOL registered=[scheduler registerForTaskWithIdentifier:GSIdentifier usingQueue:dispatch_get_main_queue() launchHandler:^(id<GSContinuedTask> task){
   if(epoch!=GSEpoch){[task setTaskCompletedWithSuccess:NO];return;}
   GSTask=task;
   task.expirationHandler=^{dispatch_async(dispatch_get_main_queue(),^{
    if(epoch!=GSEpoch)return;
    GSStopBatchImport(YES);GSFinishBackground(NO,@"expired");
   });};
   GSBackgroundRecord(@{@"granted":@YES,@"status":@"running"});GSEndShortTask();GSPollBackground();
  }];
  if(registered){
   id<GSContinuedRequest> request=[(id<GSContinuedRequest>)[requestClass alloc] initWithIdentifier:GSIdentifier title:@"GoToHP" subtitle:@"Preparing uploads"];
   NSError *error=nil;
   BOOL accepted=[scheduler submitTaskRequest:request error:&error];
   if(!GSTask)GSBackgroundRecord(@{@"granted":@NO,@"status":accepted?@"requested":@"rejected",@"errorCode":@(error.code)});
  }else GSBackgroundRecord(@{@"granted":@NO,@"status":@"registration_failed"});
 }
 GSTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){GSPollBackground();}];
#endif
}
