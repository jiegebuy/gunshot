#import <Foundation/Foundation.h>
#include <assert.h>
static NSString *const UIApplicationWillResignActiveNotification=@"UIApplicationWillResignActiveNotification";
#import "../Jailed/SnapshotGuard.m"
@implementation UIApplication
+ (instancetype)sharedApplication{static id app;static dispatch_once_t once;dispatch_once(&once,^{app=[self new];});return app;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler{return UIBackgroundTaskInvalid;}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler{return UIBackgroundTaskInvalid;}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier{}
@end
@interface PHSMediaItemCell : NSObject
@property NSUInteger calls,reuses;
@property unsigned char state;
- (void)setAutoBackupIconForState:(unsigned char)state;
- (void)prepareForReuse;
@end
@implementation PHSMediaItemCell
- (void)setAutoBackupIconForState:(unsigned char)state{self.calls++;self.state=state;}
- (void)prepareForReuse{self.reuses++;}
@end
static id Info(id self,SEL cmd,NSString *key){return [key isEqual:@"CFBundleExecutable"]?@"GooglePhotos":@"7.92.0";}
static void Drain(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:0.1];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];}
int main(void){@autoreleasepool{
 method_setImplementation(class_getInstanceMethod(NSBundle.class,@selector(objectForInfoDictionaryKey:)),(IMP)Info);
 UIApplication *app=UIApplication.sharedApplication;app.applicationState=UIApplicationStateActive;
 GSInstallSnapshotGuard();PHSMediaItemCell *cell=[PHSMediaItemCell new];
 [cell setAutoBackupIconForState:1];assert(cell.calls==1&&cell.state==1);
 [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
 [cell setAutoBackupIconForState:2];[cell setAutoBackupIconForState:3];assert(cell.calls==1);
 app.applicationState=UIApplicationStateBackground;Drain();assert(cell.calls==1);
 app.applicationState=UIApplicationStateActive;[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];Drain();
 assert(cell.calls==2&&cell.state==3&&GSPendingIcons.count==0);
 GSInactive=YES;[cell setAutoBackupIconForState:4];[cell prepareForReuse];assert(cell.reuses==1);
 GSInactive=NO;GSDrainIcons();Drain();assert(cell.calls==2);
 GSInactive=YES;
 @autoreleasepool{PHSMediaItemCell *released=[PHSMediaItemCell new];[released setAutoBackupIconForState:5];}
 GSInactive=NO;GSDrainIcons();Drain();
 NSLog(@"PASS foreground passthrough, inactive deferral, latest state, reuse and weak lifetime");
 return 0;
}}
