#import <Foundation/Foundation.h>

// A per-reader directory; only tasks carrying its Swift TaskLocal may use it.
@interface GSPhotoKitCache : NSObject
@property(nonatomic, readonly) NSURL *directory;
+ (instancetype)create:(NSError **)error;
- (BOOL)perform:(dispatch_block_t)operation;
- (NSDictionary *)statistics;
- (NSString *)sourceVersionForSize:(unsigned long long)size;
- (BOOL)remove:(NSError **)error;
@end
