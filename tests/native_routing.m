#import "host_profile.h"
#import "../UI/GSNativeRouting.h"
#import "../UI/GSExporter.h"
#import <objc/runtime.h>
#include <assert.h>

static NSString *version=@"unsupported";
static BOOL host=NO;
@interface GSFixtureBundle : NSBundle
@end
@implementation GSFixtureBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
 if([key isEqual:@"CFBundleExecutable"])return host?@"GooglePhotos":@"OtherApp";
 if([key isEqual:@"CFBundleShortVersionString"])return version;
 return nil;
}
@end
static NSBundle *FixtureMainBundle(id object,SEL selector){static GSFixtureBundle *b; if(!b)b=[GSFixtureBundle new];return b;}
@implementation PHAsset
@end
@interface PHSLocalAsset : NSObject
@property(nonatomic,strong) PHAsset *phAsset;
@property(nonatomic) _Bool isLocked;
@end
@implementation PHSLocalAsset
@end
static NSUInteger originalCount,importedCount;
static BOOL failExport;
static NSString *selected=@"destination@example.com";
static NSString *lastAccount;
static NSString *identity=@"native-destination";
static void (^duringExport)(void);
static NSURL *exportDirectory;
@interface PHSBackupActionBehaviorImpl : NSObject
- (void)backupLocalAssets:(id)assets;
@end
@implementation PHSBackupActionBehaviorImpl
- (void)backupLocalAssets:(id)assets{originalCount++;}
@end
@interface PHSActionsGridModel : NSObject
- (void)backupLocalAssets:(id)assets;
@end
@implementation PHSActionsGridModel
- (void)backupLocalAssets:(id)assets{originalCount++;}
@end
// A future reintroduction of the old presenter fails this test.
void GSPresentRoutedAssets(NSArray<PHAsset *> *assets,NSString *account){assert(!"backup presented GoToHP UI");}
void GSInstallBackupRequests(void){}
BOOL GSBackupRequestsAvailable(void){return NO;} // Exercise the compatibility path.
NSDictionary *GSNativeAccountSummary(void){assert(NSThread.isMainThread);return @{@"email":@"destination@example.com",@"identifier":identity};}
BOOL GSNativeIdentityMatches(NSString *expected){assert(NSThread.isMainThread);return expected.length&&[expected isEqual:identity];}
NSDictionary *GSRequest(NSDictionary *request,NSError **error){
 if([request[@"op"]isEqual:@"accounts"])return @{@"selected":selected};
 if([request[@"op"]isEqual:@"options"])return @{@"quality":@"original"};
 return @{};
}
NSArray *GSExportAsset(PHAsset *asset,NSURL *directory,NSError **error){
 assert(!NSThread.isMainThread);exportDirectory=directory;
 if(duringExport)dispatch_sync(dispatch_get_main_queue(),duringExport);
 return failExport?nil:@[[directory URLByAppendingPathComponent:@"original.heic"]];
}
NSString *GSImportFiles(NSArray *files,NSString *account,NSString *quality,NSDate *date,NSError **error){assert(!NSThread.isMainThread);assert([quality isEqual:@"original"]);importedCount++;lastAccount=account;return @"job";}
NSString *GSImportPhotoIdentifierChecked(NSString *identifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,NSError **error){
 assert(!NSThread.isMainThread&&identifier.length&&[quality isEqual:@"original"]);
 if(authorization&&!authorization())return nil;
 exportDirectory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
 [NSFileManager.defaultManager createDirectoryAtURL:exportDirectory withIntermediateDirectories:YES attributes:nil error:nil];
 if(duringExport)dispatch_sync(dispatch_get_main_queue(),duringExport);
 BOOL allowed=!authorization||authorization();[NSFileManager.defaultManager removeItemAtURL:exportDirectory error:nil];
 if(failExport||!allowed)return nil;
 importedCount++;lastAccount=account;return @"job";
}
NSString *GSImportPhotoIdentifier(NSString *identifier,NSString *account,NSString *quality,NSError **error){return GSImportPhotoIdentifierChecked(identifier,account,quality,nil,error);}
static void Drain(NSUInteger queued,NSUInteger failed){
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
 while(deadline.timeIntervalSinceNow>0){NSDictionary *s=GSNativeRoutingSnapshot();if([s[@"queued"]unsignedIntegerValue]==queued&&[s[@"failed"]unsignedIntegerValue]==failed)return;[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];}
 assert(!"headless import did not finish");
}
int main(void){@autoreleasepool{
 method_setImplementation(class_getClassMethod(NSBundle.class,@selector(mainBundle)),(IMP)FixtureMainBundle);
 GSInstallNativeRouting();assert(!GSNativeRoutingAvailable());
 host=YES;version=GSFixtureVersion;GSInstallNativeRouting();assert(GSNativeRoutingAvailable());
 GSSetNativeRouting(NO,nil);
 PHSBackupActionBehaviorImpl *behavior=[PHSBackupActionBehaviorImpl new];
 PHSActionsGridModel *grid=[PHSActionsGridModel new];
 PHSLocalAsset *local=[PHSLocalAsset new];local.phAsset=[PHAsset new];local.phAsset.localIdentifier=@"asset-one";
 [behavior backupLocalAssets:@[local]];[grid backupLocalAssets:@[local]];
 assert(originalCount==2&&importedCount==0);
 GSSetNativeRouting(YES,@"destination@example.com");
 [behavior backupLocalAssets:@[local]];Drain(1,0);
 assert(importedCount==1&&originalCount==2&&[lastAccount isEqual:@"destination@example.com"]);
 PHAsset *second=[PHAsset new];second.localIdentifier=@"asset-two";
 [grid backupLocalAssets:[NSSet setWithObjects:local.phAsset,second,nil]];Drain(3,0);
 assert(importedCount==3&&originalCount==2);
 [behavior backupLocalAssets:@[local,@"unknown"]];Drain(3,1);
 local.isLocked=YES;[grid backupLocalAssets:@[local]];Drain(3,2);
 local.isLocked=NO;selected=@"other@example.com";[behavior backupLocalAssets:@[local]];Drain(3,3);
 selected=@"destination@example.com";failExport=YES;[behavior backupLocalAssets:@[local]];Drain(3,4);
 assert(importedCount==3&&originalCount==2&&GSNativeRoutingSnapshot()[@"lastError"]);
 failExport=NO;[behavior backupLocalAssets:@[local]];Drain(4,4);
 assert(!GSNativeRoutingSnapshot()[@"lastError"]);
 // Changing the identity, selected account, destination, or toggle during
 // PhotoKit export must not import even the first asset (nor later assets).
 NSArray *changes=@[
  ^{identity=@"other-native-identity";},
  ^{identity=@"";},
  ^{selected=@"other@example.com";},
  ^{GSSetNativeRouting(YES,@"other@example.com");},
  ^{GSSetNativeRouting(NO,nil);}
 ];
 NSUInteger failed=4;
 for(void (^change)(void) in changes){
  identity=@"native-destination";selected=@"destination@example.com";GSSetNativeRouting(YES,selected);duringExport=change;
  [behavior backupLocalAssets:@[local,local.phAsset]];Drain(4,++failed);
  assert(importedCount==4&&originalCount==2);
  assert(![NSFileManager.defaultManager fileExistsAtPath:exportDirectory.path]);
 }
 duringExport=nil;identity=@"native-destination";selected=@"destination@example.com";GSSetNativeRouting(YES,selected);
 [grid backupLocalAssets:@[local]];Drain(5,failed);assert(!GSNativeRoutingSnapshot()[@"lastError"]);
 // A missing initial identity is rejected before starting any export.
 identity=@"";exportDirectory=nil;[behavior backupLocalAssets:@[local]];Drain(5,++failed);assert(!exportDirectory);
 GSSetNativeRouting(NO,nil);[behavior backupLocalAssets:@[local]];
 assert(originalCount==3&&importedCount==5);
 NSLog(@"PASS silent manual import, batch, original policy, account binding, invalid/locked assets, export failure, recovery and no native fallback");
 return 0;
}}
