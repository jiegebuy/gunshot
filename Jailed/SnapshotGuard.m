#import "SnapshotGuard.h"
#import "../Shared/GSPhotosCompatibility.h"
#if GS_TEST_SNAPSHOT
#import "../tests/background_upload_shim.h"
#else
#import <UIKit/UIKit.h>
#endif

static BOOL GSInactive;
static NSMapTable *GSPendingIcons;
static void (*GSIconState)(id,SEL,unsigned char);
static void (*GSReuseCell)(id,SEL);
static void GSSetIconState(id cell,SEL selector,unsigned char state){
 if(GSInactive||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){
  [GSPendingIcons setObject:@(state) forKey:cell];return;
 }
 [GSPendingIcons removeObjectForKey:cell];GSIconState(cell,selector,state);
}
static void GSPrepareCell(id cell,SEL selector){
 [GSPendingIcons removeObjectForKey:cell];GSReuseCell(cell,selector);
}
static void GSDrainIcons(void){
 // Return to the run loop between small batches of deferred view mutations.
 dispatch_async(dispatch_get_main_queue(),^{
  if(GSInactive||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
  NSMutableArray *cells=[NSMutableArray arrayWithCapacity:8];
  for(id cell in GSPendingIcons.keyEnumerator){[cells addObject:cell];if(cells.count==8)break;}
  for(id cell in cells){
   if(GSInactive||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
   NSNumber *state=[GSPendingIcons objectForKey:cell];[GSPendingIcons removeObjectForKey:cell];
   if(state)GSIconState(cell,NSSelectorFromString(@"setAutoBackupIconForState:"),state.unsignedCharValue);
  }
  if(GSPendingIcons.count)GSDrainIcons();
 });
}
void GSInstallSnapshotGuard(void){
 static BOOL installed;
 if(installed||!GSPhotosHostSupported()||![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]isEqual:@"7.92.0"])return;
 if(@available(iOS 27.0,*)){
  Class cls=NSClassFromString(@"PHSMediaItemCell");
  if(!GSPhotosHasMethod(cls,@"setAutoBackupIconForState:","v20@0:8C16")||!GSPhotosHasMethod(cls,@"prepareForReuse","v16@0:8"))return;
  GSPendingIcons=[NSMapTable weakToStrongObjectsMapTable];
  GSInactive=UIApplication.sharedApplication.applicationState!=UIApplicationStateActive;
  SEL state=NSSelectorFromString(@"setAutoBackupIconForState:"),reuse=NSSelectorFromString(@"prepareForReuse");
  Method method=class_getInstanceMethod(cls,state);GSIconState=(void *)method_getImplementation(method);
  class_replaceMethod(cls,state,(IMP)GSSetIconState,method_getTypeEncoding(method));
  method=class_getInstanceMethod(cls,reuse);GSReuseCell=(void *)method_getImplementation(method);
  class_replaceMethod(cls,reuse,(IMP)GSPrepareCell,method_getTypeEncoding(method));
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){GSInactive=YES;}];
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){GSInactive=NO;GSDrainIcons();}];
  installed=YES;
 }
}
