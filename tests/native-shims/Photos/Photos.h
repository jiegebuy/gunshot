#import <Foundation/Foundation.h>
@class PHFetchResult;
typedef int32_t PHAssetResourceDataRequestID;
typedef NS_ENUM(NSInteger, PHAssetMediaType) { PHAssetMediaTypeUnknown=0, PHAssetMediaTypeImage=1, PHAssetMediaTypeVideo=2 };
typedef NS_OPTIONS(NSUInteger, PHAssetMediaSubtype) { PHAssetMediaSubtypeNone=0, PHAssetMediaSubtypePhotoLive=1<<3 };
typedef NS_ENUM(NSInteger, PHAssetResourceType) { PHAssetResourceTypePhoto=1, PHAssetResourceTypeVideo=2, PHAssetResourceTypePairedVideo=9 };
@interface PHAsset : NSObject
@property(nonatomic,copy) NSString *localIdentifier;
@property(nonatomic,strong) NSDate *creationDate;
@property(nonatomic) PHAssetMediaType mediaType;
@property(nonatomic) PHAssetMediaSubtype mediaSubtypes;
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)identifiers options:(id)options;
@end
@interface PHAssetResource : NSObject
@property(nonatomic) PHAssetResourceType type;
@property(nonatomic,copy) NSString *originalFilename;
+ (NSArray<PHAssetResource *> *)assetResourcesForAsset:(PHAsset *)asset;
@end
@interface PHAssetResourceRequestOptions : NSObject
@property(nonatomic) BOOL networkAccessAllowed;
@end
@interface PHAssetResourceManager : NSObject
+ (instancetype)defaultManager;
- (PHAssetResourceDataRequestID)requestDataForAssetResource:(PHAssetResource *)resource options:(PHAssetResourceRequestOptions *)options dataReceivedHandler:(void (^)(NSData *))handler completionHandler:(void (^)(NSError *))completion;
- (void)cancelDataRequest:(PHAssetResourceDataRequestID)requestID;
- (void)writeDataForAssetResource:(PHAssetResource *)resource toFile:(NSURL *)url options:(PHAssetResourceRequestOptions *)options completionHandler:(void (^)(NSError *))completion;
@end
@interface PHFetchResult : NSObject
- (void)enumerateObjectsUsingBlock:(void (^)(PHAsset *,NSUInteger,BOOL *))block;
@end
