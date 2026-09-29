#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <sys/stat.h>

static NSString *Documents(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
static NSDictionary *Failure(NSError *error) {
    return error ? @{@"domain": error.domain, @"code": @(error.code)} : @{};
}
static unsigned long long FreeBytes(void) {
    return [[NSFileManager.defaultManager attributesOfFileSystemForPath:Documents() error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}
static NSDictionary *NetworkBytes(void) {
    struct ifaddrs *interfaces = NULL;
    unsigned long long received = 0, sent = 0;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *p = interfaces; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || !p->ifa_data || strcmp(p->ifa_name, "en0")) continue;
            struct if_data *data = p->ifa_data;
            received += data->ifi_ibytes; sent += data->ifi_obytes;
        }
        freeifaddrs(interfaces);
    }
    return @{@"deviceWiFiReceived": @(received), @"deviceWiFiSent": @(sent)};
}
static id ReadProperty(id object, NSString *name) {
    @try { return [object valueForKey:name]; } @catch (__unused NSException *exception) { return NSNull.null; }
}
static BOOL SetPrivateBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 3 || strcmp(signature.methodReturnType, @encode(void)) ||
        strcmp([signature getArgumentTypeAtIndex:2], @encode(BOOL))) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    return YES;
}
static PHAssetResource *Original(PHAsset *asset) {
    for (PHAssetResource *resource in [PHAssetResource assetResourcesForAsset:asset])
        if (resource.type == PHAssetResourceTypeVideo) return resource;
    return nil;
}
static NSDictionary *Describe(PHAsset *asset, PHAssetResource *resource) {
    return @{@"assetID": asset.localIdentifier, @"duration": @(asset.duration),
             @"width": @(asset.pixelWidth), @"height": @(asset.pixelHeight),
             @"filename": resource.originalFilename ?: @"", @"resourceType": @(resource.type),
             @"expectedBytes": ReadProperty(resource, @"fileSize") ?: NSNull.null,
             @"locallyAvailable": ReadProperty(resource, @"locallyAvailable") ?: NSNull.null};
}
static void SaveJSON(NSString *name, id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:[Documents() stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}

@interface ProbeRun : NSObject <NSURLSessionDataDelegate> {
    CC_SHA256_CTX _hash;
}
@property NSMutableDictionary *values;
@property NSMutableArray *samples;
@property NSDate *start;
@property NSDate *deadline;
@property unsigned long long count;
@property unsigned long long cap;
@property unsigned long long minimumFree;
@property double progress;
@property BOOL stopped;
@property BOOL finalized;
@property NSString *stopReason;
@property dispatch_semaphore_t networkDone;
- (instancetype)initWithCommand:(NSDictionary *)command;
- (BOOL)consume:(NSData *)data;
- (void)sample;
- (NSDictionary *)snapshot;
- (BOOL)shouldStop;
- (void)finishHash:(BOOL)complete;
@end

@implementation ProbeRun
- (instancetype)initWithCommand:(NSDictionary *)command {
    if ((self = [super init])) {
        _values = [@{@"id": command[@"id"], @"mode": command[@"mode"], @"status": @"running",
                     @"systemVersion": UIDevice.currentDevice.systemVersion,
                     @"networkCountersScope": @"device-wide en0; not per-resource"} mutableCopy];
        _samples = [NSMutableArray array]; _start = NSDate.date;
        _deadline = [_start dateByAddingTimeInterval:MAX(10, MIN(600, [command[@"timeout"] doubleValue] ?: 180))];
        _cap = [command[@"maxBytes"] unsignedLongLongValue] ?: (2ULL << 30);
        _cap = MIN(_cap, 8ULL << 30);
        _minimumFree = FreeBytes(); _values[@"initialFreeBytes"] = @(_minimumFree);
        _values[@"initialNetwork"] = NetworkBytes(); CC_SHA256_Init(&_hash);
    }
    return self;
}
- (BOOL)shouldStop {
    @synchronized(self) {
        if (!_stopped && [_deadline timeIntervalSinceNow] <= 0) { _stopped = YES; _stopReason = @"timeout"; }
        if (!_stopped && FreeBytes() < (1ULL << 30)) { _stopped = YES; _stopReason = @"free_space_floor"; }
        return _stopped;
    }
}
- (BOOL)consume:(NSData *)data {
    @synchronized(self) {
        if ([self shouldStop] || _finalized) return NO;
        if (!_count && data.length) {
            _values[@"firstDataSeconds"] = @(-[_start timeIntervalSinceNow]);
            _values[@"progressAtFirstData"] = @(_progress);
            _values[@"networkAtFirstData"] = NetworkBytes();
            _values[@"freeBytesAtFirstData"] = @(FreeBytes());
        }
        NSUInteger length = (NSUInteger)MIN((unsigned long long)data.length, _cap - _count);
        CC_SHA256_Update(&_hash, data.bytes, (CC_LONG)length); _count += length;
        if (length < data.length || _count >= _cap) { _stopped = YES; _stopReason = @"byte_cap"; return NO; }
        return YES;
    }
}
- (void)sample {
    @synchronized(self) {
        unsigned long long free = FreeBytes(); _minimumFree = MIN(_minimumFree, free);
        NSMutableDictionary *sample = [NetworkBytes() mutableCopy];
        [sample addEntriesFromDictionary:@{@"seconds": @(-[_start timeIntervalSinceNow]), @"freeBytes": @(free),
                                           @"bytes": @(_count), @"progress": @(_progress)}];
        if (_samples.count < 650) [_samples addObject:sample];
    }
}
- (NSDictionary *)snapshot {
    @synchronized(self) {
        NSMutableDictionary *result = [_values mutableCopy];
        [result addEntriesFromDictionary:@{@"bytes": @(_count), @"seconds": @(-[_start timeIntervalSinceNow]),
            @"minimumFreeBytes": @(_minimumFree), @"progress": @(_progress), @"samples": [_samples copy]}];
        if (_stopReason) result[@"stopReason"] = _stopReason;
        return result;
    }
}
- (void)finishHash:(BOOL)complete {
    @synchronized(self) {
        if (_finalized) return;
        _finalized = YES;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &_hash);
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
        _values[complete && !_stopped ? @"completeSHA256" : @"prefixSHA256"] = hex;
        _values[@"readComplete"] = @(complete && !_stopped);
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    @synchronized(self) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        self.values[@"httpStatus"] = @([http isKindOfClass:NSHTTPURLResponse.class] ? http.statusCode : 0);
        self.values[@"httpExpectedBytes"] = @(response.expectedContentLength);
        self.values[@"httpMIME"] = response.MIMEType ?: @"";
        BOOL raw = [http isKindOfClass:NSHTTPURLResponse.class] && http.statusCode == 200;
        if (!raw) { self.stopped = YES; self.stopReason = @"non_raw_http_response"; }
        completion(raw ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (![self consume:data]) [task cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized(self) { self.values[@"httpError"] = Failure(error); }
    [self finishHash:!error]; dispatch_semaphore_signal(self.networkDone);
}
@end

static void WaitForRequest(ProbeRun *run, dispatch_semaphore_t done, void (^cancel)(void)) {
    BOOL cancelled = NO; NSDate *cancelledAt = nil;
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
        [run sample];
        if ([run shouldStop] && !cancelled) { cancelled = YES; cancelledAt = NSDate.date; cancel(); }
        if (cancelled && -[cancelledAt timeIntervalSinceNow] > 15) {
            @synchronized(run) { run.values[@"cancelCompletionMissing"] = @YES; } break;
        }
    }
}

// Diagnostic-only duck-typed requests. The inspected CloudAssets delegate uses
// these Objective-C selectors to deliver decrypted raw ranges to AVFoundation.
// No framework object internals, credentials, or stream-handle ivars are read.
@interface ProbeRangeData : NSObject
@property long long requestedOffset;
@property NSInteger requestedLength;
@property long long currentOffset;
@property ProbeRun *run;
- (BOOL)requestsAllDataToEndOfResource;
- (void)respondWithData:(NSData *)data;
@end
@implementation ProbeRangeData
- (BOOL)requestsAllDataToEndOfResource { return NO; }
- (void)respondWithData:(NSData *)data {
    @synchronized(self) {
        if (self.currentOffset < self.requestedOffset || data.length > (NSUInteger)(self.requestedOffset + self.requestedLength - self.currentOffset)) {
            @synchronized(self.run) { self.run.stopped = YES; self.run.stopReason = @"range_overrun"; } return;
        }
        [self.run consume:data]; self.currentOffset += data.length;
    }
}
@end
@interface ProbeRangeRequest : NSObject
@property NSURLRequest *request;
@property ProbeRangeData *dataRequest;
@property NSURLResponse *response;
@property NSURLRequest *redirect;
@property dispatch_semaphore_t done;
@property NSError *error;
@property BOOL finished;
@property BOOL cancelled;
- (id)contentInformationRequest;
- (BOOL)isFinished;
- (BOOL)isCancelled;
- (void)finishLoading;
- (void)finishLoadingWithError:(NSError *)error;
@end
@implementation ProbeRangeRequest
- (id)contentInformationRequest { return nil; }
- (BOOL)isFinished { return self.finished; }
- (BOOL)isCancelled { return self.cancelled; }
- (void)finishLoading { [self finishLoadingWithError:nil]; }
- (void)finishLoadingWithError:(NSError *)error {
    @synchronized(self) { if (self.finished) return; self.error = error; self.finished = YES; dispatch_semaphore_signal(self.done); }
}
@end

static void ReadLoaderRanges(ProbeRun *run, AVURLAsset *asset, NSDictionary *command) {
    AVAssetResourceLoader *loader = asset.resourceLoader;
    id<AVAssetResourceLoaderDelegate> delegate = loader.delegate;
    NSString *name = delegate ? NSStringFromClass([delegate class]) : @"nil";
    @synchronized(run) { run.values[@"loaderDelegateClass"] = name; }
    if ((! [name hasPrefix:@"CloudAssets."] && ![name hasPrefix:@"CloudAsset."]) || ![delegate respondsToSelector:@selector(resourceLoader:shouldWaitForLoadingOfRequestedResource:)]) {
        @synchronized(run) { run.values[@"rawReadUnavailable"] = @"unsupported_loader_delegate"; } return;
    }
    unsigned long long expected;
    @synchronized(run) { expected = [run.values[@"sourceBefore"][@"expectedBytes"] unsignedLongLongValue]; }
    unsigned long long start = [command[@"startOffset"] unsignedLongLongValue], offset = start;
    if (!expected || expected > (8ULL << 30) || start >= expected) return;
    @synchronized(run) { run.values[@"rangeStart"] = @(start); run.values[@"rangeChunkBytes"] = @(1 << 20); }
    dispatch_queue_t queue = loader.delegateQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    NSUInteger ranges = 0;
    while (offset < expected && ![run shouldStop]) {
        ProbeRangeRequest *request = [ProbeRangeRequest new]; request.done = dispatch_semaphore_create(0);
        request.request = [NSURLRequest requestWithURL:asset.URL];
        ProbeRangeData *data = [ProbeRangeData new]; data.run = run;
        data.requestedOffset = offset; data.currentOffset = offset;
        data.requestedLength = (NSInteger)MIN(1ULL << 20, expected - offset); request.dataRequest = data;
        dispatch_async(queue, ^{
            @try {
                BOOL accepted = [delegate resourceLoader:loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)(id)request];
                if (!accepted) [request finishLoadingWithError:[NSError errorWithDomain:@"Probe.LoaderRejected" code:1 userInfo:nil]];
            } @catch (__unused NSException *exception) {
                [request finishLoadingWithError:[NSError errorWithDomain:@"Probe.LoaderException" code:1 userInfo:nil]];
            }
        });
        WaitForRequest(run, request.done, ^{
            request.cancelled = YES;
            dispatch_async(queue, ^{
                if ([delegate respondsToSelector:@selector(resourceLoader:didCancelLoadingRequest:)])
                    [delegate resourceLoader:loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)(id)request];
                [request finishLoadingWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
            });
        });
        if (request.error || data.currentOffset != (long long)offset + data.requestedLength) {
            @synchronized(run) { run.values[@"rangeError"] = Failure(request.error); run.values[@"rangeShortRead"] = @(data.currentOffset != (long long)offset + data.requestedLength); } break;
        }
        offset += data.requestedLength; ranges++;
        @synchronized(run) { run.values[@"completedRanges"] = @(ranges); run.values[@"nextRangeOffset"] = @(offset); }
    }
    [run finishHash:start == 0 && offset == expected];
}

static void ReadResource(ProbeRun *run, PHAssetResource *resource, BOOL transient, BOOL network) {
    PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new]; options.networkAccessAllowed = network;
    if (transient && !SetPrivateBool(options, @"setDownloadIsTransient:", YES)) {
        @synchronized(run) { run.values[@"unsupported"] = @"setDownloadIsTransient: ABI"; } return;
    }
    @synchronized(run) { run.values[@"downloadIsTransient"] = ReadProperty(options, @"downloadIsTransient") ?: NSNull.null; }
    options.progressHandler = ^(double value) { @synchronized(run) { run.progress = value; } };
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    PHAssetResourceManager *manager = PHAssetResourceManager.defaultManager;
    PHAssetResourceDataRequestID request = [manager requestDataForAssetResource:resource options:options
        dataReceivedHandler:^(NSData *data) { [run consume:data]; }
        completionHandler:^(NSError *error) {
            @synchronized(run) { run.values[@"resourceError"] = Failure(error); }
            [run finishHash:!error]; dispatch_semaphore_signal(done);
        }];
    WaitForRequest(run, done, ^{ [manager cancelDataRequest:request]; });
}

static void ReadAVAsset(ProbeRun *run, AVAsset *asset) {
    @synchronized(run) { run.values[@"avAssetClass"] = NSStringFromClass(asset.class); }
    if (![asset isKindOfClass:AVURLAsset.class]) {
        @synchronized(run) { run.values[@"rawReadUnavailable"] = @"not_AVURLAsset"; } return;
    }
    NSURL *url = [(AVURLAsset *)asset URL];
    @synchronized(run) { run.values[@"urlScheme"] = url.scheme ?: @""; }
    // Never persist a media URL: it can include authorization credentials.
    if (url.isFileURL) {
        struct stat st;
        if (!stat(url.fileSystemRepresentation, &st)) {
            @synchronized(run) {
            run.values[@"fileBytesAtAVDelivery"] = @(st.st_size);
            run.values[@"fileAllocatedAtAVDelivery"] = @((unsigned long long)st.st_blocks * 512);
            }
        }
        NSError *error = nil; NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:&error];
        BOOL eof = NO;
        while (handle && ![run shouldStop]) { @autoreleasepool {
            NSData *chunk = [handle readDataUpToLength:1 << 20 error:&error];
            if (!chunk || !chunk.length) { eof = chunk != nil; break; }
            if (![run consume:chunk]) break;
        }}
        [handle closeAndReturnError:nil]; @synchronized(run) { run.values[@"fileError"] = Failure(error); }
        [run finishHash:eof && !error];
    } else if ([url.scheme isEqualToString:@"https"]) {
        run.networkDone = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.URLCache = nil; configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForResource = MAX(1, [run.deadline timeIntervalSinceNow]);
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:run delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithURL:url]; [task resume];
        WaitForRequest(run, run.networkDone, ^{ [task cancel]; }); [session invalidateAndCancel];
    } else {
        @synchronized(run) { run.values[@"rawReadUnavailable"] = @"non_HTTP_non_file_URL"; }
    }
}

static void ReadVideo(ProbeRun *run, PHAsset *asset, NSDictionary *command) {
    PHVideoRequestOptions *options = [PHVideoRequestOptions new];
    options.version = PHVideoRequestOptionsVersionOriginal; options.networkAccessAllowed = YES;
    options.deliveryMode = [command[@"delivery"] isEqual:@"automatic"] ? PHVideoRequestOptionsDeliveryModeAutomatic : PHVideoRequestOptionsDeliveryModeHighQualityFormat;
    BOOL streaming = ![command[@"mode"] isEqual:@"video-baseline"];
    if (streaming && !SetPrivateBool(options, @"setStreamingAllowed:", YES)) {
        @synchronized(run) { run.values[@"unsupported"] = @"setStreamingAllowed: ABI"; } return;
    }
    @synchronized(run) {
    run.values[@"streamingAllowed"] = ReadProperty(options, @"streamingAllowed") ?: NSNull.null;
    run.values[@"streamingVideoIntent"] = ReadProperty(options, @"streamingVideoIntent") ?: NSNull.null;
    run.values[@"deliveryMode"] = @(options.deliveryMode);
    }
    options.progressHandler = ^(double value, NSError *error, BOOL *stop, NSDictionary *info) {
        @synchronized(run) { run.progress = value; } if ([run shouldStop]) *stop = YES;
    };
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block AVAsset *received = nil;
    __block AVPlayerItem *receivedItem = nil;
    void (^complete)(AVAsset *, NSDictionary *) = ^(AVAsset *av, NSDictionary *info) {
        @synchronized(run) {
            received = av; run.values[@"avDeliverySeconds"] = @(-[run.start timeIntervalSinceNow]);
            run.values[@"progressAtAVDelivery"] = @(run.progress);
            run.values[@"videoError"] = Failure(info[PHImageErrorKey]);
            run.values[@"videoCancelled"] = info[PHImageCancelledKey] ?: @NO;
        }
        dispatch_semaphore_signal(done);
    };
    PHImageManager *manager = PHImageManager.defaultManager; PHImageRequestID request;
    if ([command[@"mode"] isEqual:@"player-streaming"] || [command[@"mode"] isEqual:@"range-loader-streaming"]) {
        request = [manager requestPlayerItemForVideo:asset options:options resultHandler:^(AVPlayerItem *item, NSDictionary *info) {
            @synchronized(run) { receivedItem = item; } complete(item.asset, info);
        }];
    } else {
        request = [manager requestAVAssetForVideo:asset options:options resultHandler:^(AVAsset *av, AVAudioMix *mix, NSDictionary *info) { complete(av, info); }];
    }
    WaitForRequest(run, done, ^{ [manager cancelImageRequest:request]; });
    __attribute__((objc_precise_lifetime)) AVPlayerItem *keepAlive;
    @synchronized(run) { keepAlive = receivedItem; }
    (void)keepAlive;
    AVAsset *result; @synchronized(run) { result = received; }
    if (result && ![run shouldStop]) {
        if ([command[@"mode"] isEqual:@"range-loader-streaming"] && [result isKindOfClass:AVURLAsset.class])
            ReadLoaderRanges(run, (AVURLAsset *)result, command);
        else ReadAVAsset(run, result);
    }
}

@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property UITextView *text;
@property NSTimer *timer;
@property BOOL busy;
@property ProbeRun *run;
@property NSString *lastCommand;
@end
@implementation ProbeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    self.text = [[UITextView alloc] initWithFrame:self.window.bounds];
    self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.text.textContainerInset = UIEdgeInsetsMake(60, 24, 24, 24);
    self.text.editable = NO; self.text.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.text.text = @"PhotoKit Probe\nWaiting for photo library access.";
    controller.view = self.text; self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    application.idleTimerDisabled = YES;
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
        SaveJSON(@"status.json", @{@"authorization": @(status), @"systemVersion": UIDevice.currentDevice.systemVersion});
    }];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    return YES;
}
- (void)tick {
    if (self.run) {
        [self.run sample]; NSDictionary *snapshot = self.run.snapshot;
        SaveJSON(@"current.json", snapshot);
        self.text.text = [NSString stringWithFormat:@"PhotoKit Probe\n%@\n%@\nBytes: %@\nSeconds: %.1f\nFree: %.2f GiB",
            snapshot[@"mode"], snapshot[@"status"], snapshot[@"bytes"], [snapshot[@"seconds"] doubleValue], FreeBytes() / (double)(1ULL << 30)];
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:[Documents() stringByAppendingPathComponent:@"cancel.request"]]) {
        @synchronized(self.run) { self.run.stopped = YES; self.run.stopReason = @"user_cancel"; }
        [NSFileManager.defaultManager removeItemAtPath:[Documents() stringByAppendingPathComponent:@"cancel.request"] error:nil];
    }
    if (self.busy) return;
    NSData *data = [NSData dataWithContentsOfFile:[Documents() stringByAppendingPathComponent:@"command.json"]];
    NSDictionary *command = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![command isKindOfClass:NSDictionary.class] || ![command[@"id"] isKindOfClass:NSString.class] || [command[@"id"] isEqual:self.lastCommand]) return;
    NSString *identifier = command[@"id"];
    if (identifier.length > 80 || [identifier rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"].invertedSet].location != NSNotFound) return;
    self.lastCommand = identifier; self.busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { [self execute:command]; }
        dispatch_async(dispatch_get_main_queue(), ^{ self.busy = [self.run.snapshot[@"cancelCompletionMissing"] boolValue]; });
    });
}
- (void)execute:(NSDictionary *)command {
    NSString *mode = command[@"mode"];
    if ([mode isEqual:@"inventory"]) {
        PHFetchOptions *options = [PHFetchOptions new]; options.fetchLimit = 1000;
        options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
        NSMutableArray *items = [NSMutableArray array];
        for (PHAsset *asset in [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeVideo options:options]) {
            PHAssetResource *resource = Original(asset); if (resource) [items addObject:Describe(asset, resource)];
        }
        SaveJSON(@"inventory.json", @{@"id": command[@"id"], @"items": items, @"freeBytes": @(FreeBytes())}); return;
    }
    ProbeRun *run = [[ProbeRun alloc] initWithCommand:command];
    dispatch_sync(dispatch_get_main_queue(), ^{ self.run = run; });
    @try {
        PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[command[@"assetID"] ?: @""] options:nil].firstObject;
        PHAssetResource *resource = asset ? Original(asset) : nil;
        if (!resource) { @synchronized(run) { run.values[@"error"] = @"original_not_found"; } }
        else {
            @synchronized(run) { run.values[@"sourceBefore"] = Describe(asset, resource); }
            if ([mode isEqual:@"resource-transient"] || [mode isEqual:@"resource-baseline"] || [mode isEqual:@"resource-local"]) {
                ReadResource(run, resource, [mode isEqual:@"resource-transient"], ![mode isEqual:@"resource-local"]);
            } else if ([mode isEqual:@"video-streaming"] || [mode isEqual:@"video-baseline"] || [mode isEqual:@"player-streaming"] || [mode isEqual:@"range-loader-streaming"]) {
                ReadVideo(run, asset, command);
            } else { @synchronized(run) { run.values[@"error"] = @"unknown_mode"; } }
            @synchronized(run) { run.values[@"sourceAfter"] = Describe(asset, Original(asset)); }
        }
    } @catch (NSException *exception) { @synchronized(run) { run.values[@"exception"] = exception.name; } }
    [run sample];
    @synchronized(run) { run.values[@"status"] = @"finished"; }
    SaveJSON([NSString stringWithFormat:@"result-%@.json", command[@"id"]], run.snapshot);
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class)); }
}
