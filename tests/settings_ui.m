#import "../Shared/GSLocalization.h"
#import <UIKit/UIKit.h>
#import "../UI/GSPanel.h"
#import "../UI/GSAccountConnection.h"
#import "../UI/GSUploadMonitor.h"
#import "../UI/GSNativeRouting.h"
#import "../UI/GSUploadDiagnostics.h"
#import "../UI/GSExporter.h"
#import "../Shared/IPCProtocol.h"
#include <stdlib.h>
#include <stdatomic.h>
#include <math.h>
#include "libgotohp.h"
// Real jailed adapter + UIKit + NWPath + Go runtime. Only account operations are fake.
// A synchronous main callback models native SSO while the core queue is busy.

static BOOL SnapshotDuringAuthorization;
static atomic_ulong FixtureAccountReads;
static atomic_ulong FixtureNativeConnections;
static atomic_int FixtureConcurrent=2;
@interface GSPanel (GSFixturePolling)
- (void)refresh;
- (void)reloadTablePreservingPosition;
- (void)chooseValueForControl:(NSInteger)control;
- (void)sheet:(UIAlertController *)sheet;
@end
@interface GSFixtureRetryPanel : GSPanel
@property(nonatomic,strong) UIAlertController *valueSheet;
@end
@implementation GSFixtureRetryPanel
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion{
 if([vc isKindOfClass:UIAlertController.class]){self.valueSheet=(UIAlertController *)vc;return;}
 [super presentViewController:vc animated:flag completion:completion];
}
@end
static NSUInteger NativeRefreshes;
void GSRefreshNativeLibrary(void){dispatch_async(dispatch_get_main_queue(),^{NativeRefreshes++;});}
NSDictionary *GSPhotosIntegrationSnapshot(void){return @{};}
NSDictionary *GSNativeAccountSummary(void){return @{@"email":@"test@example.com",@"identifier":@"fixture"};}
BOOL GSNativeIdentityMatches(NSString *identifier){return [identifier isEqual:@"fixture"];}
void GSInstallPhotosIntegration(void){}
void GSInstallNativeAccount(void){}
char *GSNativeBearer(const char *identifier){return NULL;}
char *GSFixtureRequest(char *json,char *role){
 NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json]dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
 NSString *op=request[@"op"];id data=@{};
 // Runtime requests cross the real C ABI and Go JSON decoder. The previous
 // all-fake service accepted integer 1/0 via boolValue and missed this bug.
 if([op isEqual:@"conditions"]||[op isEqual:@"list"]||[op isEqual:@"upload_summary"])return GunshotRequest(json,role);
 if([op isEqual:@"account_native"]){
  atomic_fetch_add(&FixtureNativeConnections,1);
  NSLog(@"Fixture: authorizing");
  dispatch_sync(dispatch_get_main_queue(),^{
   NSDictionary *snapshot=GSEmbeddedRuntimeSnapshot();
   SnapshotDuringAuthorization=[snapshot[@"authorization"]isEqual:@"checking"];
   NSLog(@"Fixture: authorization snapshot returned");
  });
 }
 if([op isEqual:@"accounts"])atomic_fetch_add(&FixtureAccountReads,1);
 if([op isEqual:@"accounts"])data=@{@"selected":@"test@example.com",@"accounts":@[@{@"email":@"test@example.com"}]};
 if([op isEqual:@"options"])data=@{@"quality":@"original",@"concurrent":@(atomic_load(&FixtureConcurrent)),@"retries":@3,@"wifiOnly":@NO,@"chargingOnly":@NO,@"paused":@NO};
 NSData *reply=[NSJSONSerialization dataWithJSONObject:@{@"ok":@YES,@"data":data} options:0 error:nil];
 return strdup([[NSString alloc]initWithData:reply encoding:NSUTF8StringEncoding].UTF8String);
}
static BOOL UnlimitedStorage=YES;
void GSInstallUnlimitedStorage(void){}
NSDictionary *GSUnlimitedStorageSnapshot(void){return @{};}
BOOL GSUnlimitedStorageAvailable(void){return YES;}
BOOL GSUnlimitedStorageEnabled(void){return UnlimitedStorage;}
void GSSetUnlimitedStorage(BOOL enabled){UnlimitedStorage=enabled;}
BOOL GSIsGooglePhotos(void){return YES;}
void GSInstallNativeRouting(void){}
BOOL GSNativeRoutingAvailable(void){return YES;}
NSDictionary *GSNativeRoutingSnapshot(void){return @{};}
BOOL GSBackupRequestsAvailable(void){return YES;}
NSDictionary *GSBackupRequestsSnapshot(void){return @{};}
BOOL GSNativeRoutingEnabled(void){return NO;}
NSString *GSNativeRoutingAccount(void){return @"test@example.com";}
void GSSetNativeRouting(BOOL enabled,NSString *account){}
void GSInstallUploadDiagnostics(void){}
BOOL GSUploadDiagnosticsAvailable(void){return YES;}
BOOL GSUploadDiagnosticsEnabled(void){return NO;}
void GSSetUploadDiagnostics(BOOL enabled){}
NSDictionary *GSUploadDiagnosticsSnapshot(void){return @{};}
NSArray<NSURL *> *GSExportAsset(PHAsset *asset,NSURL *directory,NSError **error){return nil;}
NSString *GSImportFiles(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,NSError **error){return nil;}
NSString *GSImportFilesWithProgress(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){return nil;}
NSString *GSImportPhotoIdentifierChecked(NSString *identifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,NSError **error){return nil;}
NSString *GSImportPhotoIdentifierWithProgress(NSString *identifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){return nil;}
NSString *GSImportPhotoIdentifier(NSString *identifier,NSString *account,NSString *quality,NSError **error){return nil;}
static NSString *Documents(void){return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;}
static void Finish(BOOL success,NSString *reason){
 [[NSString stringWithFormat:@"%@ %@\n",success?@"PASS":@"FAIL",reason]writeToFile:[Documents() stringByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
 NSLog(@"Settings UIKit smoke: %@",reason);exit(success?0:1);
}
static void Await(BOOL(^condition)(void),void(^next)(void),NSDate *deadline){
 if(condition()){next();return;}
 if(deadline.timeIntervalSinceNow<=0){Finish(NO,@"presentation deadline exceeded");return;}
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{Await(condition,next,deadline);});
}
static void Capture(UIWindow *window,NSString *name){
 UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc]initWithSize:window.bounds.size];
 NSData *png=[renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context){[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];}];
 [png writeToFile:[Documents() stringByAppendingPathComponent:name] atomically:YES];
}
static GSPanel *Panel(UIViewController *host){
 UIViewController *nav=host.presentedViewController;
 if(![nav isKindOfClass:UINavigationController.class])return nil;
 id top=((UINavigationController *)nav).topViewController;return [top isKindOfClass:GSPanel.class]?top:nil;
}
static void CheckRealSheetPresentation(GSPanel *panel,void(^next)(void)){
 NSIndexPath *path=[NSIndexPath indexPathForRow:2 inSection:2];
 [panel.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
 [panel.tableView layoutIfNeeded];UITableViewCell *cell=[panel.tableView cellForRowAtIndexPath:path];
 [panel tableView:panel.tableView didSelectRowAtIndexPath:path];
 Await(^BOOL{return [panel.presentedViewController isKindOfClass:UIAlertController.class];},^{
  UIAlertController *sheet=(UIAlertController *)panel.presentedViewController;
  if(sheet.preferredStyle!=UIAlertControllerStyleActionSheet||sheet.actions.count<11){Finish(NO,@"real retry action sheet was not presented");return;}
  if(@available(iOS 26.0,*)){
   UIPopoverPresentationController *popover=sheet.popoverPresentationController;
   if(sheet.modalPresentationStyle!=UIModalPresentationPopover||!popover||!cell||popover.sourceView!=cell||!CGRectEqualToRect(popover.sourceRect,cell.bounds)){Finish(NO,@"real action sheet did not retain its Liquid Glass row anchor");return;}
  }
  [panel dismissViewControllerAnimated:NO completion:next];
 },[NSDate dateWithTimeIntervalSinceNow:5]);
}
static void CheckStationaryPolling(GSPanel *panel,UIWindow *window,void(^next)(void)){
 NSIndexPath *path=[NSIndexPath indexPathForRow:1 inSection:6];
 // Offscreen rows keep estimated heights until a reload re-measures them, so the first
 // position-preserving reload after the scroll still shifts geometry. Run the same
 // reload the refresh path uses until the layout reaches its fixed point, then capture
 // the baseline the later reload will be compared against.
 [panel reloadTablePreservingPosition];[panel.tableView layoutIfNeeded];
 [panel reloadTablePreservingPosition];[panel.tableView layoutIfNeeded];
 UITableViewCell *cell=[panel.tableView cellForRowAtIndexPath:path];
 if(!cell){Finish(NO,@"storage switch must be visible before polling test");return;}
 CGFloat relative=[panel.tableView rectForRowAtIndexPath:path].origin.y-panel.tableView.contentOffset.y;
 NSUInteger reads=atomic_load(&FixtureAccountReads);
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
  CGFloat now=[panel.tableView rectForRowAtIndexPath:path].origin.y-panel.tableView.contentOffset.y;
  if(atomic_load(&FixtureAccountReads)<reads+2||[panel.tableView cellForRowAtIndexPath:path]!=cell||fabs(now-relative)>1){Finish(NO,@"unchanged timer polls replaced the switch or moved the settings list");return;}
  // A real changed snapshot still updates, retaining the visible row's position.
  atomic_store(&FixtureConcurrent,3);[panel refresh];
  Await(^BOOL{return [[[panel valueForKey:@"options"]objectForKey:@"concurrent"]intValue]==3;},^{
   CGFloat updated=[panel.tableView rectForRowAtIndexPath:path].origin.y-panel.tableView.contentOffset.y;
   if(fabs(updated-relative)>1||![((UISwitch *)[panel.tableView cellForRowAtIndexPath:path].accessoryView)isOn]){Finish(NO,@"changed snapshot moved or removed the storage switch");return;}
   Capture(window,@"settings-after-polling.png");next();
  },[NSDate dateWithTimeIntervalSinceNow:5]);
 });
}
#include "photos_glass_fixture.h"
@interface GSFixtureScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic) BOOL started;
@end
@implementation GSFixtureScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{
 NSLog(@"Fixture: scene connecting");
 self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];
 self.window.rootViewController=[UIViewController new];self.window.rootViewController.view.backgroundColor=UIColor.systemBackgroundColor;
 [self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene{
 if(self.started)return;self.started=YES;NSLog(@"Fixture: scene active");
 if(@available(iOS 26.0,*)){
  if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"]boolValue]||
     ![NSUserDefaults.standardUserDefaults boolForKey:@"com.apple.SwiftUI.IgnoreSolariumOptOut"]){
   Finish(NO,@"Liquid Glass compatibility override was not present before UIApplicationMain");return;
  }
 }
 GSSetLanguage(@"ja");NSLog(@"Fixture: language initialized");
 UIViewController *root=self.window.rootViewController;
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
 // Authenticate at app activation, before any GoToHP settings are presented.
 GSStartAccountConnection();
 GSStartBackupIntegration();
 Await(^BOOL{return [GSAccountConnectionSnapshot()[@"state"]isEqual:@"connected"];},^{
 if(root.presentedViewController||atomic_load(&FixtureNativeConnections)!=1){Finish(NO,@"launch authorization required UI or connected more than once");return;}
 // A detached delegate controller must resolve to the active scene's root.
 GSPresentSettings([UIViewController new]);
 Await(^BOOL{GSPanel *panel=Panel(root);return panel.settingsMode&&panel.viewIfLoaded.window&&[[panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].detailTextLabel.text isEqual:@"認証確認済み · アップロード可能"];},^{
  NSDictionary *runtime=GSEmbeddedRuntimeSnapshot();
  if(![runtime[@"conditionsAccepted"]boolValue]||!SnapshotDuringAuthorization||![runtime[@"coreReady"]boolValue]||![runtime[@"foreground"]boolValue]||![runtime[@"path"]isEqual:@"satisfied"]){Finish(NO,@"embedded runtime state or nonblocking authorization snapshot failed");return;}
  NSSet *allowed=[NSSet setWithArray:@[@"uploadSummary",@"coreReady",@"conditionsAccepted",@"foreground",@"path",@"networkOnline",@"wifi",@"charging",@"authorization"]];
  if(![[NSSet setWithArray:runtime.allKeys]isSubsetOfSet:allowed]){Finish(NO,@"unexpected diagnostic fields");return;}
  GSPanel *panel=Panel(root);if([panel.tableView numberOfSections]!=8||[panel.tableView numberOfRowsInSection:6]!=3){Finish(NO,@"settings sections or appearance rows incorrect");return;}
  GSFixtureRetryPanel *retryPanel=[GSFixtureRetryPanel new];retryPanel.settingsMode=YES;
  [retryPanel setValue:[@{@"retries":@7,@"concurrent":@2,@"quality":@"original"}mutableCopy] forKey:@"options"];
  retryPanel.view.frame=CGRectMake(0,0,390,844);
  [retryPanel.tableView reloadData];[retryPanel.tableView layoutIfNeeded];
  UITableViewCell *retry=[retryPanel tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:2]];
  [retryPanel chooseValueForControl:2];
  if(![retry.detailTextLabel.text isEqual:@"7 回"]||![retryPanel.valueSheet.actions[7].title isEqual:@"✓ 7 回"]){Finish(NO,@"Japanese retry setting must use the protocol key for display and selection");return;}
  // Issue #50: Liquid Glass action sheets must anchor to the tapped row, not a fixed top offset.
  NSIndexPath *retryPath=[NSIndexPath indexPathForRow:2 inSection:2];
  [retryPanel.tableView scrollToRowAtIndexPath:retryPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
  [retryPanel.tableView layoutIfNeeded];
  [retryPanel tableView:retryPanel.tableView didSelectRowAtIndexPath:retryPath];
  UIAlertController *retrySheet=retryPanel.valueSheet;
  UIPopoverPresentationController *retryPopover=retrySheet.popoverPresentationController;
  UITableViewCell *retryCell=[retryPanel.tableView cellForRowAtIndexPath:retryPath];
  if(!retrySheet||retrySheet.actions.count<11){Finish(NO,@"retry sheet missing after row selection");return;}
  if(retryCell){
   if(retryPopover.sourceView!=retryCell||!CGRectEqualToRect(retryPopover.sourceRect,retryCell.bounds)){Finish(NO,@"sheet must anchor to the tapped cell");return;}
  }else{
   CGRect row=[retryPanel.tableView rectForRowAtIndexPath:retryPath];
   if(retryPopover.sourceView!=retryPanel.tableView){Finish(NO,@"sheet must fall back to the table row, not a fixed top offset");return;}
   if(fabs(CGRectGetMidX(retryPopover.sourceRect)-CGRectGetMidX(row))>1||fabs(CGRectGetMaxY(retryPopover.sourceRect)-(CGRectGetMaxY(row)-2))>1){Finish(NO,@"sheet sourceRect must match the selected row");return;}
  }
  if(retryPopover.sourceView==retryPanel.view&&fabs(retryPopover.sourceRect.origin.y-80)<1){Finish(NO,@"sheet must not use the hardcoded y=80 anchor");return;}
  NSIndexPath *languagePath=[NSIndexPath indexPathForRow:0 inSection:6];
  [retryPanel.tableView scrollToRowAtIndexPath:languagePath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
  [retryPanel.tableView layoutIfNeeded];
  [retryPanel tableView:retryPanel.tableView didSelectRowAtIndexPath:languagePath];
  UIAlertController *languageSheet=retryPanel.valueSheet;
  UIPopoverPresentationController *languagePopover=languageSheet.popoverPresentationController;
  UITableViewCell *languageCell=[retryPanel.tableView cellForRowAtIndexPath:languagePath];
  if(languageSheet.actions.count!=6){Finish(NO,@"language sheet must list five languages plus cancel");return;}
  if(languageCell){
   if(languagePopover.sourceView!=languageCell||!CGRectEqualToRect(languagePopover.sourceRect,languageCell.bounds)){Finish(NO,@"language sheet must anchor to the tapped cell");return;}
  }else{
   CGRect row=[retryPanel.tableView rectForRowAtIndexPath:languagePath];
   if(languagePopover.sourceView!=retryPanel.tableView||fabs(CGRectGetMaxY(languagePopover.sourceRect)-(CGRectGetMaxY(row)-2))>1){Finish(NO,@"language sheet must anchor to the selected row");return;}
  }
  if(languagePopover.sourceView==retryPanel.view&&fabs(languagePopover.sourceRect.origin.y-80)<1){Finish(NO,@"language sheet must not use the hardcoded y=80 anchor");return;}
  Capture(self.window,@"settings-light.png");
  GSSetLanguage(@"en");[panel viewWillAppear:NO];
  GSPanel *uploads=[[GSPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];
  if([uploads tableView:panel.tableView numberOfRowsInSection:1]!=3){Finish(NO,@"bulk upload controls missing");return;}
  UITableViewCell *album=[uploads tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:1]];
  UITableViewCell *stop=[uploads tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:1]];
  if(![album.textLabel.text isEqual:@"Choose album"]||![stop.textLabel.text isEqual:@"Stop preparing"]||![album.detailTextLabel.text containsString:@"entire album"]){Finish(NO,@"album import labels missing");return;}
  UITableViewCell *quality=[panel tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
  if(![quality.textLabel.text isEqual:@"Quality"]||![panel.navigationItem.rightBarButtonItem.title isEqual:@"Reconnect"]){Finish(NO,@"English settings did not update");return;}
  // Standard navigation items must retain localized titles and actions.
  if(![panel.navigationItem.leftBarButtonItem.title isEqual:@"Done"]||![panel.navigationItem.rightBarButtonItems[1].title isEqual:@"Uploads"]){Finish(NO,@"navigation labels did not update");return;}
  for(UIBarButtonItem *item in @[panel.navigationItem.leftBarButtonItem,panel.navigationItem.rightBarButtonItems[0],panel.navigationItem.rightBarButtonItems[1]]){
   if(item.customView||item.target!=panel||!item.action){Finish(NO,@"standard navigation item configuration incorrect");return;}
  }
  UITableViewCell *status=[panel tableView:panel.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
  if(![status.detailTextLabel.text isEqual:@"Authenticated · Ready to upload"]){Finish(NO,@"cached status language did not update");return;}
  if(!GSCheckPhotosGlass(panel,self.window)){Finish(NO,@"Google Photos bottom bar glass regression");return;}
  NSIndexPath *storagePath=[NSIndexPath indexPathForRow:1 inSection:6];
  [panel setValue:@YES forKey:@"busy"];
  UITableViewCell *storage=[panel tableView:panel.tableView cellForRowAtIndexPath:storagePath];
  UISwitch *toggle=(UISwitch *)storage.accessoryView;
  if(![storage.textLabel.text isEqual:@"Show unlimited storage"]||![toggle isKindOfClass:UISwitch.class]||!toggle.on||!toggle.enabled){Finish(NO,@"storage toggle default or availability failed");return;}
  toggle.on=NO;[toggle sendActionsForControlEvents:UIControlEventValueChanged];
  if(UnlimitedStorage){Finish(NO,@"storage opt-out while busy failed");return;}
  toggle.on=YES;[toggle sendActionsForControlEvents:UIControlEventValueChanged];
  if(!UnlimitedStorage){Finish(NO,@"storage opt-in failed");return;}
  [panel setValue:@NO forKey:@"busy"];[panel.tableView reloadData];
  Capture(self.window,@"settings-english.png");
  GSSetLanguage(@"ja");[panel viewWillAppear:NO];
  [panel.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:7] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
  Capture(self.window,@"settings-history.png");
  CheckStationaryPolling(panel,self.window,^{
  [root dismissViewControllerAnimated:NO completion:^{
   UIViewController *menu=[UIViewController new];menu.view.backgroundColor=UIColor.secondarySystemBackgroundColor;
   [root presentViewController:menu animated:NO completion:^{
    GSPresentSettings(root); // Root already has a presented account menu.
    Await(^BOOL{return Panel(menu).viewIfLoaded.window!=nil;},^{
     UIViewController *first=menu.presentedViewController;
     GSPresentSettings(root);GSPresentSettings(nil);
     dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
      if(menu.presentedViewController!=first||first.presentedViewController){Finish(NO,@"duplicate settings presentation");return;}
      self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
      Capture(self.window,@"settings-dark.png");
      [root dismissViewControllerAnimated:NO completion:^{
       GSPresentSettings(nil);
       Await(^BOOL{return Panel(root).viewIfLoaded.window!=nil&&[GSUploadMonitorSnapshot()[@"reachable"]boolValue]&&GSEmbeddedRuntimeSnapshot()[@"uploadSummary"]!=nil;},^{
        // An empty queue has revision zero and must not manufacture completion.
        if(NativeRefreshes){Finish(NO,@"empty queue incorrectly announced completion");return;}
        CheckRealSheetPresentation(Panel(root),^{
         Finish(YES,@"detached, nested, repeated and nil-host presentation; real Liquid Glass action-sheet presentation/dismissal; stationary polling and changed-snapshot anchor retained; settings rendered; real jailed runtime online, launch completion observer active and authorization snapshot nonblocking");
        });
       },deadline);
      }];
     });
    },deadline);
   }];
  }];
  });
 },deadline);
 },deadline);
}
@end
@interface GSFixtureApp : UIResponder <UIApplicationDelegate> @end
@implementation GSFixtureApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{
 UISceneConfiguration *config=[[UISceneConfiguration alloc]initWithName:@"Fixture" sessionRole:session.role];config.delegateClass=GSFixtureScene.class;return config;
}
@end
int main(int argc,char **argv){@autoreleasepool{
 NSLog(@"Fixture: main");
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{Finish(NO,@"watchdog: no completion within 60 seconds after main");});
 return UIApplicationMain(argc,argv,nil,NSStringFromClass(GSFixtureApp.class));
}}
