#import "GSPhotoKitRangeSource.h"
#import "GSPhotoKitCache.h"
#import "GSImportStorage.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static dispatch_semaphore_t GSRangeSlots;
static BOOL GSRangePoisoned;
static NSError *GSRangeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Gunshot.PhotoKitRange" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
static id GSRangeProperty(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *exception) { return nil; }
}

@interface GSRangeData : NSObject
@property long long requestedOffset;
@property NSInteger requestedLength;
@property long long currentOffset;
@property(copy) BOOL (^consume)(NSData *, NSError **);
@property NSError *failure;
- (BOOL)requestsAllDataToEndOfResource;
- (void)respondWithData:(NSData *)data;
@end
@implementation GSRangeData
- (BOOL)requestsAllDataToEndOfResource { return NO; }
- (void)respondWithData:(NSData *)data {
    @synchronized(self) {
        if (self.failure) return;
        if (self.currentOffset < self.requestedOffset || data.length > (NSUInteger)(self.requestedOffset + self.requestedLength - self.currentOffset)) {
            self.failure = GSRangeError(1, @"PhotoKit returned an invalid byte range."); return;
        }
        NSError *error = nil;
        if (!self.consume(data, &error)) { self.failure = error ?: GSRangeError(2, @"Original streaming was interrupted."); return; }
        self.currentOffset += data.length;
    }
}
@end

@interface GSRangeRequest : NSObject
@property NSURLRequest *request;
@property GSRangeData *dataRequest;
@property NSURLResponse *response;
@property NSURLRequest *redirect;
@property dispatch_semaphore_t done;
@property NSError *failure;
@property BOOL finished;
@property BOOL cancelled;
- (id)contentInformationRequest;
- (BOOL)isFinished;
- (BOOL)isCancelled;
- (void)finishLoading;
- (void)finishLoadingWithError:(NSError *)error;
@end
@implementation GSRangeRequest
- (id)contentInformationRequest { return nil; }
- (BOOL)isFinished { return self.finished; }
- (BOOL)isCancelled { return self.cancelled; }
- (void)finishLoading { [self finishLoadingWithError:nil]; }
- (void)finishLoadingWithError:(NSError *)error {
    @synchronized(self) { if (self.finished) return; self.failure = error; self.finished = YES; dispatch_semaphore_signal(self.done); }
}
@end

@interface GSPhotoKitRangeSource ()
@property PHAsset *asset;
@property(nonatomic, readwrite) unsigned long long size;
@property(nonatomic, readwrite) NSString *sourceVersion;
@property(copy) GSImportAuthorizationCheck authorization;
@property NSData *prime;
@property BOOL slot;
@end

@implementation GSPhotoKitRangeSource
+ (instancetype)openAsset:(PHAsset *)asset resource:(PHAssetResource *)resource authorization:(GSImportAuthorizationCheck)authorization error:(NSError **)error {
    if (asset.mediaType != PHAssetMediaTypeVideo || resource.type != PHAssetResourceTypeVideo ||
        [GSRangeProperty(resource, @"locallyAvailable") boolValue]) return nil;
    if (@available(iOS 27.0, *)) {} else { return nil; }
    if (!NSClassFromString(@"GSPhotoKitTaskContext")) return nil;
    unsigned long long size = [GSRangeProperty(resource, @"fileSize") unsignedLongLongValue];
    if (size < 32 || size > (8ULL << 30)) {
        if (error) *error = GSRangeError(3, @"This cloud original has no supported range size."); return nil;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ GSRangeSlots = dispatch_semaphore_create(2); });
    while (dispatch_semaphore_wait(GSRangeSlots, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4))) {
        if (authorization && !authorization()) { if (error) *error = GSRangeError(2, @"Original streaming was interrupted."); return nil; }
    }
    GSPhotoKitRangeSource *source = [self new]; source.slot = YES;
    source.asset = asset; source.size = size; source.authorization = authorization;
    NSMutableData *prime = [NSMutableData data];
    if (![source readWindow:0 length:MIN(1ULL << 20, size) consume:^BOOL(NSData *data, NSError **failure) {
        [prime appendData:data]; return YES;
    } error:error]) { [source close]; return nil; }
    source.prime = prime;
    return source;
}
- (NSError *)interruption {
    @synchronized(GSPhotoKitRangeSource.class) {
        if (GSRangePoisoned) return GSRangeError(4, @"PhotoKit did not finish cancellation. Reopen the app before retrying.");
    }
    if (!self.slot || (self.authorization && !self.authorization())) return GSRangeError(2, @"Original streaming was interrupted.");
    if (GSStorageFreeBytes([NSURL fileURLWithPath:NSHomeDirectory()]) < GSStorageReserve + (96ULL << 20))
        return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:nil];
    return nil;
}
- (BOOL)wait:(dispatch_semaphore_t)done failure:(NSError **)error cancel:(dispatch_block_t)cancel {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180];
    NSDate *cancelled = nil;
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4))) {
        NSError *failure = [self interruption];
        if (!failure && deadline.timeIntervalSinceNow <= 0) failure = GSRangeError(5, @"Timed out waiting for original data.");
        if (failure && !cancelled) { if (error) *error = failure; cancelled = NSDate.date; cancel(); }
        if (cancelled && -cancelled.timeIntervalSinceNow >= 15) {
            @synchronized(GSPhotoKitRangeSource.class) { GSRangePoisoned = YES; }
            return NO;
        }
    }
    return cancelled == nil;
}
- (BOOL)readWindow:(unsigned long long)start length:(unsigned long long)length consume:(BOOL (^)(NSData *, NSError **))consume error:(NSError **)error {
    NSError *failure = [self interruption];
    if (failure) { if (error) *error = failure; return NO; }
    GSPhotoKitCache *cache = [GSPhotoKitCache create:&failure];
    if (!cache) { if (error) *error = failure; return NO; }
    __block BOOL success = NO;
    @autoreleasepool {
        PHVideoRequestOptions *options = [PHVideoRequestOptions new];
        options.version = PHVideoRequestOptionsVersionOriginal; options.networkAccessAllowed = YES;
        options.deliveryMode = PHVideoRequestOptionsDeliveryModeHighQualityFormat;
        SEL streaming = NSSelectorFromString(@"setStreamingAllowed:");
        NSMethodSignature *signature = [options methodSignatureForSelector:streaming];
        if (signature.numberOfArguments != 3 || strcmp(signature.methodReturnType, @encode(void)) || strcmp([signature getArgumentTypeAtIndex:2], @encode(BOOL))) {
            failure = GSRangeError(6, @"The PhotoKit streaming interface is unavailable.");
        } else {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(options, streaming, YES);
            PHImageManager *manager = [PHImageManager new];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block AVPlayerItem *item = nil; __block NSError *requestError = nil;
            PHImageRequestID request = [manager requestPlayerItemForVideo:self.asset options:options resultHandler:^(AVPlayerItem *value, NSDictionary *info) {
                item = value; requestError = info[PHImageErrorKey]; dispatch_semaphore_signal(done);
            }];
            BOOL ready = [self wait:done failure:&failure cancel:^{ [manager cancelImageRequest:request]; }];
            if (ready && !requestError && [item.asset isKindOfClass:AVURLAsset.class]) {
                AVURLAsset *asset = (AVURLAsset *)item.asset;
                AVAssetResourceLoader *loader = asset.resourceLoader;
                id<AVAssetResourceLoaderDelegate> delegate = loader.delegate;
                NSString *name = NSStringFromClass([delegate class]);
                if (([name isEqual:@"CloudAsset.LoadingRequestHandler"] || [name isEqual:@"CloudAssets.LoadingRequestHandler"]) &&
                    [delegate respondsToSelector:@selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:)]) {
                    dispatch_queue_t queue = loader.delegateQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
                    unsigned long long offset = start, end = start + length;
                    while (offset < end && !(failure = [self interruption])) { @autoreleasepool {
                        GSRangeRequest *range = [GSRangeRequest new]; range.done = dispatch_semaphore_create(0);
                        range.request = [NSURLRequest requestWithURL:asset.URL];
                        GSRangeData *data = [GSRangeData new]; range.dataRequest = data;
                        data.requestedOffset = offset; data.currentOffset = offset;
                        data.requestedLength = (NSInteger)MIN(1ULL << 20, end - offset);
                        data.consume = ^BOOL(NSData *bytes, NSError **readError) {
                            NSString *version = [cache sourceVersionForSize:self.size];
                            if (!version || (self.sourceVersion && ![self.sourceVersion isEqual:version])) {
                                if (readError) *readError = GSRangeError(7, @"Original identity or cache ownership changed."); return NO;
                            }
                            self.sourceVersion = version;
                            return consume(bytes, readError);
                        };
                        dispatch_async(queue, ^{
                            if (![cache perform:^{
                                @try {
                                    if (![delegate resourceLoader:loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)(id)range])
                                        [range finishLoadingWithError:GSRangeError(8, @"PhotoKit rejected the requested range.")];
                                } @catch (__unused NSException *exception) { [range finishLoadingWithError:GSRangeError(8, @"PhotoKit rejected the requested range.")]; }
                            }]) [range finishLoadingWithError:GSRangeError(7, @"The original cache is closed.")];
                        });
                        BOOL finished = [self wait:range.done failure:&failure cancel:^{
                            range.cancelled = YES;
                            dispatch_async(queue, ^{
                                if ([delegate respondsToSelector:@selector(resourceLoader:didCancelLoadingRequest:)])
                                    [delegate resourceLoader:loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)(id)range];
                            });
                        }];
                        if (finished) {
                            dispatch_sync(queue, ^{
                                if ([delegate respondsToSelector:@selector(resourceLoader:didCancelLoadingRequest:)])
                                    [delegate resourceLoader:loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)(id)range];
                            });
                        }
                        if (!finished || range.failure || data.failure || data.currentOffset != (long long)offset + data.requestedLength) {
                            failure = failure ?: data.failure ?: range.failure ?: GSRangeError(9, @"PhotoKit returned an incomplete range."); break;
                        }
                        offset += data.requestedLength;
                    }}
                    success = offset == end && !failure;
                } else failure = GSRangeError(6, @"The original does not provide the expected streaming reader.");
                [asset cancelLoading];
            } else failure = failure ?: requestError ?: GSRangeError(6, @"PhotoKit did not provide an original streaming reader.");
            [manager cancelImageRequest:request]; item = nil;
        }
    }
    NSError *cleanup = nil;
    if (![cache remove:&cleanup]) { success = NO; failure = failure ?: cleanup; }
    if (error) *error = failure;
    return success;
}
- (BOOL)readFromOffset:(unsigned long long)offset consume:(BOOL (^)(NSData *, NSError **))consume error:(NSError **)error {
    if (offset > self.size) { if (error) *error = GSRangeError(1, @"The original resume offset is invalid."); return NO; }
    if (offset == 0 && self.prime) {
        if (!consume(self.prime, error)) return NO;
        offset = self.prime.length;
    }
    self.prime = nil;
    while (offset < self.size) {
        unsigned long long end = MIN(self.size, ((offset / (20ULL << 20)) + 1) * (20ULL << 20));
        if (![self readWindow:offset length:end - offset consume:consume error:error]) return NO;
        offset = end;
    }
    return YES;
}
- (void)close {
    self.prime = nil;
    if (self.slot) { self.slot = NO; dispatch_semaphore_signal(GSRangeSlots); }
}
- (void)dealloc { [self close]; }
@end
