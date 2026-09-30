#import "GSPhotoKitRangePump.h"
#import <limits.h>

static NSError *GSRangeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Gunshot.PhotoKitRange" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface GSPhotoKitRangeData ()
@property NSMutableData *buffer;
@property NSError *failure;
@property BOOL closed;
@end
@implementation GSPhotoKitRangeData
- (instancetype)init { if ((self = [super init])) _buffer = [NSMutableData data]; return self; }
- (BOOL)requestsAllDataToEndOfResource { return NO; }
- (void)respondWithData:(NSData *)data {
    @synchronized(self) {
        if (self.closed || self.failure) return;
        if (self.currentOffset < self.requestedOffset ||
            self.currentOffset - self.requestedOffset > self.requestedLength ||
            data.length > (NSUInteger)(self.requestedLength - (self.currentOffset - self.requestedOffset))) {
            self.failure = GSRangeError(1, @"PhotoKit returned an invalid byte range."); return;
        }
        [self.buffer appendData:data];
        self.currentOffset += data.length;
    }
}
@end

@interface GSPhotoKitRangeRequest ()
@property(readwrite) BOOL finished;
@property NSError *failure;
@property dispatch_semaphore_t changed;
@property NSTimeInterval deadline;
@property BOOL releaseStarted;
@property BOOL released;
@end
@implementation GSPhotoKitRangeRequest
- (instancetype)init { if ((self = [super init])) _changed = dispatch_semaphore_create(0); return self; }
- (id)contentInformationRequest { return nil; }
- (BOOL)isFinished { return self.finished; }
- (BOOL)isCancelled { return self.cancelled; }
- (void)finishLoading { [self finishLoadingWithError:nil]; }
- (void)finishLoadingWithError:(NSError *)error {
    @synchronized(self) {
        if (self.finished) return;
        @synchronized(self.dataRequest) {
            self.dataRequest.closed = YES;
            self.failure = error ?: self.dataRequest.failure;
            if (!self.failure && self.dataRequest.currentOffset != self.dataRequest.requestedOffset + self.dataRequest.requestedLength)
                self.failure = GSRangeError(9, @"PhotoKit returned an incomplete range.");
        }
        self.finished = YES;
        dispatch_semaphore_signal(self.changed);
    }
}
@end

@implementation GSPhotoKitRangePump
- (instancetype)init {
    if ((self = [super init])) { _chunkBytes = 5 << 20; _maxRequests = 4; _requestTimeout = 180; _cancellationTimeout = 15; }
    return self;
}
- (void)release:(GSPhotoKitRangeRequest *)request {
    if (request.releaseStarted) return;
    request.releaseStarted = YES;
    self.releaseRequest(request, ^{ request.released = YES; dispatch_semaphore_signal(request.changed); });
}
- (BOOL)readOffset:(unsigned long long)offset length:(unsigned long long)length
           consume:(BOOL (^)(NSData *, NSError **))consume error:(NSError **)error {
    _cancellationUnconfirmed = NO;
    if (offset > LLONG_MAX || length > (unsigned long long)LLONG_MAX - offset ||
        !self.chunkBytes || self.chunkBytes > (5U << 20) || !self.maxRequests || self.maxRequests > 4 ||
        !self.URL || !self.submit || !self.releaseRequest || !consume) {
        if (error) *error = GSRangeError(1, @"The original byte range is invalid."); return NO;
    }
    unsigned long long scheduled = offset, end = offset + length;
    NSMutableArray<GSPhotoKitRangeRequest *> *pending = [NSMutableArray array];
    NSError *failure = nil;
    while (offset < end && !failure) { @autoreleasepool {
        failure = self.interruption ? self.interruption() : nil;
        if (failure) break;
        while (pending.count < self.maxRequests && scheduled < end) {
            GSPhotoKitRangeRequest *request = [GSPhotoKitRangeRequest new];
            request.request = [NSURLRequest requestWithURL:self.URL];
            request.dataRequest = [GSPhotoKitRangeData new];
            request.dataRequest.requestedOffset = scheduled;
            request.dataRequest.currentOffset = scheduled;
            request.dataRequest.requestedLength = (NSInteger)MIN(self.chunkBytes - scheduled % self.chunkBytes, end - scheduled);
            request.deadline = NSProcessInfo.processInfo.systemUptime + self.requestTimeout;
            [pending addObject:request];
            scheduled += request.dataRequest.requestedLength;
            self.submit(request);
        }
        GSPhotoKitRangeRequest *request = pending.firstObject;
        while (!failure) {
            failure = self.interruption ? self.interruption() : nil;
            for (GSPhotoKitRangeRequest *other in pending) {
                if (other.finished && other.failure) { failure = failure ?: other.failure; break; }
            }
            if (failure || request.finished) break;
            if (NSProcessInfo.processInfo.systemUptime >= request.deadline) {
                failure = GSRangeError(5, @"Timed out waiting for original data."); break;
            }
            dispatch_semaphore_wait(request.changed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20));
        }
        if (failure) break;
        [self release:request];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + self.cancellationTimeout;
        while (!request.released && NSProcessInfo.processInfo.systemUptime < deadline)
            dispatch_semaphore_wait(request.changed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20));
        if (!request.released) { failure = GSRangeError(4, @"PhotoKit did not release the completed range."); break; }
        failure = self.interruption ? self.interruption() : nil;
        if (failure) break;
        // Only this reader thread touches the consumer. Loader callbacks never
        // wait on filesystem sync, upload backpressure, or the application's queues.
        NSData *bytes = request.dataRequest.buffer;
        request.dataRequest.buffer = nil;
        if (!consume(bytes, &failure)) {
            failure = failure ?: GSRangeError(2, @"Original streaming was interrupted."); break;
        }
        offset += request.dataRequest.requestedLength;
        [pending removeObjectAtIndex:0];
    }}
    // Cancel every outstanding request before waiting; a single shared deadline
    // prevents four stuck requests from multiplying the cancellation timeout.
    for (GSPhotoKitRangeRequest *request in pending) {
        request.cancelled = YES;
        @synchronized(request.dataRequest) { request.dataRequest.closed = YES; request.dataRequest.buffer = nil; }
        [self release:request];
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + self.cancellationTimeout;
    for (GSPhotoKitRangeRequest *request in pending) {
        while ((!request.finished || !request.released) && NSProcessInfo.processInfo.systemUptime < deadline)
            dispatch_semaphore_wait(request.changed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20));
        if (!request.finished || !request.released) _cancellationUnconfirmed = YES;
    }
    if (error) *error = failure;
    return offset == end && !failure && !self.cancellationUnconfirmed;
}
@end
