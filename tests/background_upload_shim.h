#import <Foundation/Foundation.h>
typedef NSUInteger UIBackgroundTaskIdentifier;
static const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid=NSUIntegerMax;
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;
@end
