#pragma once
#import <Foundation/Foundation.h>

// Leave room for iOS and other apps. Allow one oversized asset only after the
// queue drains; the free-space guard reserves both its export and queue copy.
static const unsigned long long GSStorageReserve=1ULL<<30;
static const unsigned long long GSStorageQueueLimit=1ULL<<30;
static inline BOOL GSStorageQueueFull(unsigned long long retained,NSUInteger jobs,unsigned long long incoming){
 return retained>0&&(retained>=GSStorageQueueLimit||incoming>GSStorageQueueLimit-retained||jobs>=128);
}
static inline unsigned long long GSStorageFreeBytes(NSURL *directory){
#if GS_TEST_STORAGE
 extern unsigned long long GSFixtureFreeBytes(void);
 return GSFixtureFreeBytes();
#else
 // User-requested imports can use capacity the OS makes available by purging
 // expendable system caches. A raw filesystem free count excludes that space.
 NSURL *fresh=[NSURL fileURLWithPath:directory.path];
 NSNumber *available=nil;
 if([fresh getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]&&available.longLongValue>0)return available.unsignedLongLongValue;
 NSDictionary *attributes=[NSFileManager.defaultManager attributesOfFileSystemForPath:directory.path error:nil];
 return [attributes[NSFileSystemFreeSize]unsignedLongLongValue];
#endif
}
