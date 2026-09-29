#import "../UI/GSBatchImport.h"
#import "../UI/GSExporter.h"
#import "../Shared/IPCProtocol.h"
#import "../UI/GSImportStorage.h"
#include <assert.h>
#include <stdatomic.h>
#include <math.h>

// Exercise the real PhotoKit exporter, 32 KiB IPC importer and batch worker.
// Opaque bytes stand in for PhotoKit originals; no codec or network is mocked
// as successfully decoding these bytes.
static atomic_ulong Queued;
static atomic_ulong Written;
static BOOL IncludeUnreadable;
static BOOL RejectAppend;
static BOOL SlashHeavy;
static NSUInteger Cancelled;
static __weak NSError *LastAppendError;
static atomic_int ActiveExports,PeakExports;
static dispatch_semaphore_t CloudStarted,CloudRelease;
static NSMutableArray<NSMutableData *> *Received;
static NSMutableDictionary<NSString *,NSString *> *SourceJobs;
static NSMutableDictionary<NSString *,NSDictionary *> *CopyJobs;
static dispatch_semaphore_t LargeCopyStarted,LargeCopyRelease;
static dispatch_semaphore_t SmallCopyStarted,SmallCopyRelease;
static atomic_bool LargeBuffered;
static atomic_ullong FreeOverride;
static NSUInteger CapacityWaits,PausedWaits,FaultWaits,StorageEvents,CloudCancelled;
static atomic_ulong FreeReads;
static BOOL LowSpace,LowSpaceDuringExport;
static atomic_int CloudCancel;
unsigned long long GSFixtureFreeBytes(void){FreeReads++;return FreeOverride?FreeOverride:LowSpace||(LowSpaceDuringExport&&FreeReads>1)?GSStorageReserve:32ULL<<30;}
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
static NSData *ResourceBytes(NSString *name){
 if([name isEqual:@"large.MOV"])return [NSMutableData dataWithLength:(40ULL<<20)+13];
 return OriginalBytes([name isEqual:@"original.MOV"]);
}
static NSDictionary *CopyJob(NSString *identifier){@synchronized(CopyJobs){return CopyJobs[identifier];}}
static void BeforeAppend(NSDictionary *job,NSUInteger index,unsigned long long offset){
 if(SmallCopyRelease&&offset==0&&[job[@"resources"][index][@"name"]isEqual:@"original.HEIC"]){
  dispatch_semaphore_signal(SmallCopyStarted);
  assert(dispatch_semaphore_wait(SmallCopyRelease,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 }
 if(LargeCopyRelease&&offset==0&&[job[@"resources"][index][@"name"]isEqual:@"large.MOV"]){
  dispatch_semaphore_signal(LargeCopyStarted);
  assert(dispatch_semaphore_wait(LargeCopyRelease,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 }
}
@interface PHFetchResult ()
@property(nonatomic,strong) NSArray *items;
@end
@implementation PHFetchResult
- (void)enumerateObjectsUsingBlock:(void (^)(PHAsset *,NSUInteger,BOOL *))block{BOOL stop=NO;NSUInteger i=0;for(PHAsset *asset in self.items){block(asset,i++,&stop);if(stop)break;}}
@end
@implementation PHAsset
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)ids options:(id)options{
 assert(!NSThread.isMainThread&&ids.count<=256);NSMutableArray *items=[NSMutableArray array];
 for(NSString *identifier in ids){PHAsset *asset=[PHAsset new];asset.localIdentifier=identifier;asset.fixtureQueueLabel=@(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));
 asset.creationDate=[NSDate dateWithTimeIntervalSince1970:123];asset.mediaType=PHAssetMediaTypeImage;
 if(identifier.intValue==5)asset.mediaSubtypes=PHAssetMediaSubtypePhotoLive;
 [items addObject:asset];}
 PHFetchResult *result=[PHFetchResult new];result.items=items;return result;
}
@end
@interface PHAssetResource ()
@property(nonatomic) BOOL unreadable;
@end
@implementation PHAssetResource
+ (NSArray *)assetResourcesForAsset:(PHAsset *)asset{
 if(![asset.localIdentifier isEqual:@"native"]){NSString *label=@(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));assert([label isEqual:asset.fixtureQueueLabel]);}
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
- (void)cancelDataRequest:(PHAssetResourceDataRequestID)requestID{assert(requestID==1);CloudCancelled++;atomic_store(&CloudCancel,1);}
- (PHAssetResourceDataRequestID)requestDataForAssetResource:(PHAssetResource *)resource options:(PHAssetResourceRequestOptions *)options dataReceivedHandler:(void (^)(NSData *))handler completionHandler:(void (^)(NSError *))completion{
 assert(!NSThread.isMainThread&&options.networkAccessAllowed);
 int active=atomic_fetch_add(&ActiveExports,1)+1;if(active>atomic_load(&PeakExports))atomic_store(&PeakExports,active);assert(active<=GS_IMPORT_LANES);
 atomic_store(&CloudCancel,0);BOOL unreadable=resource.unreadable;
 NSData *bytes=OriginalBytes(resource.type==PHAssetResourceTypePairedVideo);Written++;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  if(options.progressHandler){
   options.progressHandler(NAN);options.progressHandler(INFINITY);options.progressHandler(-1);
   options.progressHandler(0.25);options.progressHandler(0.25);options.progressHandler(0.1);options.progressHandler(0.5);
  }
  if(CloudRelease){dispatch_semaphore_signal(CloudStarted);dispatch_semaphore_wait(CloudRelease,DISPATCH_TIME_FOREVER);}
  [NSThread sleepForTimeInterval:0.01]; // Model an asynchronous PhotoKit/iCloud wait.
  if(options.progressHandler)options.progressHandler(1.0);
  NSError *failure=unreadable?[NSError errorWithDomain:@"private-resource-error" code:99 userInfo:nil]:nil;
  if(!failure)for(NSUInteger offset=0;offset<bytes.length&&!atomic_load(&CloudCancel);offset+=1048576){
   handler([bytes subdataWithRange:NSMakeRange(offset,MIN(1048576,bytes.length-offset))]);
  }
  if(atomic_load(&CloudCancel))failure=[NSError errorWithDomain:@"PhotoKitCancelled" code:1 userInfo:nil];
  atomic_fetch_sub(&ActiveExports,1);completion(failure);
 }});
 return 1;
}
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
 NSDictionary *job=CopyJob(identifier);BeforeAppend(job,index,offset);
 if(RejectAppend&&offset>=32768){
  NSError *failure=[NSError errorWithDomain:@"Gunshot.IPC" code:73 userInfo:@{NSLocalizedDescriptionKey:@"Synthetic late binary chunk rejection"}];
  LastAppendError=failure;if(error)*error=failure;return NO;
 }
 NSMutableData *bytes=job[@"received"][index];assert(bytes.length==offset);[bytes appendData:data];return YES;
}
#endif
NSDictionary *GSRequest(NSDictionary *request,NSError **error){
 // Match the real transport boundary instead of accepting oversized mocks.
 assert([NSJSONSerialization dataWithJSONObject:request options:0 error:nil].length<=GS_MAX_JSON);
 assert(!NSThread.isMainThread);NSString *op=request[@"op"];
 if([op isEqual:@"import_capacity"]){
  if(LargeBuffered)return @{@"retainedBytes":@(9ULL<<30),@"bufferedBytes":@(9ULL<<30),@"smallBufferedBytes":@0,@"bufferedJobs":@1,@"releasableBytes":@0,@"paused":@NO};
  BOOL full=CapacityWaits>0,paused=PausedWaits>0,fault=FaultWaits>0;if(full)CapacityWaits--;if(paused)PausedWaits--;if(fault)FaultWaits--;
  return @{@"retainedBytes":@(full?(8ULL<<30):0),@"retainedJobs":@(full?128:0),@"releasableBytes":@(full?(8ULL<<30):0),@"paused":@(paused),@"storageFault":@(fault)};
 }
 if([op isEqual:@"accounts"])return @{@"selected":@"fixture@example.com"};
 if([op isEqual:@"options"])return @{@"quality":@"original",@"concurrent":@8};
 if([op isEqual:@"source_lookup"]){
  @synchronized(SourceJobs){NSString *job=SourceJobs[request[@"sourceID"]];return job?@{@"found":@YES,@"id":job,@"state":@"completed"}:@{@"found":@NO};}
 }
 if([op isEqual:@"begin"]){
  assert([request[@"quality"]isEqual:@"original"]&&[request[@"account"]isEqual:@"fixture@example.com"]&&[request[@"timestamp"]longLongValue]==123);
  NSString *identifier=NSUUID.UUID.UUIDString;
  if([request[@"sourceID"]length])@synchronized(SourceJobs){SourceJobs[request[@"sourceID"]]=identifier;}
  NSArray *resources=request[@"resources"];NSMutableArray *received=[NSMutableArray array];
  for(NSDictionary *resource in resources){assert([resource[@"size"]unsignedIntegerValue]==ResourceBytes(resource[@"name"]).length);[received addObject:[NSMutableData data]];}
  @synchronized(CopyJobs){CopyJobs[identifier]=@{@"resources":resources,@"received":received};Received=received;}
  return @{@"id":identifier};
 }
 if([op isEqual:@"append"]){
  NSDictionary *job=CopyJob(request[@"id"]);BeforeAppend(job,[request[@"index"]unsignedIntegerValue],[request[@"offset"]unsignedLongLongValue]);
  if(RejectAppend&&[request[@"offset"]unsignedIntegerValue]>=32768){
   NSError *failure=[NSError errorWithDomain:@"Gunshot.IPC" code:73 userInfo:@{NSLocalizedDescriptionKey:@"Synthetic late chunk rejection"}];
   LastAppendError=failure;if(error)*error=failure;return nil;
  }
  NSMutableData *bytes=job[@"received"][[request[@"index"]unsignedIntegerValue]];assert(bytes.length==[request[@"offset"]unsignedIntegerValue]);
  NSData *chunk=[[NSData alloc]initWithBase64EncodedString:request[@"data"]options:0];assert(chunk.length>0&&chunk.length<=32768);[bytes appendData:chunk];return @{};
 }
 if([op isEqual:@"seal"]){
  NSDictionary *job=CopyJob(request[@"id"]);NSArray *received=job[@"received"],*resources=job[@"resources"];
  for(NSUInteger i=0;i<received.count;i++){
   assert([received[i]isEqual:ResourceBytes(resources[i][@"name"])]);
  }
  @synchronized(CopyJobs){[CopyJobs removeObjectForKey:request[@"id"]];}
  Queued++;return @{@"id":request[@"id"]};
 }
 if([op isEqual:@"cancel"]){@synchronized(CopyJobs){[CopyJobs removeObjectForKey:request[@"id"]];}Cancelled++;return @{};}
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
static void TestIndependentCopies(BOOL constrained){
 NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString]isDirectory:YES];
 assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
 NSURL *large=[directory URLByAppendingPathComponent:@"large.MOV"],*small=[directory URLByAppendingPathComponent:@"original.HEIC"];
 assert([ResourceBytes(@"large.MOV")writeToURL:large atomically:NO]);assert([ResourceBytes(@"original.HEIC")writeToURL:small atomically:NO]);
 LargeCopyStarted=dispatch_semaphore_create(0);LargeCopyRelease=dispatch_semaphore_create(0);
 dispatch_semaphore_t smallDone=dispatch_semaphore_create(0),spaceWait=dispatch_semaphore_create(0);
 dispatch_group_t group=dispatch_group_create();NSUInteger before=Queued;
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  assert(GSImportFilesWithProgress(@[large],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],nil,nil,nil));
 }});
 assert(dispatch_semaphore_wait(LargeCopyStarted,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 LargeBuffered=YES;
 if(constrained)FreeOverride=GSStorageReserve+(40ULL<<20)+13+FixtureSize-1;
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  __block BOOL reported=NO;
  assert(GSImportFilesWithProgress(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],nil,^(NSDictionary *event){
   if(!reported&&[event[@"stage"]isEqual:@"waiting_storage"]){
    assert([event[@"stagingReservedBytes"]unsignedLongLongValue]==(40ULL<<20)+13);reported=YES;dispatch_semaphore_signal(spaceWait);
   }
  },nil));
  dispatch_semaphore_signal(smallDone);
 }});
 if(constrained){
  assert(dispatch_semaphore_wait(spaceWait,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
  assert(dispatch_semaphore_wait(smallDone,DISPATCH_TIME_NOW)!=0); // Unwritten large bytes still reserve physical space.
  FreeOverride=0;
 }
 assert(dispatch_semaphore_wait(smallDone,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 assert(Queued==before+1); // Small upload is sealed while the large copy has written nothing.
 dispatch_semaphore_signal(LargeCopyRelease);
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 assert(Queued==before+2);LargeBuffered=NO;LargeCopyStarted=nil;LargeCopyRelease=nil;
 // A failed copy must release its unused reservation before the next admission.
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  FreeOverride=GSStorageReserve+FixtureSize;RejectAppend=YES;NSError *error=nil;
  assert(!GSImportFilesWithProgress(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],nil,nil,&error));assert(error);
  RejectAppend=NO;
  assert(GSImportFilesWithProgress(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],nil,nil,&error));assert(!error);
  FreeOverride=0;
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}
static void TestExportReservations(void){
 NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString]isDirectory:YES];
 assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
 NSURL *small=[directory URLByAppendingPathComponent:@"original.HEIC"];
 assert([ResourceBytes(@"original.HEIC")writeToURL:small atomically:NO]);
 dispatch_semaphore_t exported=dispatch_semaphore_create(0);
 dispatch_semaphore_t release[2]={dispatch_semaphore_create(0),dispatch_semaphore_create(0)};
 dispatch_semaphore_t done[2]={dispatch_semaphore_create(0),dispatch_semaphore_create(0)};
 dispatch_group_t group=dispatch_group_create();
 for(NSUInteger i=0;i<2;i++){
  dispatch_semaphore_t resume=release[i],finished=done[i];
  dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
   __block unsigned long long bytes=0;
   assert(GSImportPhotoIdentifierWithProgress([NSString stringWithFormat:@"reservation-%lu",(unsigned long)i],@"fixture@example.com",@"original",nil,^(NSDictionary *event){
    bytes+=[event[@"exportedBytesDelta"]unsignedLongLongValue];
    if(event[@"exportedBytesDelta"]&&bytes==FixtureSize){
     dispatch_semaphore_signal(exported);
     assert(dispatch_semaphore_wait(resume,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
    }
   },nil));
   dispatch_semaphore_signal(finished);
  }});
 }
 for(NSUInteger i=0;i<2;i++)assert(dispatch_semaphore_wait(exported,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 dispatch_semaphore_t inspected=dispatch_semaphore_create(0);
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  PausedWaits=1;__block BOOL observed=NO;
  assert(GSImportFilesWithProgress(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],nil,^(NSDictionary *event){
   if([event[@"stage"]isEqual:@"waiting_upload_resume"]){
    assert([event[@"exportCopyReservedBytes"]unsignedLongLongValue]==2ULL*FixtureSize);
    assert([event[@"stagingReservedBytes"]unsignedLongLongValue]==0);observed=YES;
   }
  },nil));
  assert(observed);
  // An unreserved caller must release the copy lane instead of waiting for
  // exported originals that need that lane to release their reservations.
  FreeOverride=GSStorageReserve+3ULL*FixtureSize-1;NSError *error=nil;
  assert(!GSImportFiles(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],&error));
  assert([error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSFileWriteOutOfSpaceError);
  dispatch_semaphore_signal(inspected);
 }});
 assert(dispatch_semaphore_wait(inspected,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 // Exactly enough space for the two reserved copies, with no second reservation.
 FreeOverride=GSStorageReserve+2ULL*FixtureSize;
 for(NSUInteger i=0;i<2;i++){
  dispatch_semaphore_signal(release[i]);
  assert(dispatch_semaphore_wait(done[i],dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 }
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);FreeOverride=0;
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  __block BOOL allowed=YES;NSError *error=nil;
  assert(!GSImportPhotoIdentifierWithProgress(@"reservation-cancel",@"fixture@example.com",@"original",^BOOL{return allowed;},^(NSDictionary *event){
   if([event[@"exportedBytesDelta"]unsignedLongLongValue])allowed=NO;
  },&error));
  assert([error.domain isEqual:@"Gunshot.Authorization"]);
  assert(!GSImportPhotoIdentifierWithProgress(@"reservation-storage-fault",@"fixture@example.com",@"original",nil,^(NSDictionary *event){
   if([event[@"exportedBytesDelta"]unsignedLongLongValue])FaultWaits=1;
  },&error));
  assert([error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSFileWriteOutOfSpaceError&&FaultWaits==0);
  // Failed exports and completed copies must both release all reservations.
  FreeOverride=GSStorageReserve+FixtureSize;
  assert(GSImportFiles(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],&error));assert(!error);FreeOverride=0;
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}
static void TestConcurrentSpaceLoss(void){
 NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString]isDirectory:YES];
 assert([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
 NSURL *large=[directory URLByAppendingPathComponent:@"large.MOV"],*small=[directory URLByAppendingPathComponent:@"original.HEIC"];
 assert([ResourceBytes(@"large.MOV")writeToURL:large atomically:NO]);assert([ResourceBytes(@"original.HEIC")writeToURL:small atomically:NO]);
 LargeCopyStarted=dispatch_semaphore_create(0);LargeCopyRelease=dispatch_semaphore_create(0);
 SmallCopyStarted=dispatch_semaphore_create(0);SmallCopyRelease=dispatch_semaphore_create(0);
 dispatch_semaphore_t largeDone=dispatch_semaphore_create(0);dispatch_group_t group=dispatch_group_create();
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  NSError *error=nil;
  assert(!GSImportFiles(@[large],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],&error));
  assert([error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSFileWriteOutOfSpaceError);dispatch_semaphore_signal(largeDone);
 }});
 assert(dispatch_semaphore_wait(LargeCopyStarted,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  assert(GSImportFiles(@[small],@"fixture@example.com",@"original",[NSDate dateWithTimeIntervalSince1970:123],nil));
 }});
 assert(dispatch_semaphore_wait(SmallCopyStarted,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 FreeOverride=GSStorageReserve-1;dispatch_semaphore_signal(LargeCopyRelease);
 // External disk usage must defer the large copy without waiting on the blocked small copy.
 assert(dispatch_semaphore_wait(largeDone,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 FreeOverride=0;dispatch_semaphore_signal(SmallCopyRelease);
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 LargeCopyStarted=nil;LargeCopyRelease=nil;SmallCopyStarted=nil;SmallCopyRelease=nil;
 [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}
int main(void){@autoreleasepool{
 SourceJobs=[NSMutableDictionary dictionary];CopyJobs=[NSMutableDictionary dictionary];
 NSDictionary *result=Run();assert(Queued==60&&Written==61&&[result[@"queued"]intValue]==60&&[result[@"failed"]intValue]==0);
 assert([result[@"exportedBytes"]unsignedLongLongValue]==61ULL*FixtureSize&&[result[@"cloudProgressUnits"]unsignedIntegerValue]==61000);
 assert([result[@"stagedBytes"]unsignedLongLongValue]==61ULL*FixtureSize);
 NSUInteger writtenAfterFirst=Written;result=Run();
 assert(Queued==60&&Written==writtenAfterFirst&&[result[@"queued"]intValue]==60&&[result[@"failed"]intValue]==0);
 assert([result[@"stagedBytes"]unsignedLongLongValue]==0); // Existing receipts copy no bytes.
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
 assert(atomic_load(&PeakExports)>1&&atomic_load(&PeakExports)<=GS_IMPORT_LANES);
 NSUInteger beforeDuplicates=Written;
 for(NSUInteger i=0;i<12;i++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  assert(GSImportPhotoIdentifier(@"same-source",@"fixture@example.com",@"original",nil));
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
 assert(Written==beforeDuplicates+1); // Concurrent callers must still export once.
 // Every identifier collides under the old hash-based assignment. A slow cloud
 // resource must not leave eleven otherwise usable preparation lanes idle.
 NSMutableArray *collisions=[NSMutableArray array];
 for(NSUInteger i=0;collisions.count<GS_IMPORT_LANES;i++){
  NSString *identifier=[NSString stringWithFormat:@"cloud-collision-%lu",(unsigned long)i];
  if(identifier.hash%GS_IMPORT_LANES==0)[collisions addObject:identifier];
 }
 CloudStarted=dispatch_semaphore_create(0);CloudRelease=dispatch_semaphore_create(0);
 NSUInteger beforeCloud=Written;atomic_store(&PeakExports,0);
 for(NSString *identifier in collisions)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  assert(GSImportPhotoIdentifier(identifier,@"fixture@example.com",@"original",nil));
 }});
 NSUInteger started=0;dispatch_time_t cloudDeadline=dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC);
 for(;started<GS_IMPORT_LANES;started++)if(dispatch_semaphore_wait(CloudStarted,cloudDeadline))break;
 for(NSUInteger i=0;i<GS_IMPORT_LANES;i++)dispatch_semaphore_signal(CloudRelease);
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0);
 CloudRelease=nil;CloudStarted=nil;
 assert(started==GS_IMPORT_LANES&&atomic_load(&PeakExports)==GS_IMPORT_LANES&&Written==beforeCloud+GS_IMPORT_LANES);
 // Exercise the failure AFTER one successful chunk. The error must survive the
 // exporter's inner autoreleasepool and ARC's out-parameter writeback on the
 // asset-import queue (the exact retain that faulted on the device).
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  RejectAppend=YES;
  NSError *error=nil;
  __block unsigned long long staged=0;NSUInteger queuedBefore=Queued;
  GSImportStorageProgress copyProgress=^(NSDictionary *event){
   staged+=[event[@"stagedBytesDelta"]unsignedLongLongValue];
   if(event[@"stagedBytesDelta"]){
    assert(staged==[Received[0]length]&&Queued==queuedBefore); // Publish accepted bytes before seal.
   }
  };
  assert(!GSImportPhotoIdentifierWithProgress(@"chunk-failure",@"fixture@example.com",@"original",nil,copyProgress,&error));
#if GS_JAILED
  assert(staged==1048576);
#else
  assert(staged==32768);
#endif
  assert(error&&LastAppendError==error);
  assert([error.domain isEqual:@"Gunshot.IPC"]&&error.code==73&&Cancelled==1);
  assert(!GSImportPhotoIdentifier(@"chunk-failure-no-error",@"fixture@example.com",@"original",nil));
  assert(Cancelled==2);
  RejectAppend=NO;
  staged=0;
  assert(GSImportPhotoIdentifierWithProgress(@"after-chunk-failure",@"fixture@example.com",@"original",nil,copyProgress,&error));
  assert(staged==FixtureSize);
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
 dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  assert(GSStorageQueueFull(GSStorageQueueLimit,1,0,GSStorageQueueLimit));
  assert(GSStorageQueueFull(GSStorageQueueLimit-1,1,2,GSStorageQueueLimit));
  assert(GSStorageQueueFull(1,128,0,GSStorageQueueLimit));
  assert(!GSStorageQueueFull(0,0,8ULL<<30,GSStorageQueueLimit)); // oversized asset runs alone
  unsigned long long roomy=GSStorageQueueBudget(23ULL<<30,2231778024ULL);
  assert(roomy>2231778024ULL&&!GSStorageQueueFull(2231778024ULL,1,32ULL<<20,roomy));
  assert(GSStorageQueueBudget(1ULL<<30,0)==GSStorageQueueLimit);
  assert(GSStorageQueueCanAdmit(9ULL<<30,0,1,FixtureSize,8ULL<<30,YES));
  assert(!GSStorageQueueCanAdmit((9ULL<<30)+GSStorageSmallQueueReserve,GSStorageSmallQueueReserve,10,FixtureSize,8ULL<<30,YES));
  assert(!GSStorageQueueCanAdmit(9ULL<<30,0,1,40ULL<<20,8ULL<<30,NO));
  assert(!GSStorageQueueCanAdmit(9ULL<<30,0,128,FixtureSize,8ULL<<30,YES));
  assert(GSStorageQueueCanAdmit(64ULL<<20,64ULL<<20,4,9ULL<<30,8ULL<<30,NO));
  CapacityWaits=2;StorageEvents=0;
  assert(GSImportPhotoIdentifierWithProgress(@"capacity-release",@"fixture@example.com",@"original",nil,^(NSDictionary *s){if([s[@"stage"]isEqual:@"waiting_storage"])StorageEvents++;},nil));
  assert(CapacityWaits==0&&StorageEvents==2);
  PausedWaits=2;StorageEvents=0;
  assert(GSImportPhotoIdentifierWithProgress(@"pause-release",@"fixture@example.com",@"original",nil,^(NSDictionary *s){if([s[@"stage"]isEqual:@"waiting_upload_resume"])StorageEvents++;},nil));
  assert(PausedWaits==0&&StorageEvents==2);
  FaultWaits=2;StorageEvents=0;NSUInteger beforeFault=Written;
  assert(GSImportPhotoIdentifierWithProgress(@"storage-fault-release",@"fixture@example.com",@"original",nil,^(NSDictionary *s){
   if([s[@"stage"]isEqual:@"waiting_storage"]){assert([s[@"storageFault"]boolValue]&&Written==beforeFault);StorageEvents++;}
  },nil));
  assert(FaultWaits==0&&StorageEvents==2&&Written==beforeFault+1);
  CapacityWaits=20;NSError *error=nil;
  assert(!GSImportPhotoIdentifierWithProgress(@"cancel-capacity",@"fixture@example.com",@"original",^BOOL{return CapacityWaits>18;},nil,&error));
  assert([error.domain isEqual:@"Gunshot.Authorization"]);CapacityWaits=0;
  LowSpace=YES;NSUInteger before=Written;
  NSUInteger freeBefore=FreeReads;
  assert(!GSImportPhotoIdentifierWithProgress(@"no-disk",@"fixture@example.com",@"original",^BOOL{return FreeReads<freeBefore+2;},nil,&error));
  assert([error.domain isEqual:@"Gunshot.Authorization"]&&Written==before);LowSpace=NO;
  FreeReads=0;LowSpaceDuringExport=YES;before=Queued;
  assert(!GSImportPhotoIdentifier(@"disk-filled-mid-export",@"fixture@example.com",@"original",&error));
  assert(error.code==NSFileWriteOutOfSpaceError&&CloudCancelled>0&&Queued==before);
  LowSpaceDuringExport=NO;
  assert(GSImportPhotoIdentifier(@"after-space-recovered",@"fixture@example.com",@"original",&error));assert(!error);
 }});
 assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))==0);
 CloudStarted=dispatch_semaphore_create(0);CloudRelease=dispatch_semaphore_create(0);
 __block NSDictionary *cloudResult=nil;
 assert(GSStartBatchImport(1,@"album",YES,GSPhotoIdentifierProvider(@[@"cloud-progress"]),@"fixture@example.com",@"fixture",nil,^(NSDictionary *state){cloudResult=state;}));
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];BOOL cloudStarted=NO;
 while(!cloudStarted&&deadline.timeIntervalSinceNow>0){
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  cloudStarted=dispatch_semaphore_wait(CloudStarted,DISPATCH_TIME_NOW)==0;
 }
 assert(cloudStarted);
 NSDictionary *preparing=GSBatchImportSnapshot();
 assert([preparing[@"cloudProgressUnits"]unsignedIntegerValue]==500&&[preparing[@"exportedBytes"]unsignedLongLongValue]==0&&[preparing[@"processed"]unsignedIntegerValue]==0);
 dispatch_semaphore_signal(CloudRelease);deadline=[NSDate dateWithTimeIntervalSinceNow:5];
 while(!cloudResult&&deadline.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
 assert(cloudResult&&[cloudResult[@"queued"]unsignedIntegerValue]==1&&[cloudResult[@"exportedBytes"]unsignedLongLongValue]==FixtureSize&&[cloudResult[@"cloudProgressUnits"]unsignedIntegerValue]==1000);
 CloudStarted=nil;CloudRelease=nil;
 TestIndependentCopies(NO);TestIndependentCopies(YES);TestConcurrentSpaceLoss();TestExportReservations();
 NSLog(@"PASS aggregate export reservations, atomic copy transfer, blocked lane deferral and export cleanup after cancellation/storage fault");
 NSLog(@"PASS small copies bypass blocked large copies, bounded photo capacity and physical reservation cleanup");
 NSLog(@"PASS real cloud progress before data delivery, monotonic fractions and concurrent byte aggregation");
 NSLog(@"PASS storage backpressure, automatic resume, paused uploads, cancellation, oversized isolation and low-space stream cancellation/recovery");
 NSLog(@"PASS slash-heavy originals fit the actual JSON transport limit with exact bytes");
 NSLog(@"PASS late chunk error lifetime, cancellation, recovery and 25000 source-deduplicated imports");
 NSLog(@"PASS 60 HEIC/HEIF originals, Live Photo resources, exact IPC bytes/timestamp, unreadable original isolation and bounded concurrent native exports");
}}
