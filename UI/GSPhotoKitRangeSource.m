#import "GSPhotoKitRangeSource.h"
#import "GSPhotoKitCache.h"
#import "GSPhotoKitRangePump.h"
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

@interface GSPhotoKitRangeSource ()
@property PHAsset *asset;
@property(nonatomic, readwrite) unsigned long long size;
@property(nonatomic, readwrite) NSString *sourceVersion;
@property(copy) GSImportAuthorizationCheck authorization;
@property(copy) GSImportStorageProgress progress;
@property NSData *prime;
@property BOOL slot;
@end

@implementation GSPhotoKitRangeSource
+ (BOOL)supportsAsset:(PHAsset *)asset resource:(PHAssetResource *)resource {
    if (asset.mediaType != PHAssetMediaTypeVideo || resource.type != PHAssetResourceTypeVideo ||
        [GSRangeProperty(resource, @"locallyAvailable") boolValue]) return NO;
    if (@available(iOS 27.0, *)) {} else { return NO; }
    if (!NSClassFromString(@"GSPhotoKitTaskContext")) return NO;
    unsigned long long size = [GSRangeProperty(resource, @"fileSize") unsignedLongLongValue];
    return size >= 32 && size <= (8ULL << 30);
}
+ (instancetype)openAsset:(PHAsset *)asset resource:(PHAssetResource *)resource authorization:(GSImportAuthorizationCheck)authorization progress:(GSImportStorageProgress)progress error:(NSError **)error {
    if (asset.mediaType != PHAssetMediaTypeVideo || resource.type != PHAssetResourceTypeVideo ||
        [GSRangeProperty(resource, @"locallyAvailable") boolValue]) return nil;
    if (@available(iOS 27.0, *)) {} else { return nil; }
    if (!NSClassFromString(@"GSPhotoKitTaskContext")) return nil;
    unsigned long long size = [GSRangeProperty(resource, @"fileSize") unsignedLongLongValue];
    if (size < 32 || size > (8ULL << 30)) {
        if (error) *error = GSRangeError(3, @"This cloud original has no supported range size."); return nil;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ GSRangeSlots = dispatch_semaphore_create(4); });
    while (dispatch_semaphore_wait(GSRangeSlots, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4))) {
        if (authorization && !authorization()) { if (error) *error = GSRangeError(2, @"Original streaming was interrupted."); return nil; }
    }
    GSPhotoKitRangeSource *source = [self new]; source.slot = YES;
    source.asset = asset; source.size = size; source.authorization = authorization;
    source.progress = progress;
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
                    GSPhotoKitRangePump *pump = [GSPhotoKitRangePump new];
                    pump.URL = asset.URL;
                    pump.interruption = ^NSError *{ return [self interruption]; };
                    pump.receivedBytes = ^(unsigned long long bytes) {
                        if (self.progress) self.progress(@{@"sourceReadBytesDelta": @(bytes)});
                    };
                    pump.submit = ^(GSPhotoKitRangeRequest *range) {
                        dispatch_async(queue, ^{
                            if (![cache perform:^{
                                @try {
                                    if (![delegate resourceLoader:loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)(id)range])
                                        [range finishLoadingWithError:GSRangeError(8, @"PhotoKit rejected the requested range.")];
                                } @catch (__unused NSException *exception) { [range finishLoadingWithError:GSRangeError(8, @"PhotoKit rejected the requested range.")]; }
                            }]) [range finishLoadingWithError:GSRangeError(7, @"The original cache is closed.")];
                        });
                    };
                    pump.releaseRequest = ^(GSPhotoKitRangeRequest *range, dispatch_block_t released) {
                        dispatch_async(queue, ^{
                            if ([delegate respondsToSelector:@selector(resourceLoader:didCancelLoadingRequest:)])
                                [delegate resourceLoader:loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)(id)range];
                            released();
                        });
                    };
                    success = [pump readOffset:start length:length consume:^BOOL(NSData *bytes, NSError **readError) {
                        NSString *version = [cache sourceVersionForSize:self.size];
                        if (!version || (self.sourceVersion && ![self.sourceVersion isEqual:version])) {
                            if (readError) *readError = GSRangeError(7, @"Original identity or cache ownership changed."); return NO;
                        }
                        self.sourceVersion = version;
                        return consume(bytes, readError);
                    } error:&failure];
                    if (pump.cancellationUnconfirmed) {
                        @synchronized(GSPhotoKitRangeSource.class) { GSRangePoisoned = YES; }
                    }
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
        unsigned long long end = MIN(self.size, ((offset / (60ULL << 20)) + 1) * (60ULL << 20));
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
