#import "SideloadAuditUpload.h"
#import <objc/runtime.h>
#include <string.h>

// Google Photos 7.92.0's audit-record uploader crashes this re-signed iPadOS
// host on entering the background (EXC_GUARD, close of protected descriptor).
// Both its foreground and background timers enter this method. Suppress only
// this optional audit upload, before it opens the audit state file. Do not hook
// close()/NSFileHandle, suppress OS guards, or change photo transfer classes.
static void GSSkipAuditUpload(id object,SEL selector,NSInteger interval) {}
void GSInstallSideloadAuditUploadGuard(void){
 if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"]isEqual:@"GooglePhotos"]||
    ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]isEqual:@"7.92.0"])return;
 Class uploader=NSClassFromString(@"ARIUploader");
 SEL start=NSSelectorFromString(@"uploadWithMinimumIntervalSeconds:");
 Method method=class_getInstanceMethod(uploader,start);
 Method finish=class_getInstanceMethod(uploader,NSSelectorFromString(@"finishUpload"));
 if(!method||!finish||strcmp(method_getTypeEncoding(method),"v24@0:8q16")||strcmp(method_getTypeEncoding(finish),"v16@0:8"))return;
 class_replaceMethod(uploader,start,(IMP)GSSkipAuditUpload,"v24@0:8q16");
}
