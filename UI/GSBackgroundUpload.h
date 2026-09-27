#pragma once
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT void GSBeginBackgroundUpload(NSUInteger count);
// Installs the UIKit background-task guard; call once, as early as possible.
FOUNDATION_EXPORT void GSInstallBackgroundTaskGuard(void);
FOUNDATION_EXPORT NSDictionary *GSBackgroundUploadSnapshot(void);
FOUNDATION_EXPORT NSString *const GSBackgroundUploadChanged;
