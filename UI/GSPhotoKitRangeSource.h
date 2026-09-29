#import "GSExporter.h"

@interface GSPhotoKitRangeSource : NSObject
@property(nonatomic, readonly) unsigned long long size;
@property(nonatomic, readonly) NSString *sourceVersion;
// nil without an error means a local/unsupported source should use PhotoKit's
// existing resource reader. A failed cloud range request never silently falls back.
+ (instancetype)openAsset:(PHAsset *)asset resource:(PHAssetResource *)resource authorization:(GSImportAuthorizationCheck)authorization error:(NSError **)error;
- (BOOL)readFromOffset:(unsigned long long)offset consume:(BOOL (^)(NSData *, NSError **))consume error:(NSError **)error;
- (void)close;
@end
