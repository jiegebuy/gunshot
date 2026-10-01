#import <Foundation/Foundation.h>

// Duck-typed AVAssetResourceLoadingRequest, isolated from the PhotoKit adapter.
@interface GSPhotoKitRangeData : NSObject
@property long long requestedOffset;
@property NSInteger requestedLength;
@property long long currentOffset;
- (BOOL)requestsAllDataToEndOfResource;
- (void)respondWithData:(NSData *)data;
@end

@interface GSPhotoKitRangeRequest : NSObject
@property NSURLRequest *request;
@property GSPhotoKitRangeData *dataRequest;
@property NSURLResponse *response;
@property NSURLRequest *redirect;
@property(readonly) BOOL finished;
@property BOOL cancelled;
- (id)contentInformationRequest;
- (BOOL)isFinished;
- (BOOL)isCancelled;
- (void)finishLoading;
- (void)finishLoadingWithError:(NSError *)error;
@end

@interface GSPhotoKitRangePump : NSObject
@property NSURL *URL;
@property NSUInteger chunkBytes;
@property NSUInteger maxRequests;
@property NSTimeInterval requestTimeout;
@property NSTimeInterval cancellationTimeout;
@property(copy) void (^submit)(GSPhotoKitRangeRequest *);
// Completion acknowledges the delegate cancellation/release call, not a read.
@property(copy) void (^releaseRequest)(GSPhotoKitRangeRequest *, dispatch_block_t);
@property(copy) NSError *(^interruption)(void);
// Actual accepted source bytes, including partial and out-of-order ranges.
// Called on the reader thread; it does not advance the durable upload offset.
@property(copy) void (^receivedBytes)(unsigned long long);
@property(readonly) BOOL cancellationUnconfirmed;
- (BOOL)readOffset:(unsigned long long)offset length:(unsigned long long)length
           consume:(BOOL (^)(NSData *, NSError **))consume error:(NSError **)error;
@end
