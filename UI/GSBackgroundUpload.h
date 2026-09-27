#pragma once
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT void GSBeginBackgroundUpload(NSUInteger count);
FOUNDATION_EXPORT NSDictionary *GSBackgroundUploadSnapshot(void);
FOUNDATION_EXPORT NSString *const GSBackgroundUploadChanged;
