#import "GSAppearance.h"
#import "../Shared/GSLocalization.h"
#import "GSPanel.h"
#import "GSExporter.h"
#import "GSBatchImport.h"
#import "GSAlbumPicker.h"
#import "GSNativeAccount.h"
#import "GSAccountConnection.h"
#if !GS_JAILED
#import "GSNativeRelay.h"
#else
#import "../Jailed/SideloadIdentity.h"
#endif
#import "GSNativeRouting.h"
#import "GSUploadDiagnostics.h"
#import "GSUnlimitedStorage.h"
#import "GSBackupRequests.h"
#import "GSPhotosIntegration.h"
#import "GSUploadMonitor.h"
#import "../Shared/IPCProtocol.h"
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#define GS_BACKUP_TITLE GSL(@"Route manual and automatic backups through GoToHP")
#define GS_ACCOUNT_HELP GSL(@"Connect or refresh your account.")
#if GS_JAILED
#define GS_BACKUP_HELP GSL(@"Enable Google Photos backup for automatic uploads. GoToHP controls the quality. Keep the app in the foreground.")
#define GS_QUEUED_HELP GSL(@"Keep the app open while uploading. Pending uploads resume next time.")
#define GS_AUTH_HELP GSL(@"Paste an EmbeddedSetup oauth_token or complete gotohp credential. Stored privately in this app, sent to Google, and hidden after saving.")
#else
#define GS_BACKUP_HELP GSL(@"Enable Google Photos backup for automatic uploads. GoToHP controls the quality. Keep the app open until the originals are queued; the daemon then uploads while authorization is available.")
#define GS_QUEUED_HELP GSL(@"Queued uploads continue while authorization is available. Reopen Google Photos to refresh authorization when needed.")
#define GS_AUTH_HELP GSL(@"Paste an EmbeddedSetup oauth_token or complete gotohp credential. Sent only to gotohpd and Google, and hidden after saving.")
#endif
@interface GSPanel () <PHPickerViewControllerDelegate>
@property(nonatomic,strong) NSArray *jobs;
@property(nonatomic,strong) NSDictionary *accounts;
@property(nonatomic,strong) NSMutableDictionary *options;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) NSUInteger stateGeneration;
@property(nonatomic) BOOL nativeAuthorizationFailed;
@property(nonatomic,strong) NSArray *sharedItems;
@property(nonatomic,copy) void (^activityCompletion)(void);
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,copy) NSString *statusLanguage;
@end
@implementation GSPanel
- (void)viewDidLoad{
 [super viewDidLoad];GSInstallNativeRouting();GSInstallUploadDiagnostics();GSInstallUnlimitedStorage();self.title=@"GoToHP";self.jobs=@[];self.statusText=GSL(@"Checking the connection…");self.statusLanguage=GSLanguage();
 self.navigationItem.leftBarButtonItem=GSNavigationButton(GSL(@"Done"),self,@selector(close));
 self.navigationItem.rightBarButtonItem=GSNavigationButton(self.settingsMode?GSL(@"Reconnect"):GSL(@"Add"),self,@selector(primary));
#if GS_JAILED
 self.navigationItem.prompt=nil;
#endif
 if(self.settingsMode&&GSIsGooglePhotos()){
 UIBarButtonItem *upload=GSNavigationButton(GSL(@"Uploads"),self,@selector(openUploadPanel));
 self.navigationItem.rightBarButtonItems=@[self.navigationItem.rightBarButtonItem,upload];
 }
 if(!self.settingsMode&&GSIsGooglePhotos()){
 UIBarButtonItem *settings=GSNavigationButton(GSL(@"Settings"),self,@selector(openEmbeddedSettings));
 self.navigationItem.rightBarButtonItems=@[self.navigationItem.rightBarButtonItem,settings];
 }
 self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=72;
 self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
 self.tableView.tintColor=[UIColor colorWithRed:0.10 green:0.45 blue:0.91 alpha:1];
 self.navigationController.navigationBar.tintColor=self.tableView.tintColor;
 [self refresh];
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self updateNavigationLabels];[self reloadTablePreservingPosition];}
- (void)updateNavigationLabels{
 self.navigationItem.leftBarButtonItem.title=GSL(@"Done");
 self.navigationItem.rightBarButtonItem.title=self.settingsMode?GSL(@"Reconnect"):GSL(@"Add");
 if(self.navigationItem.rightBarButtonItems.count>1)self.navigationItem.rightBarButtonItems[1].title=self.settingsMode?GSL(@"Uploads"):GSL(@"Settings");
}
- (void)chooseLanguage{
 UIAlertController *sheet=[UIAlertController alertControllerWithTitle:GSL(@"Language") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
 NSArray *codes=@[@"system",@"ja",@"en"],*names=@[GSL(@"System default"),GSL(@"Japanese"),@"English"];
 for(NSUInteger i=0;i<codes.count;i++){NSString *code=codes[i];NSString *title=[code isEqual:GSLanguageOverride()]?[@"✓ " stringByAppendingString:names[i]]:names[i];
  [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){GSSetLanguage(code);[self updateNavigationLabels];[self reloadTablePreservingPosition];[self refresh];}]];
 }
 [sheet addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];[self sheet:sheet];
}
- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];__weak GSPanel *weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t){[weak refresh];}];}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (void)openUploadPanel{
 if(self.busy)return;
 GSPanel *panel=[[GSPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];
 [self.navigationController pushViewController:panel animated:YES];
}
- (void)openEmbeddedSettings{
 if(self.busy)return;
 GSPanel *settings=[[GSPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];settings.settingsMode=YES;
 [self.navigationController pushViewController:settings animated:YES];
}
- (void)close{
 // Closing the screen does not cancel queued work or wait for authentication.
 if(self.navigationController.viewControllers.count>1){[self.navigationController popViewControllerAnimated:YES];return;}
 if(self.activityCompletion)self.activityCompletion();else[self dismissViewControllerAnimated:YES completion:nil];
}
- (BOOL)isInteractingWithTable{return self.tableView.tracking||self.tableView.dragging||self.tableView.decelerating;}
- (void)reloadTablePreservingPosition{
 UITableView *table=self.tableView;
 NSIndexPath *anchor=table.indexPathsForVisibleRows.firstObject;
 CGFloat delta=anchor?table.contentOffset.y-[table rectForRowAtIndexPath:anchor].origin.y:0;
 __block CGPoint offset=table.contentOffset;
 [UIView performWithoutAnimation:^{
  [table reloadData];[table layoutIfNeeded];
  if(anchor&&anchor.section<[table numberOfSections]&&anchor.row<[table numberOfRowsInSection:anchor.section])
   offset.y=[table rectForRowAtIndexPath:anchor].origin.y+delta;
  CGFloat minimum=-table.adjustedContentInset.top;
  CGFloat maximum=MAX(minimum,table.contentSize.height-table.bounds.size.height+table.adjustedContentInset.bottom);
  [table setContentOffset:CGPointMake(offset.x,MIN(MAX(offset.y,minimum),maximum)) animated:NO];
 }];
}
- (void)message:(NSString *)message{
 BOOL changed=![self.statusText isEqual:message]||![self.statusLanguage isEqual:GSLanguage()];
 self.statusText=message;self.statusLanguage=GSLanguage();if(changed)[self reloadTablePreservingPosition];
}
- (void)refresh{
 if(self.busy||self.refreshing||self.nativeAuthorizationFailed||[self isInteractingWithTable])return;self.refreshing=YES;
 NSUInteger generation=self.stateGeneration;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
 NSError *error=nil;NSDictionary *accounts=GSRequest(@{@"op":@"accounts"},&error);NSDictionary *options=accounts?GSRequest(@{@"op":@"options"},&error):nil;
 NSMutableArray *jobs=[NSMutableArray array];NSInteger cursor=0;NSDictionary *page=nil;
 if(options)do{page=GSRequest(@{@"op":@"list",@"cursor":@(cursor)},&error);if(!page)break;[jobs addObjectsFromArray:page[@"jobs"]?:@[]];cursor=[page[@"next"]integerValue];}while(cursor>=0);
 dispatch_async(dispatch_get_main_queue(),^{self.refreshing=NO;
 // A poll completing during a gesture is superseded by the next idle poll.
 // Do not change the data source count or invalidate self-sizing rows mid-scroll.
 if([self isInteractingWithTable])return;
 if(generation!=self.stateGeneration){[self refresh];return;}if(error){[self message:error.localizedDescription];return;}
 BOOL changed=![self.accounts isEqual:accounts]||![self.options isEqual:options]||![self.jobs isEqual:jobs];
 NSString *previousStatus=self.statusText,*previousLanguage=self.statusLanguage;
 self.accounts=accounts;self.options=[options mutableCopy];self.jobs=jobs;
 NSString *readiness=GSL(@"Ready to upload");
 if([options[@"paused"]boolValue])readiness=GSL(@"Uploads paused");
 else if(![page[@"online"]boolValue])readiness=GSL(@"Waiting for a connection or app launch");
 else if([options[@"wifiOnly"]boolValue]&&![page[@"wifi"]boolValue])readiness=GSL(@"Waiting for Wi-Fi");
 else if([options[@"chargingOnly"]boolValue]&&![page[@"charging"]boolValue])readiness=GSL(@"Waiting for charging");
 NSString *authorization=GSL(@"Account configured");
#if !GS_JAILED
 if([accounts[@"nativeAuthorization"]isEqual:@"ready"])authorization=GSL(@"Authenticated");
 else if([accounts[@"nativeAuthorization"]isEqual:@"waiting"])readiness=GSL(@"Open Google Photos and reconnect to refresh authorization.");
#endif
#if GS_JAILED
 NSDictionary *runtime=GSEmbeddedRuntimeSnapshot();
 if([runtime[@"authorization"]isEqual:@"validated"])authorization=GSL(@"Authenticated");
 if(![options[@"paused"]boolValue]){
  if(![runtime[@"conditionsAccepted"]boolValue])readiness=GSL(@"Could not apply upload conditions (check diagnostics)");
  else if(![runtime[@"foreground"]boolValue])readiness=GSL(@"Waiting for the app to enter the foreground");
  else if([runtime[@"path"]isEqual:@"unknown"])readiness=GSL(@"Checking network status");
  else if(![runtime[@"networkOnline"]boolValue])readiness=GSL(@"Waiting for a network connection");
 }
#endif
 self.statusText=[accounts[@"selected"]length]?[NSString stringWithFormat:@"%@ · %@",authorization,readiness]:GSL(@"Connect an account to continue");
 NSString *importError=GSNativeRoutingSnapshot()[@"lastError"];if(importError)self.statusText=importError;self.statusLanguage=GSLanguage();
 NSDictionary *batch=GSBatchImportSnapshot();if([batch[@"total"]unsignedIntegerValue])self.statusText=[self.statusText stringByAppendingFormat:@"\n%@",[self batchStatus:batch]];
 if(changed||![previousStatus isEqual:self.statusText]||![previousLanguage isEqual:self.statusLanguage])[self reloadTablePreservingPosition];
 });
 });
}
- (NSArray<NSDictionary *> *)controlSections{
 if(!self.settingsMode)return @[@{@"title":GSL(@"Uploads"),@"rows":@[@14,@17,@18],@"footer":[GSL(@"For large batches, choose an album. The photo picker is limited to 100 items per selection.\n") stringByAppendingString:GS_QUEUED_HELP]}];
 NSMutableArray *groups=[NSMutableArray array];
 NSArray *accountRows=@[@13,@6,@7];
 if(GSIsGooglePhotos())accountRows=@[@13];
 [groups addObject:@{@"title":GSL(@"Account"),@"rows":accountRows}];
 [groups addObject:@{@"title":GSL(@"Upload settings"),@"rows":@[@0,@1,@2,@3,@4,@5],@"footer":[GSL(@"Pixel 1 requests original quality without storage usage (Pixel XL). Quality is fixed when queued. Verify storage usage and original data in Google Photos.\n") stringByAppendingString:GS_QUEUED_HELP]}];
 if(GSIsGooglePhotos())[groups addObject:@{@"title":GSL(@"Google Photos integration"),@"rows":@[@10],@"footer":GS_BACKUP_HELP}];
 [groups addObject:@{@"title":GSL(@"Queue management"),@"rows":@[@8,@9]}];
 if(GSIsGooglePhotos())[groups addObject:@{@"title":GSL(@"Diagnostics"),@"rows":@[@11,@12],@"footer":GSL(@"Troubleshoot compatibility. Tokens and media are never recorded.")}];
 [groups addObject:@{@"title":GSL(@"Appearance"),@"rows":GSIsGooglePhotos()?@[@15,@16]:@[@15],@"footer":GSIsGooglePhotos()?GSL(@"Reopen the profile menu to apply changes. Unlimited storage affects only the display; account limits and upload quality stay unchanged."):GSL(@"Reopen the profile menu to update its language.")}];
 return groups;
}
- (NSInteger)queueSection{return self.controlSections.count+1;}
- (NSInteger)controlAtPath:(NSIndexPath *)path{
 NSArray *sections=self.controlSections;
 if(path.section<1||path.section>sections.count)return -1;
 NSArray *rows=sections[path.section-1][@"rows"];
 return path.row<rows.count?[rows[path.row]integerValue]:-1;
}
- (NSString *)qualityTitle:(NSString *)quality{
 return @{@"original":GSL(@"Original quality · Pixel 1"),@"saver":GSL(@"Storage saver · Pixel 2"),@"quota":GSL(@"Original quality · Uses account storage")}[quality?:@""]?:GSL(@"Not configured");
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.queueSection+1;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
 if(section==0)return 1;
 if(section==self.queueSection)return MAX(self.jobs.count,1);
 return [self.controlSections[section-1][@"rows"]count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{
 if(section==0)return GSL(@"Connection status");
 if(section==self.queueSection)return [NSString stringWithFormat:GSL(@"Upload history (%lu)"),(unsigned long)self.jobs.count];
 return self.controlSections[section-1][@"title"];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section{
 if(section==0||section==self.queueSection)return nil;
 return self.controlSections[section-1][@"footer"];
}
- (BOOL)switchValueForControl:(NSInteger)control{
 if(control==10)return GSNativeRoutingEnabled();
 if(control==11)return GSUploadDiagnosticsEnabled();
 if(control==16)return GSUnlimitedStorageEnabled();
 return [self.options[@[@"wifiOnly",@"chargingOnly",@"paused"][control-3]]boolValue];
}
- (void)controlSwitchChanged:(UISwitch *)toggle{
 NSInteger control=toggle.tag;BOOL desired=toggle.on;
 [toggle setOn:[self switchValueForControl:control] animated:YES];
 if(control==16){GSSetUnlimitedStorage(desired);[self reloadTablePreservingPosition];return;}
 if(self.busy)return;
 if(control==10){[self toggleNativeRouting];return;}
 if(control==11){GSSetUploadDiagnostics(desired);[self reloadTablePreservingPosition];return;}
 NSMutableDictionary *options=[self.options mutableCopy];if(!options)return;
 options[@[@"wifiOnly",@"chargingOnly",@"paused"][control-3]]=@(desired);
 [self request:@{@"op":@"configure",@"options":options}];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path{
 UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
 cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
 cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
 cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
 cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
 cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.imageView.tintColor=tableView.tintColor;
 if(path.section==0){
  cell.textLabel.text=[self.accounts[@"selected"]length]?self.accounts[@"selected"]:GSL(@"Google Photos account");
  cell.detailTextLabel.text=GSLocalizedStatus(self.statusText,self.statusLanguage);cell.imageView.image=[UIImage systemImageNamed:@"person.crop.circle"];
  cell.selectionStyle=UITableViewCellSelectionStyleNone;
  if(self.busy){UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];[spinner startAnimating];cell.accessoryView=spinner;}
  return cell;
 }
 NSInteger control=[self controlAtPath:path];
 if(control>=0){
  NSArray *titles=@[GSL(@"Quality"),GSL(@"Concurrent uploads"),GSL(@"Retry limit"),GSL(@"Wi-Fi only"),GSL(@"Charging only"),GSL(@"Pause uploads"),GSL(@"Destination account"),GSL(@"Remove account from GoToHP"),GSL(@"Retry failed uploads"),GSL(@"Clear completed history"),GS_BACKUP_TITLE,GSL(@"Upload diagnostics"),GSL(@"Export diagnostics"),GSL(@"Connect or refresh account"),GSL(@"Choose photos and videos"),GSL(@"Language"),GSL(@"Show unlimited storage"),GSL(@"Choose album"),GSL(@"Stop preparing")];
  NSArray *icons=@[@"photo",@"square.stack.3d.up",@"arrow.clockwise",@"wifi",@"battery.100.bolt",@"pause.circle",@"person.crop.circle.badge.checkmark",@"person.crop.circle.badge.minus",@"arrow.clockwise.circle",@"checkmark.circle",@"arrow.triangle.branch",@"waveform.path.ecg",@"square.and.arrow.up",@"person.crop.circle.badge.checkmark",@"plus.circle",@"globe",@"cloud",@"rectangle.stack",@"stop.circle"];
  cell.textLabel.text=titles[control];cell.imageView.image=[UIImage systemImageNamed:icons[control]];
  cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
  if(control==17)cell.detailTextLabel.text=GSL(@"Upload an entire album; browse folders to choose an album.");
  if(control==18){BOOL active=[GSBatchImportSnapshot()[@"active"]boolValue];cell.textLabel.textColor=active?UIColor.systemRedColor:UIColor.secondaryLabelColor;cell.accessoryType=UITableViewCellAccessoryNone;cell.detailTextLabel.text=GSL(@"Stop after the current item. Queued uploads continue.");}
  if(control==15)cell.detailTextLabel.text=[GSLanguageOverride()isEqual:@"system"]?GSL(@"System default"):[GSLanguageOverride()isEqual:@"ja"]?GSL(@"Japanese"):@"English";
  if(control==0)cell.detailTextLabel.text=[self qualityTitle:self.options[@"quality"]];
  if(control==1)cell.detailTextLabel.text=[NSString stringWithFormat:GSL(@"Concurrent uploads: %@"),self.options[@"concurrent"]?:@1];
  if(control==2)cell.detailTextLabel.text=[NSString stringWithFormat:GSL(@"Retry limit: %@"),self.options[@"retries"]?:@3];
  if(control==6)cell.detailTextLabel.text=self.accounts[@"selected"];
  if(control==13)cell.detailTextLabel.text=GSL(@"Check the connection for the signed-in account");
  if(control==7)cell.textLabel.textColor=UIColor.systemRedColor;
  if((control>=3&&control<=5)||control==10||control==11||control==16){
   UISwitch *toggle=[UISwitch new];toggle.tag=control;toggle.on=[self switchValueForControl:control];
   toggle.accessibilityLabel=titles[control];toggle.onTintColor=tableView.tintColor;
   toggle.enabled=control==16?GSUnlimitedStorageAvailable():!self.busy&&(control==10?GSNativeRoutingAvailable():control==11?GSUploadDiagnosticsAvailable():self.options!=nil);
   [toggle addTarget:self action:@selector(controlSwitchChanged:) forControlEvents:UIControlEventValueChanged];
   cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;
  }
  if(control==16&&!GSUnlimitedStorageAvailable())cell.detailTextLabel.text=GSL(@"Unavailable in this version");
  if(control==10&&!GSNativeRoutingAvailable())cell.detailTextLabel.text=GSL(@"Unavailable in this version");
  return cell;
 }
 if(!self.jobs.count){cell.textLabel.text=GSL(@"No uploads yet");cell.detailTextLabel.text=GSL(@"Use Choose photos and videos to add items.");cell.imageView.image=[UIImage systemImageNamed:@"tray"];cell.selectionStyle=UITableViewCellSelectionStyleNone;return cell;}
 NSDictionary *job=self.jobs[path.row];NSArray *resources=job[@"resources"];
 NSString *state=job[@"state"];NSDictionary *states=@{@"pending":GSL(@"Pending"),@"preparing":GSL(@"Preparing"),@"uploading":GSL(@"Uploading"),@"committing":GSL(@"Committing"),@"completed":GSL(@"Completed"),@"failed":GSL(@"Failed"),@"cancelled":GSL(@"Cancelled")};
 cell.textLabel.text=resources.firstObject[@"name"]?:GSL(@"Media");
 long long uploaded=[job[@"uploaded"]longLongValue],total=[job[@"total"]longLongValue];
 NSString *sizes=[NSString stringWithFormat:@"%@ / %@",[NSByteCountFormatter stringFromByteCount:uploaded countStyle:NSByteCountFormatterCountStyleFile],[NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile]];
 cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@\n%@",states[state?:@""]?:GSL(@"Checking status"),[self qualityTitle:job[@"quality"]],sizes];
 cell.imageView.image=[UIImage systemImageNamed:[state isEqual:@"completed"]?@"checkmark.circle.fill":[state isEqual:@"failed"]?@"exclamationmark.circle":@"icloud.and.arrow.up"];
 if([state isEqual:@"failed"]){cell.imageView.tintColor=UIColor.systemRedColor;cell.detailTextLabel.text=[cell.detailTextLabel.text stringByAppendingString:GSL(@"\nTap to retry")];}else if([state isEqual:@"completed"])cell.imageView.tintColor=UIColor.systemGreenColor;
 cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)chooseValueForControl:(NSInteger)control{
 NSString *key=@[@"quality",@"concurrent",@"retries"][control];
 UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@[GSL(@"Quality"),GSL(@"Concurrent uploads"),GSL(@"Retry limit")][control] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
 NSArray *values=control==0?@[@"original",@"saver",@"quota"]:control==1?@[@1,@2,@3,@4]:@[@0,@1,@2,@3,@4,@5,@6,@7,@8,@9,@10];
 for(id value in values){
  NSString *title=control==0?[self qualityTitle:value]:[NSString stringWithFormat:@"%@ %@",value,control==1?GSL(@"uploads"):GSL(@"retries")];
  if([value isEqual:self.options[key]])title=[@"✓ " stringByAppendingString:title];
  [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSMutableDictionary *options=[self.options mutableCopy];if(!options)return;options[key]=value;[self request:@{@"op":@"configure",@"options":options}];}]];
 }
 [sheet addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];[self sheet:sheet];
}
- (void)request:(NSDictionary *)request{
 if(self.busy)return;self.stateGeneration++;self.busy=YES;[self message:GSL(@"Applying settings…")];self.navigationItem.rightBarButtonItem.enabled=NO;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *error=nil;GSRequest(request,&error);dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;self.navigationItem.rightBarButtonItem.enabled=YES;if(error)[self message:error.localizedDescription];else[self refresh];});});
}
- (void)sheet:(UIAlertController *)sheet{sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,80,1,1);[self presentViewController:sheet animated:YES completion:nil];}
- (void)primary{if(self.busy)return;if(self.settingsMode)[self addAccount];else if(self.sharedItems.count){NSArray *items=self.sharedItems;self.sharedItems=nil;if([items.firstObject isKindOfClass:PHAsset.class])[self importAssets:items];else[self importURLs:items];}else[self choose];}
- (void)connectNativeAccount{
 NSDictionary *account=GSNativeAccountSummary();
 if(!account){[self message:GSL(@"Could not retrieve the Google Photos account. Reopen the profile menu.")];return;}
 self.stateGeneration++;self.nativeAuthorizationFailed=NO;self.busy=YES;[self message:GSL(@"Checking the signed-in Google Photos account…")];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  NSError *error=nil;
#if GS_JAILED
  GSRequest(@{@"op":@"account_native",@"account":account[@"email"],@"nativeID":account[@"identifier"]},&error);
#else
  GSConnectDaemonAccount(account,&error);
#endif
  dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;
   if(error){self.nativeAuthorizationFailed=YES;[self message:GSL(@"Google Photos authorization failed. Check your sign-in, then tap Reconnect.")];return;}
   [self refresh];
  });
 });
}
- (void)addAccount{
 if(GSIsGooglePhotos()){[self connectNativeAccount];return;}
 UIAlertController *a=[UIAlertController alertControllerWithTitle:GSL(@"Add Google account") message:GS_AUTH_HELP preferredStyle:UIAlertControllerStyleAlert];
 [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.secureTextEntry=YES;f.autocorrectionType=UITextAutocorrectionTypeNo;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.placeholder=@"oauth_token / credential";}];
 [a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:GSL(@"Connect") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *secret=a.textFields.firstObject.text;a.textFields.firstObject.text=@"";[self request:@{@"op":@"account_add",@"secret":secret?:@""}];}]];[self sheet:a];
}
- (void)exportUploadDiagnostics{
 NSMutableDictionary *snapshot=[GSUploadDiagnosticsSnapshot() mutableCopy];
 snapshot[@"manualRouting"]=GSNativeRoutingSnapshot();
 snapshot[@"batchImport"]=GSBatchImportSnapshot();
 snapshot[@"unlimitedStorage"]=GSUnlimitedStorageSnapshot();
 snapshot[@"accountConnection"]=GSAccountConnectionSnapshot();
 snapshot[@"backupRouting"]=GSBackupRequestsSnapshot();
 snapshot[@"photosIntegration"]=GSPhotosIntegrationSnapshot();
 snapshot[@"completionMonitor"]=GSUploadMonitorSnapshot();
#if !GS_JAILED
 snapshot[@"ipc"]=GSIPCDiagnosticsSnapshot();
 snapshot[@"nativeAuthentication"]=GSNativeRelaySnapshot();
#endif
#if GS_JAILED
 snapshot[@"runtime"]=GSEmbeddedRuntimeSnapshot();
 snapshot[@"sideloadIdentity"]=GSSideloadIdentitySnapshot();
#endif
 NSData *json=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
 NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"gotohp-upload-diagnostics.json"]];
 if(!json||![json writeToURL:file options:NSDataWritingAtomic error:nil]){[self message:GSL(@"Could not export diagnostics.")];return;}
 UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:@[file] applicationActivities:nil];
 share.popoverPresentationController.sourceView=self.view;share.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,80,1,1);
 [self presentViewController:share animated:YES completion:nil];
}
- (void)toggleNativeRouting{
 if(GSNativeRoutingEnabled()){GSSetNativeRouting(NO,nil);[self reloadTablePreservingPosition];return;}
 if(!GSBackupRequestsAvailable()){[self message:GSL(@"Backup integration is unavailable in this version. Choose photos from Uploads.")];return;}
 if(!GSNativeRoutingAvailable()){[self message:GSL(@"Backup integration is unavailable in this version. Choose photos from Uploads.")];return;}
 NSString *account=self.accounts[@"selected"];
 if(!account.length){[self message:GS_ACCOUNT_HELP];return;}
 UIAlertController *a=[UIAlertController alertControllerWithTitle:GS_BACKUP_TITLE message:[NSString stringWithFormat:GSL(@"Destination: %@\n%@\nCheck failures and retries in the GoToHP queue. No native upload fallback."),account,GS_BACKUP_HELP] preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:GSL(@"Enable") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){GSSetNativeRouting(YES,account);[self reloadTablePreservingPosition];}]];[self sheet:a];
}
- (void)accountAction:(BOOL)remove{
 UIAlertController *a=[UIAlertController alertControllerWithTitle:remove?GSL(@"Remove account"):GSL(@"Destination account") message:remove?GSL(@"Cancel this account's unfinished jobs first."):nil preferredStyle:UIAlertControllerStyleActionSheet];
 for(NSDictionary *account in self.accounts[@"accounts"]){NSString *email=account[@"email"];[a addAction:[UIAlertAction actionWithTitle:email style:remove?UIAlertActionStyleDestructive:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self request:@{@"op":remove?@"account_remove":@"account_select",@"account":email}];}]];}
 [a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];[self sheet:a];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path{
 [tableView deselectRowAtIndexPath:path animated:YES];
 NSInteger control=[self controlAtPath:path];
 if(control==12){[self exportUploadDiagnostics];return;}
 if(control==16)return;
 if(control==18){GSStopBatchImport(NO);return;}
 if(self.busy)return;
 if(control>=0){
  if(control==15){[self chooseLanguage];return;}
  if(control==14){[self choose];return;}
  if(control==17){[self chooseAlbum];return;}
  if(control==13){[self addAccount];return;}
  if(control==10){[self toggleNativeRouting];return;}
  if(control==11){GSSetUploadDiagnostics(!GSUploadDiagnosticsEnabled());[self reloadTablePreservingPosition];return;}
  if(control<3){[self chooseValueForControl:control];return;}
  if(control<6)return; // Use the visible switch; no hidden value cycling.
  if(control==6||control==7)[self accountAction:control==7];
  else [self request:@{@"op":control==8?@"retry_failed":@"clear_completed"}];
 }else if(path.section==self.queueSection&&path.row<self.jobs.count){
 NSDictionary *j=self.jobs[path.row];NSString *state=j[@"state"];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:j[@"resources"][0][@"name"] message:j[@"error"] preferredStyle:UIAlertControllerStyleActionSheet];
 if([state isEqual:@"failed"])[a addAction:[UIAlertAction actionWithTitle:GSL(@"Retry") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self request:@{@"op":@"retry",@"id":j[@"id"]}];}]];
 if(![state isEqual:@"completed"]&&![state isEqual:@"cancelled"])[a addAction:[UIAlertAction actionWithTitle:GSL(@"Cancel upload") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[self request:@{@"op":@"cancel",@"id":j[@"id"]}];}]];
 [a addAction:[UIAlertAction actionWithTitle:GSL(@"Close") style:UIAlertActionStyleCancel handler:nil]];[self sheet:a];
 }
}
- (void)choose{
 if(![self.accounts[@"selected"]length]){[self message:GS_ACCOUNT_HELP];return;}
 if(![NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"]){[self message:GSL(@"This app cannot request access to your photos.")];return;}
 [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status){dispatch_async(dispatch_get_main_queue(),^{
 if(status!=PHAuthorizationStatusAuthorized&&status!=PHAuthorizationStatusLimited){[self message:GSL(@"Allow access to your photo library.")];return;}
 PHPickerConfiguration *c=[[PHPickerConfiguration alloc]initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];c.selectionLimit=100;c.preferredAssetRepresentationMode=PHPickerConfigurationAssetRepresentationModeCurrent;
 PHPickerViewController *picker=[[PHPickerViewController alloc]initWithConfiguration:c];picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
 });}];
}
- (void)chooseAlbum{
 if(![self.accounts[@"selected"]length]){[self message:GS_ACCOUNT_HELP];return;}
 if(![NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"]){[self message:GSL(@"This app cannot request access to your photos.")];return;}
 [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status){dispatch_async(dispatch_get_main_queue(),^{
  if(status!=PHAuthorizationStatusAuthorized&&status!=PHAuthorizationStatusLimited){[self message:GSL(@"Allow access to your photo library.")];return;}
  GSAlbumPicker *albums=[[GSAlbumPicker alloc]initWithStyle:UITableViewStyleInsetGrouped];
  __weak GSPanel *weak=self;
  albums.selection=^(PHFetchResult<PHAsset *> *assets){
   [weak startImportCount:assets.count source:@"album" assets:YES provider:^id(NSUInteger index){return [assets objectAtIndex:index];}];
  };
  [self presentViewController:[[UINavigationController alloc]initWithRootViewController:albums] animated:YES completion:nil];
 });}];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results{
 // Retain identifiers only. PHPicker's item providers need not load any media.
 NSMutableArray *ids=[NSMutableArray arrayWithCapacity:results.count];
 for(PHPickerResult *result in results)[ids addObject:result.assetIdentifier?:NSNull.null];
 [picker dismissViewControllerAnimated:YES completion:^{
  if(ids.count)[self startImportCount:ids.count source:@"picker" assets:YES provider:GSPhotoIdentifierProvider(ids)];
 }];
}
- (NSString *)batchStatus:(NSDictionary *)state{
 NSString *counts=[NSString stringWithFormat:GSL(@"Queued %lu / %lu · Failed %lu · Remaining %lu"),[state[@"queued"]unsignedLongValue],[state[@"total"]unsignedLongValue],[state[@"failed"]unsignedLongValue],[state[@"remaining"]unsignedLongValue]];
 NSString *reason=state[@"stopReason"],*help=nil;
 if([state[@"active"]boolValue])help=GSL(@"Preparing originals. Keep the app open.");
 else if([reason isEqual:@"account_changed"])help=GSL(@"Preparation stopped because the account changed. Reconnect and select the remaining items.");
 else if([reason isEqual:@"queue_rejected"]||[reason isEqual:@"service_unavailable"]||[reason isEqual:@"local_storage"])help=GSL(@"Preparation stopped. Check the connection, free space and queue, then select the remaining items.");
 else if(reason)help=GSL(@"Preparation stopped. Items already queued are kept.");
 else help=[state[@"failed"]unsignedIntegerValue]?GSL(@"Some originals could not be read. Check photo access and iCloud downloads, then retry the selection."):GS_QUEUED_HELP;
 return [NSString stringWithFormat:@"%@\n%@",counts,help];
}
- (void)importAssets:(NSArray<PHAsset *> *)assets{
 NSArray *selection=[assets copy];[self startImportCount:selection.count source:@"share" assets:YES provider:^id(NSUInteger index){return selection[index];}];
}
- (void)importURLs:(NSArray<NSURL *> *)urls{
 NSArray *selection=[urls copy];[self startImportCount:selection.count source:@"share" assets:NO provider:^id(NSUInteger index){return selection[index];}];
}
- (void)startImportCount:(NSUInteger)count source:(NSString *)source assets:(BOOL)assets provider:(GSBatchItemProvider)provider{
 if(!count)return;
 if(self.busy||[GSBatchImportSnapshot()[@"active"]boolValue]){[self message:GSL(@"Wait for the operation to finish, then retry.")];return;}
 NSString *account=self.accounts[@"selected"],*identity=GSNativeAccountSummary()[@"identifier"];
 if(!account.length||(GSIsGooglePhotos()&&!identity.length)){[self message:GS_ACCOUNT_HELP];return;}
 self.stateGeneration++;self.busy=YES;
 __weak GSPanel *weak=self;
 __block UIBackgroundTaskIdentifier task=UIBackgroundTaskInvalid;
 task=[UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{GSStopBatchImport(YES);if(task!=UIBackgroundTaskInvalid){[UIApplication.sharedApplication endBackgroundTask:task];task=UIBackgroundTaskInvalid;}}];
 BOOL started=GSStartBatchImport(count,source,assets,provider,account,identity,^(NSDictionary *state){
  [weak message:[weak batchStatus:state]];
 },^(NSDictionary *state){
  if(task!=UIBackgroundTaskInvalid){[UIApplication.sharedApplication endBackgroundTask:task];task=UIBackgroundTaskInvalid;}
  weak.busy=NO;[weak message:[weak batchStatus:state]];
 });
 if(!started){self.busy=NO;if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];[self message:GSL(@"Wait for the operation to finish, then retry.")];}
 else [self message:[self batchStatus:GSBatchImportSnapshot()]];
}
@end

void GSPresent(UIViewController *host){if(!host)return;GSPanel *panel=[[GSPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:panel];[host presentViewController:nav animated:YES completion:nil];}
static UIViewController *GSTopPresenter(UIViewController *hint){
 UIViewController *host=hint;
 if(![host isKindOfClass:UIViewController.class]||!host.viewIfLoaded.window||host.isBeingDismissed){
  host=nil;
  for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
   if(scene.activationState!=UISceneActivationStateForegroundActive||![scene isKindOfClass:UIWindowScene.class])continue;
   for(UIWindow *window in ((UIWindowScene *)scene).windows)
    if(window.isKeyWindow&&window.windowLevel==UIWindowLevelNormal)host=window.rootViewController;
  }
 }
 while(host.presentedViewController&&!host.presentedViewController.isBeingDismissed)host=host.presentedViewController;
 return host;
}
void GSPresentSettings(UIViewController *hint){
 dispatch_async(dispatch_get_main_queue(),^{
  UIViewController *host=GSTopPresenter(hint);
  UIViewController *visible=[host isKindOfClass:UINavigationController.class]?((UINavigationController *)host).topViewController:host;
  if(!host||[visible isKindOfClass:GSPanel.class])return; // Repeated taps never stack settings.
  id<UIViewControllerTransitionCoordinator> transition=host.transitionCoordinator;
  if(transition&&transition.isAnimated){
   BOOL queued=[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){GSPresentSettings(nil);}];
   if(queued)return;
  }
  GSPanel *panel=[[GSPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];panel.settingsMode=YES;
  UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:panel];
  nav.modalPresentationStyle=UIModalPresentationPageSheet;
  [host presentViewController:nav animated:YES completion:nil];
 });
}
@interface GSLauncher : NSObject
+ (void)open:(UIButton *)button;
@end
@implementation GSLauncher
+ (void)open:(UIButton *)button{UIViewController *host=button.window.rootViewController;while(host.presentedViewController)host=host.presentedViewController;GSPresent(host);}
@end
static char GSLauncherKey;
void GSInstallButton(UIWindow *window){
 if(GSIsGooglePhotos())return;
 if(window.windowLevel!=UIWindowLevelNormal||!window.rootViewController||objc_getAssociatedObject(window,&GSLauncherKey))return;
 UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:@"GoToHP" forState:UIControlStateNormal];BOOL glass=GSApplyGlassButton(button);if(!glass){button.backgroundColor=UIColor.secondarySystemBackgroundColor;button.layer.cornerRadius=18;}button.accessibilityLabel=GSL(@"Open the GoToHP upload queue");
 [button addTarget:GSLauncher.class action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];button.translatesAutoresizingMaskIntoConstraints=NO;[window addSubview:button];
 [NSLayoutConstraint activateConstraints:@[[button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-12],[button.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-65],(glass?[button.widthAnchor constraintGreaterThanOrEqualToConstant:84]:[button.widthAnchor constraintEqualToConstant:84]),(glass?[button.heightAnchor constraintGreaterThanOrEqualToConstant:44]:[button.heightAnchor constraintEqualToConstant:40])]];
 objc_setAssociatedObject(window,&GSLauncherKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@interface GSUploadActivity ()
@property(nonatomic,strong) NSArray *items;
@end
@implementation GSUploadActivity
- (NSString *)activityType{return @"dev.tqmane.gunshot.upload";}
- (NSString *)activityTitle{return GSL(@"Upload with GoToHP");}
- (UIImage *)activityImage{return [UIImage systemImageNamed:@"icloud.and.arrow.up"];}
- (BOOL)canPerformWithActivityItems:(NSArray *)items{if(!items.count)return NO;BOOL assets=[items.firstObject isKindOfClass:PHAsset.class];for(id i in items)if(assets?![i isKindOfClass:PHAsset.class]:!([i isKindOfClass:NSURL.class]&&[i isFileURL]))return NO;return YES;}
- (void)prepareWithActivityItems:(NSArray *)items{self.items=items;}
- (UIViewController *)activityViewController{
 GSPanel *panel=[[GSPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];
 panel.sharedItems=self.items;
 __weak GSUploadActivity *weak=self;panel.activityCompletion=^{[weak activityDidFinish:YES];};
 // Use an explicit button so opening the activity does not upload automatically.
 panel.navigationItem.prompt=GSL(@"Tap Add to queue your selection.");
 return [[UINavigationController alloc]initWithRootViewController:panel];
}
@end
