#pragma once
#import <Foundation/Foundation.h>

// Leave room for iOS and other apps. Allow one oversized asset only after the
// queue drains; the free-space guard reserves both its export and queue copy.
static const unsigned long long GSStorageReserve=4ULL<<30;
static const unsigned long long GSStorageQueueLimit=4ULL<<30;
static inline BOOL GSStorageQueueFull(unsigned long long retained,NSUInteger jobs,unsigned long long incoming){
 return retained>0&&(retained>=GSStorageQueueLimit||incoming>GSStorageQueueLimit-retained||jobs>=128);
}
static inline unsigned long long GSStorageFreeBytes(NSURL *directory){
#if GS_TEST_STORAGE
 extern unsigned long long GSFixtureFreeBytes(void);
 return GSFixtureFreeBytes();
#else
 NSDictionary *attributes=[NSFileManager.defaultManager attributesOfFileSystemForPath:directory.path error:nil];
 return [attributes[NSFileSystemFreeSize]unsignedLongLongValue];
#endif
}
