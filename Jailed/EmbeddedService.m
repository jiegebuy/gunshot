#import "../Shared/GSLocalization.h"
#include <limits.h>
#import "../Shared/IPCProtocol.h"
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import "libgotohp.h"
#import "GSRequestRole.h"
#import "../UI/GSNativeAccount.h"

// No external IPC in the jailed host. SSO can wait on main, so runtime snapshots
// must never wait on the core queue (including when exporting diagnostics).
static dispatch_queue_t GSCoreQueue;
static BOOL GSReady;
static nw_path_monitor_t GSMonitor;
static NSLock *GSStateLock;
static NSMutableDictionary *GSState;
static void GSStateInitialize(void) {
 static dispatch_once_t once;dispatch_once(&once,^{
  GSStateLock=[NSLock new];
  GSState=[@{@"coreReady":@NO,@"conditionsAccepted":@NO,@"foreground":@NO,@"path":@"unknown",@"networkOnline":@NO,@"wifi":@NO,@"charging":@NO,@"authorization":@"not_checked"} mutableCopy];
 });
}
static void GSRecord(NSDictionary *values) {
 GSStateInitialize();[GSStateLock lock];[GSState addEntriesFromDictionary:values];[GSStateLock unlock];
}
NSDictionary *GSEmbeddedRuntimeSnapshot(void) {
 GSStateInitialize();[GSStateLock lock];NSDictionary *snapshot=[GSState copy];[GSStateLock unlock];return snapshot;
}
static NSDictionary *GSCall(NSDictionary *request,const char *role) {
 NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
 if(!data||data.length>GS_MAX_JSON){GSRecord(@{@"lastRequestFailure":@{@"op":request[@"op"]?:@"unknown",@"code":data?@"request_too_large":@"serialization_failed",@"jsonBytes":@(data.length)}});return nil;}
 NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 char *raw=GunshotRequest((char *)json.UTF8String,(char *)role);
 if(!raw){GSRecord(@{@"lastRequestFailure":@{@"op":request[@"op"]?:@"unknown",@"code":@"empty_reply"}});return nil;}
 NSData *reply=[NSData dataWithBytes:raw length:strlen(raw)];GunshotFree(raw);
 id parsed=[NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
 if(![parsed isKindOfClass:NSDictionary.class]||![parsed[@"ok"]boolValue]){
  // Only record protocol error codes, never request bodies or photo contents.
  NSString *code=[parsed isKindOfClass:NSDictionary.class]?parsed[@"error"]:nil;
  if(![@[@"invalid_request",@"unauthorized",@"internal_error",@"not_initialized"]containsObject:code?:@""])code=@"request_failed";
  GSRecord(@{@"lastRequestFailure":@{@"op":request[@"op"]?:@"unknown",@"code":code}});return nil;
 }
 return parsed[@"data"]==NSNull.null?@{}:parsed[@"data"];
}
static void GSConditions(void) {
 NSDictionary *state=GSEmbeddedRuntimeSnapshot();
 if(!GSReady)return;
 // ObjC relational/logical expressions have type int: @(a && b) becomes JSON
 // 1/0, which Go correctly rejects for a bool field. Always box real booleans.
 NSDictionary *result=GSCall(@{@"op":@"conditions",@"online":([state[@"foreground"]boolValue]&&[state[@"networkOnline"]boolValue])?@YES:@NO,@"wifi":[state[@"wifi"]boolValue]?@YES:@NO,@"charging":[state[@"charging"]boolValue]?@YES:@NO},"daemon");
 GSRecord(@{@"conditionsAccepted":result?@YES:@NO});
}
static void GSSampleApplication(void) {
 // Scene lifecycle matters for scene-based hosts and container guests. Inactive
 // foreground scenes still count, e.g. while a system sheet is presented.
 BOOL foreground=UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground;
 for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
  if(scene.activationState==UISceneActivationStateForegroundActive||scene.activationState==UISceneActivationStateForegroundInactive){foreground=YES;break;}
 UIDeviceBatteryState state=UIDevice.currentDevice.batteryState;
 GSRecord(@{@"foreground":@(foreground),@"charging":(state==UIDeviceBatteryStateCharging||state==UIDeviceBatteryStateFull)?@YES:@NO});
 dispatch_async(GSCoreQueue,^{GSConditions();});
}
static void GSStart(void) {
 static dispatch_once_t once;dispatch_once(&once,^{
 GSStateInitialize();GSCoreQueue=dispatch_queue_create("dev.tqmane.gunshot.embedded",DISPATCH_QUEUE_SERIAL);
 NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
 NSURL *root=[support URLByAppendingPathComponent:@"GoToHP" isDirectory:YES];
 dispatch_async(GSCoreQueue,^{
 if(!root||![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil])return;
 [root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
 GunshotSetHostBearerProvider((uintptr_t)&GSNativeBearer);
 GSReady=GunshotInitialize((char *)root.path.UTF8String)==0;
 GSRecord(@{@"coreReady":@(GSReady)});GSConditions();
 });
 dispatch_async(dispatch_get_main_queue(),^{
 UIDevice.currentDevice.batteryMonitoringEnabled=YES;
 for(NSString *name in @[UIApplicationDidBecomeActiveNotification,UIApplicationDidEnterBackgroundNotification,UIApplicationWillEnterForegroundNotification,UISceneDidActivateNotification,UISceneWillDeactivateNotification,UISceneDidEnterBackgroundNotification,UISceneWillEnterForegroundNotification,UIDeviceBatteryStateDidChangeNotification])
  [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){GSSampleApplication();}];
 GSSampleApplication();
 });
 GSMonitor=nw_path_monitor_create();
 nw_path_monitor_set_update_handler(GSMonitor,^(nw_path_t path){
  nw_path_status_t status=nw_path_get_status(path);
  GSRecord(@{@"path":status==nw_path_status_satisfied?@"satisfied":status==nw_path_status_satisfiable?@"requires_connection":@"unsatisfied",@"networkOnline":status==nw_path_status_satisfied?@YES:@NO,@"wifi":@(nw_path_uses_interface_type(path,nw_interface_type_wifi))});
  dispatch_async(GSCoreQueue,^{GSConditions();});
 });
 // Do not starve path callbacks behind SSO / Google endpoint validation.
 nw_path_monitor_set_queue(GSMonitor,dispatch_queue_create("dev.tqmane.gunshot.network",DISPATCH_QUEUE_SERIAL));nw_path_monitor_start(GSMonitor);
 });
}
BOOL GSEmbeddedAppend(NSString *identifier,NSUInteger index,unsigned long long offset,NSData *data,NSError **error) {
 GSStart();__block BOOL accepted=NO;
 if(identifier.length&&index<2&&offset<=LLONG_MAX&&data.length>0&&data.length<=1048576){
  dispatch_sync(GSCoreQueue,^{
   if(GSReady)accepted=GunshotAppend((char *)identifier.UTF8String,(int)index,(long long)offset,(void *)data.bytes,(int)data.length)==1;
  });
 }
 if(!accepted){
  GSRecord(@{@"lastRequestFailure":@{@"op":@"append",@"code":@"binary_append_failed"}});
  if(error)*error=[NSError errorWithDomain:@"Gunshot.IPC" code:1 userInfo:@{NSLocalizedDescriptionKey:GSL(@"GoToHP request failed. Check the account, storage and queue in this app.")}];
 }
 return accepted;
}
NSDictionary *GSRequest(NSDictionary *request,NSError **error) {
 GSStart();
 // Repair missed lifecycle notifications when a settings page starts polling.
 if(NSThread.isMainThread)GSSampleApplication();else dispatch_async(dispatch_get_main_queue(),^{GSSampleApplication();});
 __block NSDictionary *result=nil;
 dispatch_sync(GSCoreQueue,^{
 if(!GSReady)return;
 NSString *op=request[@"op"];
 if([op isEqual:@"conditions"])return;
 GSConditions();
 BOOL native=[op isEqual:@"account_native"];
 if(native)GSRecord(@{@"authorization":@"checking"});
 result=GSCall(request,GSEmbeddedRequestRole(op.UTF8String));
 if(result&&[op isEqual:@"upload_summary"])GSRecord(@{@"uploadSummary":result});
 if(native)GSRecord(@{@"authorization":result?@"validated":@"failed"});
 });
 if(!result&&error)*error=[NSError errorWithDomain:@"Gunshot.IPC" code:1 userInfo:@{NSLocalizedDescriptionKey:GSL(@"GoToHP request failed. Check the account, storage and queue in this app.")}];
 return result;
}
