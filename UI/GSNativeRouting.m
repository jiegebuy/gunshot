#import "../Shared/GSPhotosCompatibility.h"
#import "../Shared/GSLocalization.h"
#import "GSNativeRouting.h"
#import "GSExporter.h"
#import "../Shared/IPCProtocol.h"
#import "GSBackupRequests.h"
#import "GSNativeAccount.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Explicit backup UI actions shared by the audited host profiles.
static BOOL GSInstalled;
static NSString *const GSEnabledKey=@"dev.tqmane.gunshot.routeManualBackup";
static NSString *const GSAccountKey=@"dev.tqmane.gunshot.routeAccount";
static void (*GSBackupOriginal)(id,SEL,id);
static void (*GSGridBackupOriginal)(id,SEL,id);
static dispatch_queue_t GSImportQueue;
static NSObject *GSImportLock;
static NSMutableDictionary *GSImportStatus;
static void GSInitializeImport(void){static dispatch_once_t once;dispatch_once(&once,^{GSImportQueue=dispatch_queue_create("dev.tqmane.gunshot.native-import",DISPATCH_QUEUE_SERIAL);GSImportLock=[NSObject new];GSImportStatus=[@{@"actions":@0,@"queued":@0,@"failed":@0}mutableCopy];});}
static void GSImportResult(NSString *error,NSUInteger queued){
 GSInitializeImport();@synchronized(GSImportLock){GSImportStatus[@"queued"]=@([GSImportStatus[@"queued"]unsignedIntegerValue]+queued);if(error){GSImportStatus[@"failed"]=@([GSImportStatus[@"failed"]unsignedIntegerValue]+1);GSImportStatus[@"lastError"]=error;}else[GSImportStatus removeObjectForKey:@"lastError"];}
}
NSDictionary *GSNativeRoutingSnapshot(void){GSInitializeImport();@synchronized(GSImportLock){NSMutableDictionary *s=[GSImportStatus mutableCopy];s[@"presentation"]=@"silent";return s;}}
BOOL GSIsGooglePhotos(void){return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"]isEqualToString:@"GooglePhotos"];}
BOOL GSNativeRoutingAvailable(void){return GSInstalled||GSBackupRequestsAvailable();}
BOOL GSNativeRoutingEnabled(void){return GSNativeRoutingAvailable()&&[NSUserDefaults.standardUserDefaults boolForKey:GSEnabledKey];}
NSString *GSNativeRoutingAccount(void){return [NSUserDefaults.standardUserDefaults stringForKey:GSAccountKey];}
void GSSetNativeRouting(BOOL enabled, NSString *account){
 [NSUserDefaults.standardUserDefaults setObject:account?:@"" forKey:GSAccountKey];
 [NSUserDefaults.standardUserDefaults setBool:enabled&&GSNativeRoutingAvailable() forKey:GSEnabledKey];
}
// Called on the import worker, including after potentially slow iCloud export.
static BOOL GSImportAuthorized(NSString *account,NSString *identity){
 __block BOOL authorized=NO;
 dispatch_sync(dispatch_get_main_queue(),^{authorized=GSNativeRoutingEnabled()&&[GSNativeRoutingAccount()isEqual:account]&&GSNativeIdentityMatches(identity);});
 return authorized&&[GSRequest(@{@"op":@"accounts"},nil)[@"selected"]isEqual:account];
}
static void GSRoute(id localAssets){
 NSMutableArray<NSString *> *identifiers=[NSMutableArray array];BOOL valid=[localAssets isKindOfClass:NSArray.class]||[localAssets isKindOfClass:NSSet.class];
 if(valid)for(id local in localAssets){
  PHAsset *asset=nil;
  if([local isKindOfClass:PHAsset.class])asset=local;
  else if([local isKindOfClass:NSClassFromString(@"PHSLocalAsset")]){
   if(((BOOL(*)(id,SEL))objc_msgSend)(local,NSSelectorFromString(@"isLocked"))){valid=NO;break;}
   asset=((id(*)(id,SEL))objc_msgSend)(local,NSSelectorFromString(@"phAsset"));
  }
  if(![asset isKindOfClass:PHAsset.class]||!asset.localIdentifier.length){valid=NO;break;}
  [identifiers addObject:asset.localIdentifier];
 }
 // Import silently; report failures in settings without native fallback.
 GSInitializeImport();@synchronized(GSImportLock){GSImportStatus[@"actions"]=@([GSImportStatus[@"actions"]unsignedIntegerValue]+1);}
 if(!valid||!identifiers.count){GSImportResult(@"The selected photos could not be retrieved.",0);return;}
 NSString *account=[GSNativeRoutingAccount()copy];NSArray<NSString *> *selection=[identifiers copy];
 dispatch_async(dispatch_get_main_queue(),^{
  NSDictionary *native=GSNativeAccountSummary();NSString *identity=native[@"identifier"];
  if(![account isEqual:native[@"email"]]||!GSNativeIdentityMatches(identity)){GSImportResult(@"The signed-in account does not match the upload destination.",0);return;}
  dispatch_async(GSImportQueue,^{@autoreleasepool{
   NSError *error=nil;NSDictionary *accounts=GSRequest(@{@"op":@"accounts"},&error);
   if(!account.length||![accounts[@"selected"]isEqual:account]){GSImportResult(@"The destination has changed. Check the backup integration settings.",0);return;}
   NSDictionary *options=GSRequest(@{@"op":@"options"},&error);NSUInteger queued=0;
   for(NSString *localIdentifier in selection){@autoreleasepool{
    if(error||!options)break;
    if(!GSImportAuthorized(account,identity)){error=[NSError errorWithDomain:@"GoToHP.Import" code:1 userInfo:nil];break;}
    NSString *job=GSImportAuthorized(account,identity)?GSImportPhotoIdentifierChecked(localIdentifier,account,options[@"quality"]?:@"original",^BOOL{
     return GSImportAuthorized(account,identity);
    },&error):nil;
    if(!job){if(!error)error=[NSError errorWithDomain:@"GoToHP.Import" code:2 userInfo:nil];break;}queued++;
   }}
   GSImportResult(queued==selection.count?nil:@"Could not add photos to the queue. Check the account and photo access.",queued);
  }});
 });
}
static void GSBackup(id object,SEL selector,id assets){
 if(!GSNativeRoutingEnabled()){GSBackupOriginal(object,selector,assets);return;}
 // Preserve the native scheduler; the shared request hook handles the transfer.
 if(GSBackupRequestsAvailable()){GSBackupOriginal(object,selector,assets);return;}
 GSRoute(assets);
}
static void GSGridBackup(id object,SEL selector,id assets){
 if(!GSNativeRoutingEnabled()){GSGridBackupOriginal(object,selector,assets);return;}
 if(GSBackupRequestsAvailable()){GSGridBackupOriginal(object,selector,assets);return;}
 GSRoute(assets);
}
void GSInstallNativeRouting(void){
 GSInstallBackupRequests();
 // Called on the main thread when installing the app's GoToHP launcher.
 if(GSInstalled||!GSIsGooglePhotos()||!GSPhotosHostSupported())return;
 Class behavior=NSClassFromString(@"PHSBackupActionBehaviorImpl");
 Class grid=NSClassFromString(@"PHSActionsGridModel");
 Class local=NSClassFromString(@"PHSLocalAsset");
 SEL selector=NSSelectorFromString(@"backupLocalAssets:");
 Method a=class_getInstanceMethod(behavior,selector),b=class_getInstanceMethod(grid,selector);
 Method asset=class_getInstanceMethod(local,NSSelectorFromString(@"phAsset"));
 Method locked=class_getInstanceMethod(local,NSSelectorFromString(@"isLocked"));
 if(!a||!b||!asset||!locked||strcmp(method_getTypeEncoding(a),"v24@0:8@16")||strcmp(method_getTypeEncoding(b),"v24@0:8@16")||strcmp(method_getTypeEncoding(asset),"@16@0:8")||strcmp(method_getTypeEncoding(locked),"B16@0:8"))return;
 GSBackupOriginal=(void *)method_setImplementation(a,(IMP)GSBackup);
 GSGridBackupOriginal=(void *)method_setImplementation(b,(IMP)GSGridBackup);
 GSInstalled=YES;
}
