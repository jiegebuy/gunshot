#import "../UI/GSBatchImport.h"
#import "../UI/GSExporter.h"
#import "../Shared/IPCProtocol.h"
#include <assert.h>
#include <stdatomic.h>

// Exercise the real PhotoKit exporter, 32 KiB IPC importer and batch worker.
// Opaque bytes stand in for PhotoKit originals; no codec or network is mocked
// as successfully decoding these bytes.
static NSUInteger Queued,Written;
static BOOL IncludeUnreadable;
static BOOL RejectAppend;
static BOOL SlashHeavy;
static NSUInteger Cancelled;
static __weak NSError *LastAppendError;
static atomic_int ActiveExports,PeakExports;
static NSString *FetchQueueLabel;
static NSArray *ExpectedResources;
static NSMutableArray<NSMutableData *> *Received;
static NSMutableDictionary<NSString *,NSString *> *SourceJobs;
#if GS_JAILED
static const NSUInteger FixtureSize=2097165;
#else
static const NSUInteger FixtureSize=70013;
#endif
static NSData *OriginalBytes(BOOL movie){
 NSMutableData *bytes=[NSMutableData dataWithLength:FixtureSize];uint8_t *p=bytes.mutableBytes;
 for(NSUInteger i=0;i<bytes.length;i++)p[i]=(uint8_t)(i*17+(movie?3:7));
 if(SlashHeavy)memset(p,0xff,bytes.length);
 memcpy(p,"\0\0\0\x18" "ftyp",8);memcpy(p+8,movie?"qt  ":"heic",4);return bytes;
}
@interface PHFetchResult ()
@property(nonatomic,strong) NSArray *items;
@end
@implementation PHFetchResult
- (void)enumerateObjectsUsingBlock:(void (^)(PHAsset *,NSUInteger,BOOL *))block{BOOL stop=NO;NSUInteger i=0;for(PHAsset *asset in self.items){block(asset,i++,&stop);if(stop)break;}}
@end
@implementation PHAsset
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)ids options:(id)options{
 assert(!NSThread.isMainThread&&ids.count==1);
 NSString *identifier=ids.firstObject;FetchQueueLabel=@(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));PHAsset *asset=[PHAsset new];asset.localIdentifier=identifier;
 asset.creationDate=[NSDate dateWithTimeIntervalSince1970:123];asset.mediaType=PHAssetMediaTypeImage;
 if(identifier.intValue==5)asset.mediaSubtypes=PHAssetMediaSubtypePhotoLive;
 PHFetchResult *result=[PHFetchResult new];result.items=@[asset];return result;
}
@end
@interface PHAssetResource ()
@property(nonatomic) BOOL unreadable;
@end
@implementation PHAssetResource
+ (NSArray *)assetResourcesForAsset:(PHAsset *)asset{
 if(![asset.localIdentifier isEqual:@"native"]){NSString *label=@(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));assert([label isEqual:FetchQueueLabel]);}
 PHAssetResource *photo=[PHAssetResource new];photo.type=PHAssetResourceTypePhoto;
 photo.originalFilename=asset.localIdentifier.intValue%2?@"original.HEIC":@"original.heif";
 photo.unreadable=IncludeUnreadable&&asset.localIdentifier.intValue==30;
 if(asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive){
  PHAssetResource *video=[PHAssetResource new];video.type=PHAssetResourceTypePairedVideo;video.originalFilename=@"original.MOV";
  return @[photo,video];
 }
 return @[photo];
}
@end
@implementation PHAssetResourceRequestOptions @end
@implementation PHAssetResourceManager
+ (instancetype)defaultManager{static id manager;static dispatch_once_t once;dispatch_once(&once,^{manager=[self new];});return manager;}
- (void)writeDataForAssetResource:(PHAssetResource *)resource toFile:(NSURL *)url options:(PHAssetResourceRequestOptions *)options completionHandler:(void (^)(NSError *))completion{
 assert(!NSThread.isMainThread&&options.networkAccessAllowed);
 int active=atomic_fetch_add(&ActiveExports,1)+1;
 if(active>atomic_load(&PeakExports))atomic_store(&PeakExports,active);
 assert(active==1);
 [NSThread sleepForTimeInterval:0.001];
 atomic_fetch_sub(&ActiveExports,1);
 if(resource.unreadable){completion([NSError errorWithDomain:@"private-resource-error" code:99 userInfo:nil]);return;}
 assert([url.lastPathComponent isEqual:resource.originalFilename]);Written++;
 NSError *error=nil;[OriginalBytes(resource.type==PHAssetResourceTypePairedVideo)writeToURL:url options:0 error:&error];completion(error);
}
@end
BOOL GSNativeIdentityMatches(NSString *identifier){assert(NSThread.isMainThread);return [identifier isEqual:@"fixture"];} 
#if GS_JAILED
BOOL GSEmbeddedAppend(NSString *identifier,NSUInteger index,unsigned long long offset,NSData *data,NSError **error){
 assert(!NSThread.isMainThread&&data.length>0&&data.length<=1048576);
 if(RejectAppend&&offset>=32768){
  NSError *failure=[NSError errorWithDomain:@"Gunshot.IPC" code:73 userInfo:@{NSLocalizedDescriptionKey:@"Synthetic late binary chunk rejection"}];
  LastAppendError=failure;if(error)*error=failure;return NO;
 }
 NSMutableData *bytes=Received[index];assert(bytes.length==offset);[bytes appendData:data];return YES;
}
#endif
NSDictionary *GSRequest(NSDictionary *request,NSError **error){
 // Match the real transport boundary instead of accepting oversized mocks.
 assert([NSJSONSerialization dataWithJSONObject:request options:0 error:nil].length<=GS_MAX_JSON);
 assert(!NSThread.isMainThread);NSString *op=request[@"op"];
 if([op isEqual:@"accounts"])return @{@"selected":@"fixture@example.com"};
 if([op isEqual:@"options"])return @{@"quality":@"original"};
 if([op isEqual:@"source_lookup"]){
  NSString *job=SourceJobs[request[@"sourceID"]];return job?@{@"found":@YES,@"id":job,@"state":@"completed"}:@{@"found":@NO};
 }
 if([op isEqual:@"begin"]){
  assert([request[@"quality"]isEqual:@"original"]&&[request[@"account"]isEqual:@"fixture@example.com"]&&[request[@"timestamp"]longLongValue]==123);
  assert([request[@"sourceID"]length]>0);
  SourceJobs[request[@"sourceID"]]=@"fixture-job";
  ExpectedResources=request[@"resources"];Received=[NSMutableArray array];
  for(NSDictionary *resource in ExpectedResources){assert([resource[@"size"]unsignedIntegerValue]==FixtureSize);[Received addObject:[NSMutableData data]];}
  return @{@"id":@"fixture-job"};
 }
 if([op isEqual:@"append"]){
  if(RejectAppend&&[request[@"offset"]unsignedIntegerValue]>=32768){
   NSError *failure=[NSError errorWithDomain:@"Gunshot.IPC" code:73 userInfo:@{NSLocalizedDescriptionKey:@"Synthetic late chunk rejection"}];
   LastAppendError=failure;if(error)*error=failure;return nil;
  }
  NSMutableData *bytes=Received[[request[@"index"]unsignedIntegerValue]];assert(bytes.length==[request[@"offset"]unsignedIntegerValue]);
  NSData *chunk=[[NSData alloc]initWithBase64EncodedString:request[@"data"]options:0];assert(chunk.length>0&&chunk.length<=32768);[bytes appendData:chunk];return @{};
 }
 if([op isEqual:@"seal"]){
  for(NSUInteger i=0;i<Received.count;i++){
   BOOL movie=[ExpectedResources[i][@"name"]isEqual:@"original.MOV"];
   assert([Received[i]isEqual:OriginalBytes(movie)]);
  }
  Queued++;return @{@"id":@"fixture-job"};
 }
 if([op isEqual:@"cancel"]){Cancelled++;return @{};}
 assert(NO);return nil;
}
static NSDictionary *Run(void){
 __block NSDictionary *done=nil;
 NSMutableArray *ids=[NSMutableArray array];for(NSUInteger index=0;index<60;index++)[ids addObject:[NSString stringWithFormat:@"%lu",(unsigned long)index]];
 assert(GSStartBatchImport(60,@"album",YES,GSPhotoIdentifierProvider(ids),@"fixture@example.com",@"fixture",nil,^(NSDictionary *state){done=state;}));
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
 while(!done&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
 assert(done);return done;
}
int main(void){@autoreleasepool{
 SourceJobs=[NSMutableDictionary dictionary];
 NSDictionary *result=Run();assert(Queued==60&&Written==61&&[result[@"queued"]intValue]==60&&[result[@"failed"]intValue]==0);
 NSUInteger writtenAfterFirst=Written;result=Run();
 assert(Queued==60&&Written==writtenAfterFirst&&[result[@"queued"]intValue]==60&&[result[@"failed"]intValue]==0);
 [SourceJobs removeAllObjects];
 IncludeUnreadable=YES;result=Run();assert(Queued==119&&[result[@"queued"]intValue]==59&&[result[@"failed"]intValue]==1&&[result[@"remaining"]intValue]==0);
 assert([result[@"failureCodes"][@"export_failed"]intValue]==1);
 IncludeUnreadable=NO;
 dispatch_group_t group=dispatch_group_create();
 for(NSUInteger i=0;i<60;i++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  PHAsset *asset=[PHAsset new];asset.mediaType=PHAssetMediaTypeImage;asset.localIdentifier=@"native";
  NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString]isDirectory:YES];
  assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
  NSArray *files=GSExportAsset(asset,directory,nil);assert(files.count==1);
  assert([[NSData dataWithContentsOfURL:files[0]]isEqual:OriginalBytes(NO)]);
  [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 assert(atomic_load(&PeakExports)==1);
 // Exercise the failure AFTER one successful chunk. The error must survive the
 // exporter's inner autoreleasepool and ARC's out-parameter writeback on the
 // asset-import queue (the exact retain that faulted on the device).
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  RejectAppend=YES;
  NSError *error=nil;
  assert(!GSImportPhotoIdentifier(@"chunk-failure",@"fixture@example.com",@"original",&error));
  assert(error&&LastAppendError==error);
  assert([error.domain isEqual:@"Gunshot.IPC"]&&error.code==73&&Cancelled==1);
  assert(!GSImportPhotoIdentifier(@"chunk-failure-no-error",@"fixture@example.com",@"original",nil));
  assert(Cancelled==2);
  RejectAppend=NO;
  assert(GSImportPhotoIdentifier(@"after-chunk-failure",@"fixture@example.com",@"original",&error));
  assert(!error);
  NSUInteger before=Written;
  for(NSUInteger i=0;i<25000;i++){@autoreleasepool{
   NSString *identifier=[NSString stringWithFormat:@"large-library-%lu",(unsigned long)i];
   SourceJobs[identifier]=@"fixture-job";
   assert(GSImportPhotoIdentifier(identifier,@"fixture@example.com",@"original",nil));
  }}
  assert(Written==before);
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC))==0);
 // JPEG padding and other binary data can encode as long runs of '/'.
 // The old 32 KiB chunk exceeds 60 KB after Foundation JSON escaping.
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  SlashHeavy=YES;
  NSMutableData *worst=[NSMutableData dataWithLength:32768];memset(worst.mutableBytes,0xff,worst.length);
  NSData *oversized=[NSJSONSerialization dataWithJSONObject:@{@"data":[worst base64EncodedStringWithOptions:0]} options:0 error:nil];
  assert(oversized.length>GS_MAX_JSON);
  NSError *error=nil;
  assert(GSImportPhotoIdentifier(@"slash-heavy-photo",@"fixture@example.com",@"original",&error));
  assert(!error);
  SlashHeavy=NO;
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0);
 NSLog(@"PASS slash-heavy originals fit the actual JSON transport limit with exact bytes");
 NSLog(@"PASS late chunk error lifetime, cancellation, recovery and 25000 source-deduplicated imports");
 NSLog(@"PASS 60 HEIC/HEIF originals, Live Photo resources, exact IPC bytes/timestamp, unreadable original isolation and bounded concurrent native exports");
}}
