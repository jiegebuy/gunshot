#import "../Shared/GSPhotosCompatibility.h"
#import "../Shared/GSLocalization.h"
#import "GSBackupRequests.h"
#import "GSNativeRouting.h"
#import "GSNativeAccount.h"
#import "GSExporter.h"
#import "GSUploadMonitor.h"
#import "../Shared/IPCProtocol.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>

// Audited manual/automatic backup: Go commits, then native lookup confirms the
// remote item. Block native payload fallback; report success only after lookup.
@interface GSBackupTransfer : NSObject
@property(atomic) BOOL cancelled;
@property(atomic) BOOL cancelGo;
@property(atomic) BOOL cancelSharedJob;
@property(atomic) BOOL reconciling;
@property(atomic) BOOL finished;
@property(atomic) BOOL sourceRegistered;
@property(atomic) double progress;
@property(atomic,copy) NSString *jobID;
@property(nonatomic,copy) NSString *account;
// SSO userID string; native request credentials.accountID is a separate object.
@property(nonatomic,copy) NSString *identityIdentifier;
@property(nonatomic,copy) NSString *localID;
@end
@implementation GSBackupTransfer @end
static char GSTransferKey;
static BOOL GSInstalled;
static NSObject *GSLock;
static NSMutableDictionary *GSCounts;
// Each overlapping request owns one registration, even for the same asset.
static NSCountedSet *GSReconciling;
// Source registrations prevent one duplicate native request from cancelling a
// Go job that another request for the same PhotoKit asset is still observing.
static NSCountedSet *GSActiveSources;
static BOOL GSMethod(id object,NSString *name,const char *encoding){
 Method m=class_getInstanceMethod(object_getClass(object),NSSelectorFromString(name));return m&&!strcmp(method_getTypeEncoding(m),encoding);
}
static id GSGet(id object,NSString *name){return GSMethod(object,name,"@16@0:8")?((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)):nil;}
static void GSCount(NSString *key){@synchronized(GSLock){GSCounts[key]=@([GSCounts[key]unsignedIntegerValue]+1);}}
BOOL GSBackupRequestsAvailable(void){return GSInstalled;}
NSDictionary *GSBackupRequestsSnapshot(void){if(!GSInstalled)return @{@"available":@NO};@synchronized(GSLock){NSMutableDictionary *d=[GSCounts mutableCopy];d[@"available"]=@YES;d[@"enabled"]=GSNativeRoutingEnabled()?@YES:@NO;return d;}}
static void GSFail(id request,NSInteger code){
 NSError *error=[NSError errorWithDomain:@"GoToHP.Backup" code:code userInfo:@{NSLocalizedDescriptionKey:GSL(@"Check the GoToHP queue for details. Native upload has not been used.")}];
 if(GSPhotosCompletionForClass(object_getClass(request))==GSPhotosCompletionCode)
  // The legacy native API constructs an NSError from a numeric failure code.
  ((void(*)(id,SEL,BOOL,id,NSInteger))objc_msgSend)(request,NSSelectorFromString(GSPhotosAssetCompletion(object_getClass(request))),NO,nil,code);
 else if(GSMethod(request,@"didCompleteWithSuccess:resultantMediaItem:error:","v36@0:8B16@20@28"))
  ((void(*)(id,SEL,BOOL,id,id))objc_msgSend)(request,NSSelectorFromString(@"didCompleteWithSuccess:resultantMediaItem:error:"),NO,nil,error);
 else if(GSMethod(request,@"handleError:","v24@0:8@16"))
  ((void(*)(id,SEL,id))objc_msgSend)(request,NSSelectorFromString(@"handleError:"),error);
 else if(GSMethod(request,@"handleErrorWithCode:","v24@0:8q16"))
  ((void(*)(id,SEL,NSInteger))objc_msgSend)(request,NSSelectorFromString(@"handleErrorWithCode:"),code);
 else if(GSMethod(request,@"didCompleteWithError:resultantMediaItem:","v32@0:8@16@24"))
  ((void(*)(id,SEL,id,id))objc_msgSend)(request,NSSelectorFromString(@"didCompleteWithError:resultantMediaItem:"),error,nil);
}
static BOOL GSCanPrepare(NSDictionary *options){
#if GS_JAILED
 NSDictionary *runtime=GSEmbeddedRuntimeSnapshot();
 return options&&[runtime[@"conditionsAccepted"]boolValue]&&[runtime[@"foreground"]boolValue]&&[runtime[@"networkOnline"]boolValue]&&![options[@"paused"]boolValue]&&(![options[@"wifiOnly"]boolValue]||[runtime[@"wifi"]boolValue])&&(![options[@"chargingOnly"]boolValue]||[runtime[@"charging"]boolValue]);
#else
 // The daemon owns upload conditions. PhotoKit export still needs the host;
 // after seal, daemon execution must not depend on host foreground state.
 NSDictionary *conditions=GSRequest(@{@"op":@"upload_summary"},nil)[@"conditions"];
 return options&&GSUploadHostForeground()&&[conditions[@"online"]boolValue]&&![conditions[@"paused"]boolValue]&&(![options[@"wifiOnly"]boolValue]||[conditions[@"wifi"]boolValue])&&(![options[@"chargingOnly"]boolValue]||[conditions[@"charging"]boolValue]);
#endif
}
static BOOL GSStillAuthorized(GSBackupTransfer *transfer){
 return !transfer.cancelled&&GSNativeRoutingEnabled()&&[GSNativeRoutingAccount()isEqual:transfer.account]&&GSNativeIdentityMatches(transfer.identityIdentifier);
}
// GSLock must be held. Returns YES only when this transfer released the final
// observer for the source, making foreground cancellation of the shared job safe.
static BOOL GSReleaseSourceLocked(GSBackupTransfer *transfer){
 if(!transfer.sourceRegistered||!transfer.localID.length)return NO;
 NSUInteger count=[GSActiveSources countForObject:transfer.localID];
 [GSActiveSources removeObject:transfer.localID];transfer.sourceRegistered=NO;
 return count==1;
}
static void GSReportProgress(id request,GSBackupTransfer *transfer,NSDictionary *state){
 NSNumber *uploaded=state[@"uploaded"],*total=state[@"total"];
 if(![uploaded isKindOfClass:NSNumber.class]||![total isKindOfClass:NSNumber.class]||
    !isfinite(uploaded.doubleValue)||!isfinite(total.doubleValue)||total.doubleValue<=0)return;
 double progress=fmin(1,fmax(0,uploaded.doubleValue/total.doubleValue));
 dispatch_async(dispatch_get_main_queue(),^{
  if(transfer.cancelled||transfer.finished||transfer.reconciling||transfer.progress==progress)return;
  if(!GSNativeIdentityMatches(transfer.identityIdentifier)||!GSNativeAccountMatches(GSGet(GSGet(request,@"credentials"),@"accountID")))return;
  if(!GSMethod(request,@"progress","d16@0:8"))return;
  transfer.progress=progress;
  id delegate=GSGet(request,@"delegate");
  if(GSMethod(delegate,@"uploadRequestDidProgress:","v24@0:8@16")){
   ((void(*)(id,SEL,id))objc_msgSend)(delegate,NSSelectorFromString(@"uploadRequestDidProgress:"),request);
   GSCount(@"progressUpdates");
  }
 });
}
static void GSStart(id request,SEL selector,IMP original){
 GSBackupTransfer *existing=objc_getAssociatedObject(request,&GSTransferKey);
 if(existing){if(existing.reconciling)((void(*)(id,SEL))original)(request,selector);return;}
 if(!GSNativeRoutingEnabled()){((void(*)(id,SEL))original)(request,selector);return;}
 PHAsset *asset=GSGet(request,@"asset");
 // Capture only PhotoKit's stable identifier before hopping to our worker.
 // Retaining Google Photos' PHAsset proxy across queues is unsafe on 7.92/iPadOS 27.
 NSString *localIdentifier=[asset isKindOfClass:PHAsset.class]?[asset.localIdentifier copy]:nil;
 if(!localIdentifier.length){GSCount(@"unsupported");GSFail(request,1);return;}
 BOOL reconciling;@synchronized(GSLock){reconciling=[GSReconciling containsObject:localIdentifier];}
 if(reconciling){((void(*)(id,SEL))original)(request,selector);return;}
 GSBackupTransfer *transfer=[GSBackupTransfer new];transfer.localID=localIdentifier;
 @synchronized(GSLock){[GSActiveSources addObject:localIdentifier];transfer.sourceRegistered=YES;}
 objc_setAssociatedObject(request,&GSTransferKey,transfer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);GSCount(@"intercepted");
 dispatch_async(dispatch_get_main_queue(),^{
  NSDictionary *account=GSNativeAccountSummary();NSString *destination=GSNativeRoutingAccount();
  if(transfer.cancelled)return;
  if(![destination isEqual:account[@"email"]]||!GSNativeAccountMatches(GSGet(GSGet(request,@"credentials"),@"accountID"))){GSCount(@"accountMismatch");GSFail(request,2);return;}
  transfer.account=destination;transfer.identityIdentifier=account[@"identifier"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
   NSError *error=nil;
   NSDictionary *accounts=GSRequest(@{@"op":@"accounts"},&error);
   NSDictionary *options=error?nil:GSRequest(@{@"op":@"options"},&error);
   if(![accounts[@"selected"]isEqual:destination])error=[NSError errorWithDomain:@"GoToHP.Backup" code:2 userInfo:nil];
   NSDate *prepareDeadline=[NSDate dateWithTimeIntervalSinceNow:24*60*60];
   while(!error&&!transfer.cancelled&&!GSCanPrepare(options)&&prepareDeadline.timeIntervalSinceNow>0){
    [NSThread sleepForTimeInterval:1];options=GSRequest(@{@"op":@"options"},&error);
   }
   if(!GSCanPrepare(options))error=[NSError errorWithDomain:@"GoToHP.Backup" code:5 userInfo:nil];
   __block BOOL authorized=NO;
   dispatch_sync(dispatch_get_main_queue(),^{authorized=GSStillAuthorized(transfer);});
   if(!authorized){if(!error&&!transfer.cancelled)GSCount(@"authorizationChanged");error=[NSError errorWithDomain:@"GoToHP.Backup" code:2 userInfo:nil];}
   NSString *job=!error?GSImportPhotoIdentifierChecked(localIdentifier,destination,options[@"quality"]?:@"original",^BOOL{
    __block BOOL allowed=NO;dispatch_sync(dispatch_get_main_queue(),^{allowed=GSStillAuthorized(transfer);});return allowed;
   },&error):nil;
   dispatch_sync(dispatch_get_main_queue(),^{authorized=GSStillAuthorized(transfer);});
   if(job&&!authorized&&!transfer.cancelled)GSCount(@"authorizationChanged");
   if(!authorized&&job){
    BOOL last=NO;@synchronized(GSLock){last=GSReleaseSourceLocked(transfer);}
    if(last)GSRequest(@{@"op":@"cancel",@"id":job},nil);job=nil;
   }
   transfer.jobID=job;
   if(job&&transfer.cancelled&&transfer.cancelGo&&transfer.cancelSharedJob)GSRequest(@{@"op":@"cancel",@"id":job},nil);
   if(job)GSCount(@"queued");
   BOOL completed=NO;NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:24*60*60];
   while(job&&!transfer.cancelled&&deadline.timeIntervalSinceNow>0){@autoreleasepool{
    NSDictionary *state=GSRequest(@{@"op":@"job",@"id":job},&error);
    if(!state)break;
    GSReportProgress(request,transfer,state);
    NSString *phase=state[@"state"];
    if([phase isEqual:@"completed"]){completed=[state[@"mediaKey"]length]>0;break;}
    if([phase isEqual:@"failed"]||[phase isEqual:@"cancelled"])break;
    [NSThread sleepForTimeInterval:1];
   }}
   dispatch_async(dispatch_get_main_queue(),^{
    if(transfer.cancelled)return;
    if(!completed){GSCount(@"failed");GSFail(request,3);return;}
    if(!GSNativeIdentityMatches(transfer.identityIdentifier)||!GSNativeAccountMatches(GSGet(GSGet(request,@"credentials"),@"accountID"))){GSCount(@"authorizationChanged");GSFail(request,2);return;}
    // Refresh native backup state from the server; GSGuard blocks re-upload.
    @synchronized(GSLock){
     if(transfer.cancelled||transfer.finished)return;
     transfer.reconciling=YES;[GSReconciling addObject:transfer.localID];
    }
    GSCount(@"reconciling");((void(*)(id,SEL))original)(request,selector);
   });
  });
 });
}
static void GSReplace(Class c,SEL s,IMP replacement){Method m=class_getInstanceMethod(c,s);if(!class_addMethod(c,s,replacement,method_getTypeEncoding(m)))method_setImplementation(class_getInstanceMethod(c,s),replacement);}
static void GSFinish(id request,BOOL success){
 GSBackupTransfer *t=objc_getAssociatedObject(request,&GSTransferKey);
 @synchronized(GSLock){
  if(!t||t.finished)return;
  t.finished=YES;if(success)t.progress=1;
  GSReleaseSourceLocked(t);
  if(t.reconciling&&!t.cancelled)[GSReconciling removeObject:t.localID];
  if(t.reconciling)GSCount(success?@"nativeReconciled":@"reconcileFailed");
 }
}
static void GSBindCompletion(Class c,BOOL live){
 SEL s=NSSelectorFromString(live?@"didCompleteWithError:resultantMediaItem:":GSPhotosAssetCompletion(c));
 IMP old=method_getImplementation(class_getInstanceMethod(c,s));
 if(live)GSReplace(c,s,imp_implementationWithBlock(^(id request,id error,id result){GSFinish(request,error==nil);((void(*)(id,SEL,id,id))old)(request,s,error,result);}));
 else if(GSPhotosCompletionForClass(c)==GSPhotosCompletionCode)GSReplace(c,s,imp_implementationWithBlock(^(id request,BOOL success,id result,NSInteger code){GSFinish(request,success);((void(*)(id,SEL,BOOL,id,NSInteger))old)(request,s,success,result,code);}));
 else GSReplace(c,s,imp_implementationWithBlock(^(id request,BOOL success,id result,id error){GSFinish(request,success&&error==nil);((void(*)(id,SEL,BOOL,id,id))old)(request,s,success,result,error);}));
}
static BOOL GSRequestClassMatches(Class c){
 if(!c)return NO;
 for(NSArray *entry in @[@[@"start",@"v16@0:8"],@[@"cancel",@"v16@0:8"],@[@"shouldTimeout",@"B16@0:8"],@[@"didStart",@"B16@0:8"],@[@"asset",@"@16@0:8"],@[@"credentials",@"@16@0:8"]]){
  Method m=class_getInstanceMethod(c,NSSelectorFromString(entry[0]));if(!m||strcmp(method_getTypeEncoding(m),[entry[1]UTF8String]))return NO;
 }
 return YES;
}
static void GSBindStart(Class c){
 SEL s=NSSelectorFromString(@"start");IMP original=method_getImplementation(class_getInstanceMethod(c,s));
 GSReplace(c,s,imp_implementationWithBlock(^(id request){GSStart(request,s,original);}));
 SEL started=NSSelectorFromString(@"didStart");IMP oldStarted=method_getImplementation(class_getInstanceMethod(c,started));
 GSReplace(c,started,imp_implementationWithBlock(^BOOL(id request){GSBackupTransfer *t=objc_getAssociatedObject(request,&GSTransferKey);return t&&!t.reconciling&&!t.cancelled?YES:((BOOL(*)(id,SEL))oldStarted)(request,started);}));
 SEL timeout=NSSelectorFromString(@"shouldTimeout");IMP oldTimeout=method_getImplementation(class_getInstanceMethod(c,timeout));
 GSReplace(c,timeout,imp_implementationWithBlock(^BOOL(id request){GSBackupTransfer *t=objc_getAssociatedObject(request,&GSTransferKey);return t&&!t.reconciling&&!t.cancelled?NO:((BOOL(*)(id,SEL))oldTimeout)(request,timeout);}));
 SEL cancel=NSSelectorFromString(@"cancel");IMP oldCancel=method_getImplementation(class_getInstanceMethod(c,cancel));
 GSReplace(c,cancel,imp_implementationWithBlock(^(id request){
  GSBackupTransfer *t=objc_getAssociatedObject(request,&GSTransferKey);t.cancelGo=GSUploadHostForeground();
  @synchronized(GSLock){
   if(t.reconciling&&!t.finished&&!t.cancelled)[GSReconciling removeObject:t.localID];
   t.cancelSharedJob=GSReleaseSourceLocked(t);
   t.cancelled=YES;
  }
  // Background cancellation preserves the Go job for foreground resumption.
  // Foreground cancellation may cancel Go only after the last request observing
  // this source has released it; duplicate callbacks therefore cannot kill peers.
  if(t.jobID&&t.cancelGo&&t.cancelSharedJob)dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{GSRequest(@{@"op":@"cancel",@"id":t.jobID},nil);});
  ((void(*)(id,SEL))oldCancel)(request,cancel);
 }));
}
static void GSBindProgress(Class c){
 SEL selector=NSSelectorFromString(@"progress");
 if(!GSPhotosHasMethod(c,@"progress","d16@0:8")||!GSPhotosHasMethod(c,@"delegate","@16@0:8"))return;
 IMP original=method_getImplementation(class_getInstanceMethod(c,selector));
 // Live Photo progress is computed from native child uploads and has no setter.
 // Both request types expose Go's byte progress through the same native getter.
 GSReplace(c,selector,imp_implementationWithBlock(^double(id request){
  GSBackupTransfer *t=objc_getAssociatedObject(request,&GSTransferKey);
  return t&&!t.cancelled?t.progress:((double(*)(id,SEL))original)(request,selector);
 }));
}
static BOOL GSBlockNative(void){BOOL active;@synchronized(GSLock){active=GSReconciling.count>0;}return GSNativeRoutingEnabled()||active;}
static void GSGuard(id request,SEL selector,IMP original){
 if(GSBlockNative()||objc_getAssociatedObject(request,&GSTransferKey)){GSCount(@"nativePayloadBlocked");GSFail(request,4);return;}
 ((void(*)(id,SEL))original)(request,selector);
}
static void GSBindBackground(Class c){
 BOOL objectError=GSPhotosHasMethod(c,@"handleError:","v24@0:8@16");
 if(!GSRequestClassMatches(c)||
    !GSPhotosHasMethod(c,@"finishUpload","v16@0:8")||
    !GSPhotosHasMethod(c,@"blueprintDidComplete:mediaItem:error:","v36@0:8B16@20@28")||
    !GSPhotosHasMethod(c,@"beginUploadMediaRequestWithFingerprint:","v24@0:8@16")||
    (!objectError&&!GSPhotosHasMethod(c,@"handleErrorWithCode:","v24@0:8q16")))return;
 GSBindStart(c);GSBindProgress(c);
 // Existence matches finish directly; they never invoke blueprint completion.
 SEL finish=NSSelectorFromString(@"finishUpload");IMP oldFinish=method_getImplementation(class_getInstanceMethod(c,finish));
 GSReplace(c,finish,imp_implementationWithBlock(^(id request){GSFinish(request,YES);((void(*)(id,SEL))oldFinish)(request,finish);}));
 SEL failure=NSSelectorFromString(objectError?@"handleError:":@"handleErrorWithCode:");IMP oldFailure=method_getImplementation(class_getInstanceMethod(c,failure));
 if(objectError)GSReplace(c,failure,imp_implementationWithBlock(^(id request,id error){GSFinish(request,NO);((void(*)(id,SEL,id))oldFailure)(request,failure,error);}));
 else GSReplace(c,failure,imp_implementationWithBlock(^(id request,NSInteger code){GSFinish(request,NO);((void(*)(id,SEL,NSInteger))oldFailure)(request,failure,code);}));
 // Both audited versions use NSError here; early failures use handleError above.
 SEL blueprint=NSSelectorFromString(@"blueprintDidComplete:mediaItem:error:");IMP oldBlueprint=method_getImplementation(class_getInstanceMethod(c,blueprint));
 GSReplace(c,blueprint,imp_implementationWithBlock(^(id request,BOOL success,id result,id error){GSFinish(request,success&&error==nil);((void(*)(id,SEL,BOOL,id,id))oldBlueprint)(request,blueprint,success,result,error);}));
 // This branch can send through a background NSURLSession without startFetcher.
 SEL upload=NSSelectorFromString(@"beginUploadMediaRequestWithFingerprint:");IMP oldUpload=method_getImplementation(class_getInstanceMethod(c,upload));
 GSReplace(c,upload,imp_implementationWithBlock(^(id request,id fingerprint){
  if(GSBlockNative()||objc_getAssociatedObject(request,&GSTransferKey)){GSCount(@"nativePayloadBlocked");GSFail(request,4);return;}
  ((void(*)(id,SEL,id))oldUpload)(request,upload,fingerprint);
 }));
}
static void GSBindScotty(void){
 Class c=NSClassFromString(@"_TtC84googlemac_iPhone_Shared_Photos_Upload_Request_Scotty_ScottyUploadServiceImpl_ImplLib23ScottyUploadServiceImpl");
 SEL s=NSSelectorFromString(@"uploadWithAsset:shouldAllowCellular:useBackgroundSession:start:progress:onDataReleased:completionHandler:");
 Method m=class_getInstanceMethod(c,s);
 if(m&&!strcmp(method_getTypeEncoding(m),"v64@0:8@\"GMUUploadAsset\"16B24B28@?<v@?B>32@?<v@?d>40@?<v@?>48@?<v@?@\"NSData\"@\"NSError\">56")){
  IMP old=method_getImplementation(m);
  GSReplace(c,s,imp_implementationWithBlock(^(id service,id asset,BOOL cellular,BOOL background,id start,id progress,id released,void(^done)(id,id)){
   if(!GSBlockNative()){((void(*)(id,SEL,id,BOOL,BOOL,id,id,id,id))old)(service,s,asset,cellular,background,start,progress,released,done);return;}
   GSCount(@"nativePayloadBlocked");if(released)((void(^)(void))released)();if(done)done(nil,[NSError errorWithDomain:@"GoToHP.Backup" code:4 userInfo:nil]);
  }));
 }
 SEL stateless=NSSelectorFromString(@"statelessUploadWithAsset:shouldAllowCellular:progress:completionHandler:");m=class_getInstanceMethod(c,stateless);
 if(m&&!strcmp(method_getTypeEncoding(m),"v44@0:8@\"GMUUploadAsset\"16B24@?<v@?d>28@?<v@?@\"NSData\"@\"NSError\">36")){
  IMP old=method_getImplementation(m);
  GSReplace(c,stateless,imp_implementationWithBlock(^(id service,id asset,BOOL cellular,id progress,void(^done)(id,id)){
   if(!GSBlockNative()){((void(*)(id,SEL,id,BOOL,id,id))old)(service,stateless,asset,cellular,progress,done);return;}
   GSCount(@"nativePayloadBlocked");if(done)done(nil,[NSError errorWithDomain:@"GoToHP.Backup" code:4 userInfo:nil]);
  }));
 }
}
void GSInstallBackupRequests(void){
 if(GSInstalled||!GSIsGooglePhotos()||!GSPhotosHostSupported())return;
 Class asset=NSClassFromString(@"GMUAssetUploadRequest"),live=NSClassFromString(@"GMULivePhotoSingleUploadRequest"),base=NSClassFromString(@"GMUUploadRequest");
 if(!GSRequestClassMatches(asset)||!GSRequestClassMatches(live))return;
 Method fetch=class_getInstanceMethod(base,NSSelectorFromString(@"startFetcher"));if(!fetch||strcmp(method_getTypeEncoding(fetch),"v16@0:8"))return;
 if(GSPhotosCompletionForClass(asset)==GSPhotosCompletionUnavailable)return;
 Method ac=class_getInstanceMethod(asset,NSSelectorFromString(GSPhotosAssetCompletion(asset))),lc=class_getInstanceMethod(live,NSSelectorFromString(@"didCompleteWithError:resultantMediaItem:"));
 if(!ac||!lc||strcmp(method_getTypeEncoding(ac),GSPhotosAssetCompletionABI(asset))||strcmp(method_getTypeEncoding(lc),"v32@0:8@16@24"))return;
 GSLock=[NSObject new];GSCounts=[NSMutableDictionary dictionary];GSReconciling=[NSCountedSet new];GSActiveSources=[NSCountedSet new];
 GSBindStart(asset);GSBindStart(live);GSBindCompletion(asset,NO);GSBindCompletion(live,YES);
 GSBindProgress(asset);GSBindProgress(live);
 GSBindBackground(NSClassFromString(@"GMUBackgroundAssetUploadRequest"));
 Class liveUpload=NSClassFromString(@"GMULivePhotoUploadRequest");
 if(GSRequestClassMatches(liveUpload)&&GSPhotosHasMethod(liveUpload,@"didCompleteWithError:resultantMediaItem:","v32@0:8@16@24")){GSBindStart(liveUpload);GSBindCompletion(liveUpload,YES);GSBindProgress(liveUpload);}
 SEL s=NSSelectorFromString(@"startFetcher");IMP original=method_getImplementation(fetch);GSReplace(base,s,imp_implementationWithBlock(^(id request){GSGuard(request,s,original);}));
 Class media=NSClassFromString(@"GMUUploadMediaRequest");SEL cnde=NSSelectorFromString(@"startCNDEUpload");Method cm=class_getInstanceMethod(media,cnde);
 if(cm&&!strcmp(method_getTypeEncoding(cm),"v16@0:8")){IMP old=method_getImplementation(cm);GSReplace(media,cnde,imp_implementationWithBlock(^(id request){GSGuard(request,cnde,old);}));}
 GSBindScotty();GSInstalled=YES;
}
