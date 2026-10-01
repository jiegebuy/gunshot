#import "../UI/GSPhotoKitRangePump.h"
#import <limits.h>

static void *LoaderQueueKey = &LoaderQueueKey;
static NSError *FixtureError(void) { return [NSError errorWithDomain:@"Fixture" code:73 userInfo:nil]; }

@interface Loader : NSObject
@property dispatch_queue_t queue;
@property NSMutableArray<GSPhotoKitRangeRequest *> *submitted;
@property NSMutableSet<GSPhotoKitRangeRequest *> *released;
@property NSMutableArray<NSNumber *> *arrivals;
@property NSData *original;
@property NSString *mode;
@property GSPhotoKitRangeRequest *delayed;
@property NSUInteger outstanding;
@property NSUInteger peak;
- (void)submit:(GSPhotoKitRangeRequest *)request;
- (void)release:(GSPhotoKitRangeRequest *)request completion:(dispatch_block_t)completion;
@end
@implementation Loader
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("fixture.loader", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, LoaderQueueKey, LoaderQueueKey, NULL);
        _submitted = [NSMutableArray array]; _released = [NSMutableSet set]; _arrivals = [NSMutableArray array];
        NSMutableData *data = [NSMutableData dataWithLength:173];
        for (NSUInteger i = 0; i < data.length; i++) ((uint8_t *)data.mutableBytes)[i] = (uint8_t)(i * 7);
        _original = data;
    }
    return self;
}
- (void)deliver:(GSPhotoKitRangeRequest *)request {
    if (request.cancelled) return;
    NSUInteger offset = (NSUInteger)request.dataRequest.requestedOffset, length = (NSUInteger)request.dataRequest.requestedLength;
    NSData *bytes = [self.original subdataWithRange:NSMakeRange(offset, length)];
    if ([self.mode isEqual:@"short"] && offset == 0) bytes = [bytes subdataWithRange:NSMakeRange(0, length - 1)];
    [request.dataRequest respondWithData:bytes];
    if ([self.mode isEqual:@"overrun"] && offset == 0) [request.dataRequest respondWithData:[NSData dataWithBytes:"x" length:1]];
    [request finishLoading];
    // Neither a late callback nor a repeated completion may change accepted data.
    [request.dataRequest respondWithData:[NSData dataWithBytes:"z" length:1]];
    [request finishLoadingWithError:FixtureError()];
    @synchronized(self) { [self.arrivals addObject:@(offset)]; }
}
- (void)submit:(GSPhotoKitRangeRequest *)request {
    NSUInteger index;
    @synchronized(self) {
        [self.submitted addObject:request]; index = self.submitted.count - 1;
        self.outstanding++; self.peak = MAX(self.peak, self.outstanding);
        NSCAssert(self.outstanding <= 4, @"unbounded request scheduling");
    }
    if ([self.mode isEqual:@"cancel"] || [self.mode isEqual:@"stuck"] || [self.mode isEqual:@"timeout"]) return;
    if ([self.mode isEqual:@"remote-error"]) {
        if (index == 2) dispatch_async(self.queue, ^{ [request finishLoadingWithError:FixtureError()]; });
        return;
    }
    if ([self.mode isEqual:@"rolling"]) {
        if (index < 3) return;
        if (index == 3) {
            self.delayed = request;
            NSArray *first = [self.submitted copy];
            dispatch_async(self.queue, ^{ [self deliver:first[2]]; [self deliver:first[1]]; [self deliver:first[0]]; });
            return;
        }
        if (index == 4) {
            GSPhotoKitRangeRequest *delayed = self.delayed; self.delayed = nil;
            dispatch_async(self.queue, ^{ [self deliver:delayed]; });
        }
    }
    dispatch_async(self.queue, ^{ [self deliver:request]; });
}
- (void)release:(GSPhotoKitRangeRequest *)request completion:(dispatch_block_t)completion {
    dispatch_async(self.queue, ^{
        @synchronized(self) {
            NSCAssert(![self.released containsObject:request], @"released twice");
            [self.released addObject:request]; self.outstanding--;
        }
        if (request.cancelled && ![self.mode isEqual:@"stuck"]) [request finishLoadingWithError:FixtureError()];
        completion();
    });
}
@end

static NSData *Run(NSString *mode, NSUInteger start, BOOL expectedSuccess, NSUInteger *committed) {
    Loader *loader = [Loader new]; loader.mode = mode;
    GSPhotoKitRangePump *pump = [GSPhotoKitRangePump new];
    pump.URL = [NSURL URLWithString:@"fixture://original"]; pump.chunkBytes = 16;
    pump.requestTimeout = 0.5; pump.cancellationTimeout = 0.15;
    pump.submit = ^(GSPhotoKitRangeRequest *request) { [loader submit:request]; };
    pump.releaseRequest = ^(GSPhotoKitRangeRequest *request, dispatch_block_t done) { [loader release:request completion:done]; };
    pump.interruption = ^NSError *{
        @synchronized(loader) { return [mode isEqual:@"cancel"] && loader.submitted.count == 4 ? FixtureError() : nil; }
    };
    NSMutableData *result = [NSMutableData data];
    __block unsigned long long received = 0;
    pump.receivedBytes = ^(unsigned long long bytes) {
        NSCAssert(!dispatch_get_specific(LoaderQueueKey), @"progress blocked the loader callback queue");
        NSCAssert(bytes > 0, @"waiting reported progress"); received += bytes;
    };
    NSError *error = nil;
    BOOL success = [pump readOffset:start length:loader.original.length - start consume:^BOOL(NSData *data, NSError **failure) {
        NSCAssert(!dispatch_get_specific(LoaderQueueKey), @"consumer blocked the loader callback queue");
        if ([mode isEqual:@"consumer-error"] && result.length >= 16) { *failure = FixtureError(); return NO; }
        [result appendData:data]; return YES;
    } error:&error];
    dispatch_sync(loader.queue, ^{});
    NSCAssert(success == expectedSuccess, @"%@ result: %@", mode, error);
    NSCAssert((error == nil) == expectedSuccess, @"%@ error contract", mode);
    NSCAssert(loader.released.count == loader.submitted.count, @"%@ leaked requests", mode);
    NSCAssert(pump.cancellationUnconfirmed == [mode isEqual:@"stuck"], @"%@ cancellation state", mode);
    if (success) {
        NSCAssert(received == loader.original.length - start, @"source progress lost or duplicated bytes");
        NSCAssert([result isEqual:[loader.original subdataWithRange:NSMakeRange(start, loader.original.length - start)]], @"bytes reordered or duplicated");
        NSCAssert(loader.peak == 4, @"did not prefetch");
        for (GSPhotoKitRangeRequest *request in loader.submitted) {
            NSUInteger lower = (NSUInteger)request.dataRequest.requestedOffset;
            NSUInteger upper = lower + request.dataRequest.requestedLength;
            NSCAssert(lower / 16 == (upper - 1) / 16, @"request crossed native chunk boundary");
        }
    }
    if ([mode isEqual:@"rolling"]) NSCAssert(loader.arrivals.firstObject.unsignedIntegerValue == 32, @"not an out-of-order fixture");
    if ([mode isEqual:@"remote-error"] || [mode isEqual:@"cancel"] || [mode isEqual:@"consumer-error"])
        NSCAssert([error.domain isEqual:@"Fixture"] && error.code == 73, @"lost original error");
    if ([mode isEqual:@"short"] || [mode isEqual:@"overrun"] || [mode isEqual:@"cancel"] || [mode isEqual:@"remote-error"])
        NSCAssert(result.length == 0, @"committed invalid bytes");
    if (committed) *committed = start + result.length;
    return result;
}

static void TestPartialProgress(void) {
    dispatch_queue_t queue = dispatch_queue_create("fixture.partial", DISPATCH_QUEUE_SERIAL);
    NSObject *lock = [NSObject new];
    __block NSUInteger received = 0, reports = 0, consumed = 0;
    GSPhotoKitRangePump *pump = [GSPhotoKitRangePump new];
    pump.URL = [NSURL URLWithString:@"fixture://partial"]; pump.chunkBytes = 16; pump.maxRequests = 1;
    pump.requestTimeout = 2;
    NSData *original = [[Loader new].original subdataWithRange:NSMakeRange(0, 16)];
    pump.submit = ^(GSPhotoKitRangeRequest *request) {
        dispatch_async(queue, ^{
            [request.dataRequest respondWithData:[original subdataWithRange:NSMakeRange(0, 8)]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), queue, ^{
                @synchronized(lock) {
                    NSCAssert(received == 8 && reports == 1 && consumed == 0, @"partial data was invisible or idle polls invented progress");
                }
                [request.dataRequest respondWithData:[original subdataWithRange:NSMakeRange(8, 8)]];
                [request finishLoading];
                [request.dataRequest respondWithData:original]; // Closed callbacks must not count.
            });
        });
    };
    pump.releaseRequest = ^(GSPhotoKitRangeRequest *request, dispatch_block_t done) { dispatch_async(queue, done); };
    pump.receivedBytes = ^(unsigned long long bytes) {
        @synchronized(lock) { received += bytes; reports++; }
    };
    NSError *error = nil;
    BOOL success = [pump readOffset:0 length:16 consume:^BOOL(NSData *bytes, NSError **failure) {
        NSCAssert([bytes isEqual:original], @"partial progress changed ordered bytes");
        @synchronized(lock) { consumed += bytes.length; } return YES;
    } error:&error];
    NSCAssert(success && !error && received == 16 && reports == 2 && consumed == 16, @"partial progress contract");
}

int main(void) { @autoreleasepool {
    TestPartialProgress();
    Run(@"rolling", 0, YES, NULL);
    Run(@"resume", 3, YES, NULL);
    for (NSString *mode in @[@"short", @"overrun", @"remote-error", @"consumer-error", @"cancel", @"timeout", @"stuck"])
        Run(mode, 0, NO, NULL);
    NSUInteger committed = 0;
    NSData *prefix = Run(@"consumer-error", 0, NO, &committed);
    NSCAssert(committed == 16, @"checkpoint advanced past failed consumer");
    NSData *tail = Run(@"resume", committed, YES, NULL);
    NSMutableData *joined = [prefix mutableCopy]; [joined appendData:tail];
    NSCAssert([joined isEqual:[Loader new].original], @"resume integrity");
    GSPhotoKitRangePump *invalid = [GSPhotoKitRangePump new]; NSError *error = nil;
    NSCAssert(![invalid readOffset:LLONG_MAX length:1 consume:^BOOL(NSData *data, NSError **failure) { abort(); } error:&error] && error, @"offset overflow");
    puts("PhotoKit rolling ranges: ordering, bounds, resume, errors and cancellation passed");
    return 0;
}}
