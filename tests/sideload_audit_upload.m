#import <Foundation/Foundation.h>
#include <assert.h>
@interface FixtureBundle:NSObject
+ (instancetype)mainBundle;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
#define NSBundle FixtureBundle
#import "../Jailed/SideloadAuditUpload.m"
#undef NSBundle
static NSString *Version=@"7.92.0",*Executable=@"GooglePhotos";
static NSUInteger AuditStarts,PhotoStarts,Finishes;
@implementation FixtureBundle
+ (instancetype)mainBundle{return [self new];}
- (id)objectForInfoDictionaryKey:(NSString *)key{return [key isEqual:@"CFBundleExecutable"]?Executable:Version;}
@end
@interface ARIUploader:NSObject
- (void)uploadWithMinimumIntervalSeconds:(NSInteger)seconds;
- (void)finishUpload;
@end
@implementation ARIUploader
- (void)uploadWithMinimumIntervalSeconds:(NSInteger)seconds{AuditStarts++;}
- (void)finishUpload{Finishes++;}
@end
@interface PhotoUploader:NSObject
- (void)uploadWithMinimumIntervalSeconds:(NSInteger)seconds;
@end
@implementation PhotoUploader
- (void)uploadWithMinimumIntervalSeconds:(NSInteger)seconds{PhotoStarts++;}
@end
int main(void){@autoreleasepool{
 ARIUploader *audit=[ARIUploader new];
 Version=@"7.20.2";GSInstallSideloadAuditUploadGuard();[audit uploadWithMinimumIntervalSeconds:1];assert(AuditStarts==1);
 Version=@"7.92.0";Executable=@"Other";GSInstallSideloadAuditUploadGuard();[audit uploadWithMinimumIntervalSeconds:1];assert(AuditStarts==2);
 Executable=@"GooglePhotos";GSInstallSideloadAuditUploadGuard();GSInstallSideloadAuditUploadGuard();
 [audit uploadWithMinimumIntervalSeconds:0];[audit uploadWithMinimumIntervalSeconds:60];assert(AuditStarts==2);
 [[PhotoUploader new]uploadWithMinimumIntervalSeconds:0];[audit finishUpload];assert(PhotoStarts==1&&Finishes==1);
 NSLog(@"PASS audit uploader workaround is host/version scoped and leaves photo uploads and cleanup unchanged");
}}
