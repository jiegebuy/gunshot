#import "../Shared/GSLocalization.h"
#import "GSExporter.h"
#import "../Shared/IPCProtocol.h"
#import "GSImportStorage.h"
#include <math.h>

static unsigned long long GSStagingReservedBytes,GSExportReservedBytes;
static NSObject *GSStorageAdmissionLock(void){
 static NSObject *lock;static dispatch_once_t once;dispatch_once(&once,^{lock=[NSObject new];});return lock;
}
static BOOL GSWaitForStorage(NSURL *directory,unsigned long long needed,unsigned long long incoming,unsigned long long ownReservation,BOOL limitQueue,BOOL small,
 GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error,BOOL (^admit)(NSError **)){
 BOOL waited=NO;NSError *failure=nil;
 @try {
 while(YES){@autoreleasepool{
  if(authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return NO;}
  NSDictionary *waiting=nil;
  @synchronized(GSStorageAdmissionLock()){
  NSDictionary *capacity=GSRequest(@{@"op":@"import_capacity"},&failure);if(!capacity)return NO;
  unsigned long long free=GSStorageFreeBytes(directory),retained=[capacity[@"retainedBytes"]unsignedLongLongValue];
  unsigned long long buffered=[(capacity[@"bufferedBytes"]?:capacity[@"retainedBytes"])unsignedLongLongValue];
  NSUInteger bufferedJobs=[(capacity[@"bufferedJobs"]?:capacity[@"retainedJobs"])unsignedIntegerValue];
  unsigned long long budget=GSStorageQueueBudget(free,buffered);
  unsigned long long available=free>GSStorageReserve?free-GSStorageReserve:0;
  unsigned long long reserved=GSStagingReservedBytes+GSExportReservedBytes;
  BOOL space=free<GSStorageReserve||reserved>available||needed>available-MIN(available,reserved);
  unsigned long long smallBuffered=[(capacity[@"smallBufferedBytes"]?:@(buffered))unsignedLongLongValue];
  BOOL queue=limitQueue&&!GSStorageQueueCanAdmit(buffered,smallBuffered,bufferedJobs,incoming,budget,small);
  BOOL paused=[capacity[@"paused"]boolValue];
  BOOL fault=[capacity[@"storageFault"]boolValue];
  if(!space&&!queue&&!paused&&!fault){
   if(admit&&!admit(&failure))return NO;
   if(waited&&progress)progress(@{@"stage":@"exporting"});return YES;
  }
  // With no room even to begin, wait instead of marking thousands of assets
  // failed in a tight loop. A partially exported oversized asset may be deferred.
  BOOL beforeExport=limitQueue&&incoming==0;
  // Exported files may be waiting for this same copy lane. Do not hold the
  // lane waiting for their reservations, or for another stalled admitted copy.
  if(!beforeExport&&(fault||((space||queue)&&(ownReservation>0||GSExportReservedBytes>0||reserved==0)&&![capacity[@"releasableBytes"]unsignedLongLongValue]))){
   failure=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{NSLocalizedDescriptionKey:GSL(@"Not enough space to prepare this original while keeping free space available."),@"storage":@{@"freeBytes":@(free),@"requiredAdditionalBytes":@(needed),@"reserveBytes":@(GSStorageReserve),@"retainedBytes":@(retained)}}];return NO;
  }
  waiting=@{@"stage":paused?@"waiting_upload_resume":@"waiting_storage",@"freeBytes":@(free),@"bufferedBytes":@(buffered),@"retainedBytes":@(retained),@"reserveBytes":@(GSStorageReserve),@"stagingReservedBytes":@(GSStagingReservedBytes),@"exportCopyReservedBytes":@(GSExportReservedBytes),@"storageFault":@(fault),@"bufferLimitBytes":@(budget)};
  }
  waited=YES;if(progress)progress(waiting);
#if GS_TEST_STORAGE
  [NSThread sleepForTimeInterval:0.001];
#else
  [NSThread sleepForTimeInterval:2];
#endif
 }}
 } @finally {if(error)*error=failure;}
}
static NSArray *GSOriginalResources(PHAsset *asset,NSError **error){
 NSArray *resources=[PHAssetResource assetResourcesForAsset:asset];NSMutableArray *chosen=[NSMutableArray array];
 PHAssetResourceType type=asset.mediaType==PHAssetMediaTypeVideo?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto;
 for(PHAssetResource *r in resources)if(r.type==type){[chosen addObject:r];break;}
 if(asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)for(PHAssetResource *r in resources)if(r.type==PHAssetResourceTypePairedVideo){[chosen addObject:r];break;}
 if(!chosen.count||((asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)&&chosen.count!=2)){
  if(error)*error=[NSError errorWithDomain:@"Gunshot" code:2 userInfo:@{NSLocalizedDescriptionKey:GSL(@"Original media resources are unavailable.")}];return nil;
 }
 return chosen;
}
static NSArray<NSURL *> *GSWriteOriginalResources(PHAsset *asset,NSURL *directory,unsigned long long *reservation,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error,BOOL (^consume)(NSData *,NSError **)){
 if(!consume&&!GSWaitForStorage(directory,64ULL<<20,0,0,YES,asset.mediaType==PHAssetMediaTypeImage,authorization,progress,error,nil))return nil;
 NSArray *chosen=GSOriginalResources(asset,error);if(!chosen)return nil;
 NSMutableArray *files=[NSMutableArray array];
 for(PHAssetResource *r in chosen){
  NSURL *url=[directory URLByAppendingPathComponent:r.originalFilename.lastPathComponent];
  if([NSFileManager.defaultManager fileExistsAtPath:url.path])return nil;
  PHAssetResourceRequestOptions *options=[PHAssetResourceRequestOptions new];options.networkAccessAllowed=YES;
  NSObject *progressLock=[NSObject new];__block NSUInteger cloudUnits=0;__block BOOL progressClosed=NO,dataStarted=NO;
  if(progress)options.progressHandler=^(double fraction){
   if(!isfinite(fraction)||fraction<=0)return;
   NSUInteger units=(NSUInteger)(MIN(1.0,fraction)*1000);
   @synchronized(progressLock){if(!progressClosed&&units>cloudUnits){NSUInteger delta=units-cloudUnits;cloudUnits=units;progress(@{@"cloudProgressDelta":@(delta)});}}
  };
  NSFileHandle *file=nil;
  if(!consume){
   if(![NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:@{NSFilePosixPermissions:@0600}])return nil;
   file=[NSFileHandle fileHandleForWritingAtPath:url.path];if(!file)return nil;
  }
  dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSError *exportError=nil;
  PHAssetResourceManager *manager=PHAssetResourceManager.defaultManager;
  NSLock *requestLock=[NSLock new];__block PHAssetResourceDataRequestID requestID=0;__block BOOL cancelWanted=NO;
  void(^cancel)(void)=^{[requestLock lock];cancelWanted=YES;PHAssetResourceDataRequestID current=requestID;[requestLock unlock];if(current)[manager cancelDataRequest:current];};
  // PhotoKit delivers on a serial queue. Keep only the current callback's bytes
  // and reserve enough free disk for the complete exported asset's queue copy.
  PHAssetResourceDataRequestID started=[manager requestDataForAssetResource:r options:options dataReceivedHandler:^(NSData *data){@autoreleasepool{
   @synchronized(progressLock){if(consume&&!dataStarted&&progress)progress(@{@"streamFirstDataCloudUnits":@(cloudUnits)});dataStarted=YES;}
   if(exportError)return;
   NSUInteger copies=consume?1:2;
   if(!GSWaitForStorage(directory,copies*data.length+(32ULL<<20),0,*reservation,NO,NO,authorization,progress,&exportError,^BOOL(NSError **error){
    // Reserve both the immediate export write and its later queue copy.
    *reservation+=copies*data.length;GSExportReservedBytes+=copies*data.length;return YES;
   })){cancel();return;}
   if(consume?!consume(data,&exportError):![file writeData:data error:&exportError]){cancel();return;}
   @synchronized(GSStorageAdmissionLock()){*reservation-=data.length;GSExportReservedBytes-=data.length;}
   if(progress&&data.length)progress(@{@"exportedBytesDelta":@(data.length)});
  }} completionHandler:^(NSError *e){
   @synchronized(progressLock){progressClosed=YES;}
   if(!exportError)exportError=e;dispatch_semaphore_signal(done);
  }];
  [requestLock lock];requestID=started;BOOL cancelNow=cancelWanted;[requestLock unlock];if(cancelNow)[manager cancelDataRequest:started];
  NSError *cloudSpaceError=nil;
  while(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))!=0){
   // An iCloud request may produce no data for a long time. Cancellation must
   // reach PhotoKit even while no dataReceivedHandler is running.
   if(authorization&&!authorization())cancel();
   // PhotoKit can fill its own full-resource cache before the first callback.
   // Protect physical space and other exports' copy reservations during that wait.
   BOOL awaitingData=NO;@synchronized(progressLock){awaitingData=!dataStarted&&!progressClosed;}
   if(awaitingData&&!cloudSpaceError){
    @synchronized(GSStorageAdmissionLock()){
     unsigned long long free=GSStorageFreeBytes(directory),reserved=GSStagingReservedBytes+GSExportReservedBytes;
     unsigned long long available=free>GSStorageReserve?free-GSStorageReserve:0;
     if(free<GSStorageReserve||reserved>available||(32ULL<<20)>available-MIN(available,reserved))
      cloudSpaceError=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{NSLocalizedDescriptionKey:GSL(@"Not enough space to prepare this original while keeping free space available."),@"storage":@{@"freeBytes":@(free),@"reserveBytes":@(GSStorageReserve),@"reservedBytes":@(reserved),@"stage":@"cloud_download"}}];
    }
    if(cloudSpaceError)cancel();
   }
  }
  [file closeAndReturnError:nil];
  if(cloudSpaceError)exportError=cloudSpaceError;
  if(exportError){if(error)*error=exportError;return nil;}[files addObject:url];
 }
 return files;
}
NSArray<NSURL *> *GSExportAsset(PHAsset *asset,NSURL *directory,NSError **error){
 // Native backup may schedule many assets simultaneously. Keep PhotoKit/cloud
 // resource preparation bounded across native, album, picker and share routes;
 // this does not change the queue's network upload concurrency.
 NSCAssert(!NSThread.isMainThread,@"Export originals on a worker");
 static dispatch_queue_t exports;static dispatch_once_t once;
 dispatch_once(&once,^{exports=dispatch_queue_create("dev.tqmane.gunshot.original-export",DISPATCH_QUEUE_SERIAL);});
 __block NSArray *files=nil;__block NSError *failure=nil;
 dispatch_sync(exports,^{@autoreleasepool{
  unsigned long long reserved=0;
  @try {files=GSWriteOriginalResources(asset,directory,&reserved,nil,nil,&failure,nil);}
  @finally {@synchronized(GSStorageAdmissionLock()){GSExportReservedBytes-=reserved;}}
 }});
 if(error)*error=failure;return files;
}
static NSString *GSStageFiles(NSArray<NSURL *> *files,NSArray *resources,unsigned long long totalSize,unsigned long long *exportReservation,NSString *account,NSString *quality,NSDate *date,NSString *sourceID,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 // The caller's NSError ** is autoreleasing storage. Never write it from the
 // per-chunk pool: draining that pool would free the error before ARC retains
 // it in the caller. Keep failures strongly owned until all chunk pools exit.
 NSError *failure=nil;
 @try {
 NSURL *storage=[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
 NSMutableDictionary *request=[@{@"op":@"begin",@"account":account?:@"",@"quality":quality?:@"original",@"timestamp":@((long long)(date?:NSDate.date).timeIntervalSince1970),@"resources":resources}mutableCopy];
 if(sourceID.length)request[@"sourceID"]=sourceID;
 __block NSDictionary *begin=nil;__block unsigned long long remaining=0;
 if(!GSWaitForStorage(storage,totalSize-MIN(totalSize,*exportReservation),totalSize,*exportReservation,YES,totalSize<=GSStorageSmallFileLimit,authorization,progress,&failure,^BOOL(NSError **admissionError){
  begin=GSRequest(request,admissionError);
  if([begin[@"id"]length]&&![begin[@"duplicate"]boolValue]){
   GSExportReservedBytes-=*exportReservation;*exportReservation=0;
   remaining=totalSize;GSStagingReservedBytes+=remaining;
  }
  return [begin[@"id"]length]>0;
 }))return nil;
 NSString *identifier=begin[@"id"];if(!identifier)return nil;
 if([begin[@"duplicate"]boolValue])return identifier;
 BOOL success=NO;
 @try {
 if(progress)progress(@{@"stage":@"queueing"});
 for(NSUInteger i=0;i<files.count;i++){
  NSFileHandle *f=[NSFileHandle fileHandleForReadingAtPath:files[i].path];if(!f)return nil;
  @try {unsigned long long offset=0,lastSpaceCheck=0;while(YES){@autoreleasepool{
   if(offset==0||offset-lastSpaceCheck>=16ULL<<20){
    if(!GSWaitForStorage(storage,0,0,remaining,NO,NO,authorization,progress,&failure,nil))return nil;
    lastSpaceCheck=offset;
   }
#if GS_JAILED
   NSData *chunk=[f readDataUpToLength:1048576 error:&failure];if(!chunk)return nil;if(!chunk.length)break;
   if(!GSEmbeddedAppend(identifier,i,offset,chunk,&failure))return nil;
#else
   // JSON escapes '/' in base64. A 32 KiB block of 0xff grows beyond
   // GS_MAX_JSON (60 KB); 16 KiB fits even when every character is escaped.
   NSData *chunk=[f readDataUpToLength:16384 error:&failure];if(!chunk)return nil;if(!chunk.length)break;
   if(!GSRequest(@{@"op":@"append",@"id":identifier,@"index":@(i),@"offset":@(offset),@"data":[chunk base64EncodedStringWithOptions:0]},&failure))return nil;
#endif
   offset+=chunk.length;
   @synchronized(GSStorageAdmissionLock()){remaining-=chunk.length;GSStagingReservedBytes-=chunk.length;}
   // Queue copying/hashing can outlast the system's progress deadline for a large original.
   if(progress)progress(@{@"stagedBytesDelta":@(chunk.length)});
  }}} @finally {[f closeAndReturnError:nil];}
 }
 NSDictionary *sealed=GSRequest(@{@"op":@"seal",@"id":identifier},&failure);success=sealed!=nil;return sealed[@"id"];
 } @finally {
  if(!success)GSRequest(@{@"op":@"cancel",@"id":identifier},nil);
  @synchronized(GSStorageAdmissionLock()){GSStagingReservedBytes-=remaining;}
 }
 } @finally {if(error)*error=failure;}
}
static NSString *GSImportFilesWithSource(NSArray<NSURL *> *files,unsigned long long *exportReservation,NSString *account,NSString *quality,NSDate *date,NSString *sourceID,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 NSMutableArray *resources=[NSMutableArray array];unsigned long long totalSize=0;
 for(NSURL *url in files){NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];if(!attrs||![attrs[NSFileType]isEqual:NSFileTypeRegular])return nil;totalSize+=[attrs[NSFileSize]unsignedLongLongValue];[resources addObject:@{@"name":url.lastPathComponent,@"size":attrs[NSFileSize]}];}
 static dispatch_queue_t small,large;static dispatch_once_t once;
 dispatch_once(&once,^{small=dispatch_queue_create("dev.tqmane.gunshot.stage-small",DISPATCH_QUEUE_SERIAL);large=dispatch_queue_create("dev.tqmane.gunshot.stage-large",DISPATCH_QUEUE_SERIAL);});
 __block NSString *job=nil;__block NSError *failure=nil;
 dispatch_sync(totalSize<=GSStorageSmallFileLimit?small:large,^{job=GSStageFiles(files,resources,totalSize,exportReservation,account,quality,date,sourceID,authorization,progress,&failure);});
 if(error)*error=failure;return job;
}
NSString *GSImportFiles(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,NSError **error){
 unsigned long long reserved=0;return GSImportFilesWithSource(files,&reserved,account,quality,date,nil,nil,nil,error);
}
NSString *GSImportFilesWithProgress(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 unsigned long long reserved=0;return GSImportFilesWithSource(files,&reserved,account,quality,date,nil,authorization,progress,error);
}
NSString *GSImportPhotoIdentifier(NSString *localIdentifier,NSString *account,NSString *quality,NSError **error){
 return GSImportPhotoIdentifierChecked(localIdentifier,account,quality,nil,error);
}
NSString *GSImportPhotoIdentifierChecked(NSString *localIdentifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,NSError **error){
 return GSImportPhotoIdentifierWithProgress(localIdentifier,account,quality,authorization,nil,error);
}
static NSString *GSImportStream(PHAsset *asset,NSURL *directory,NSString *account,NSString *quality,NSString *sourceID,BOOL resuming,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 NSError *failure=nil;unsigned long long reserved=0;NSString *identifier=nil;BOOL sealed=NO;
 @try {
  NSArray *resources=GSOriginalResources(asset,&failure);if(resources.count!=1)return nil;
  PHAssetResource *resource=resources.firstObject;
  if(!GSWaitForStorage(directory,64ULL<<20,0,0,!resuming,asset.mediaType==PHAssetMediaTypeImage,authorization,progress,&failure,nil))return nil;
  NSDictionary *begin=GSRequest(@{@"op":@"begin",@"streaming":@YES,@"account":account,@"quality":quality?:@"original",@"sourceID":sourceID,@"timestamp":@((long long)(asset.creationDate?:NSDate.date).timeIntervalSince1970),@"resources":@[@{@"name":resource.originalFilename.lastPathComponent,@"size":@0}]},&failure);
  identifier=begin[@"id"];if(!identifier)return nil;
  if([begin[@"duplicate"]boolValue]){sealed=YES;return identifier;}
  __block unsigned long long offset=0;
  __block NSNumber *cloudAtFirstData=nil;
  GSImportStorageProgress streamProgress=^(NSDictionary *event){
   if(event[@"streamFirstDataCloudUnits"])cloudAtFirstData=event[@"streamFirstDataCloudUnits"];
   if(progress)progress(event);
  };
  if(progress)progress(@{@"streamJob":identifier,@"stage":@"streaming"});
  NSArray *read=GSWriteOriginalResources(asset,directory,&reserved,authorization,streamProgress,&failure,^BOOL(NSData *data,NSError **appendError){
   NSError *chunkError=nil;
   @try {
   for(NSUInteger start=0;start<data.length;){@autoreleasepool{
#if GS_JAILED
    NSUInteger length=MIN((NSUInteger)1048576,data.length-start);
    NSData *chunk=[data subdataWithRange:NSMakeRange(start,length)];
    if(!GSEmbeddedAppend(identifier,0,offset,chunk,&chunkError))return NO;
#else
    NSUInteger length=MIN((NSUInteger)16384,data.length-start);
    NSData *chunk=[data subdataWithRange:NSMakeRange(start,length)];
    if(!GSRequest(@{@"op":@"append",@"id":identifier,@"index":@0,@"offset":@(offset),@"data":[chunk base64EncodedStringWithOptions:0]},&chunkError))return NO;
#endif
    start+=length;offset+=length;
    if(progress)progress(@{@"stagedBytesDelta":@(length)});
   }}return YES;
   } @finally {if(appendError)*appendError=chunkError;}
  });
  if(!read)return nil;
  if(authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return nil;}
  NSMutableDictionary *seal=[@{@"op":@"seal",@"id":identifier}mutableCopy];
  if(cloudAtFirstData)seal[@"cloudAtFirstData"]=cloudAtFirstData;
  NSDictionary *result=GSRequest(seal,&failure);sealed=result!=nil;
  return result[@"id"];
 } @finally {
  if(identifier&&!sealed){
   // Free a space-blocking partial; other interruptions retain the verified
   // prefix and server checkpoint for replay when this source is selected again.
   BOOL space=[failure.domain isEqual:NSCocoaErrorDomain]&&failure.code==NSFileWriteOutOfSpaceError;
   GSRequest(@{@"op":space?@"cancel":@"stream_suspend",@"id":identifier},nil);
  }
  @synchronized(GSStorageAdmissionLock()){GSExportReservedBytes-=reserved;}
  if(error)*error=failure;
 }
}
NSString *GSImportPhotoIdentifierWithProgress(NSString *localIdentifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 if(!localIdentifier.length||!account.length){if(error)*error=[NSError errorWithDomain:@"Gunshot" code:3 userInfo:nil];return nil;}
 // Reserve any free lane. Hashing sources into fixed lanes strands idle workers
 // behind an unrelated large iCloud video. Equal sources still cannot overlap.
 static dispatch_queue_t imports[GS_IMPORT_LANES];static dispatch_once_t once;
 static NSCondition *lanes;static NSMutableIndexSet *available;static NSMutableSet *sources;
 dispatch_once(&once,^{
  for(NSUInteger i=0;i<GS_IMPORT_LANES;i++)imports[i]=dispatch_queue_create("dev.tqmane.gunshot.asset-import",DISPATCH_QUEUE_SERIAL);
  lanes=[NSCondition new];available=[NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0,GS_IMPORT_LANES)];sources=[NSMutableSet set];
 });
 [lanes lock];
 while(!available.count||[sources containsObject:localIdentifier])[lanes wait];
 NSUInteger lane=available.firstIndex;[available removeIndex:lane];[sources addObject:localIdentifier];[lanes unlock];
 __block NSString *job=nil;__block NSError *failure=nil;
 @try {dispatch_sync(imports[lane],^{@autoreleasepool{
  if(authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return;}
  NSDictionary *existing=GSRequest(@{@"op":@"source_lookup",@"account":account,@"quality":quality?:@"original",@"sourceID":localIdentifier},&failure);
  BOOL resuming=[existing[@"resumeImport"]boolValue];
  if(existing&&[existing[@"found"]boolValue]&&!resuming){
   if(authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return;}
   if([existing[@"state"]isEqual:@"failed"]){
    if([existing[@"retryable"]boolValue]){
     if(!GSRequest(@{@"op":@"retry",@"id":existing[@"id"]?:@""},&failure))return;
    }else{failure=[NSError errorWithDomain:@"Gunshot.DuplicateSafety" code:1 userInfo:nil];return;}
   }
   job=[existing[@"id"]copy];
   return;
  }
  if(failure)return;
  PHFetchResult *found=[PHAsset fetchAssetsWithLocalIdentifiers:@[localIdentifier] options:nil];
  __block PHAsset *asset=nil;
  [found enumerateObjectsUsingBlock:^(PHAsset *candidate,NSUInteger i,BOOL *stop){asset=candidate;*stop=YES;}];
  if(!asset){failure=[NSError errorWithDomain:@"Gunshot" code:4 userInfo:nil];return;}
  NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
  if(![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&failure])return;
  unsigned long long reserved=0;
  @try {
   NSDictionary *capacity=GSRequest(@{@"op":@"ping"},&failure);if(!capacity)return;
   if([capacity[@"streamingImport"]boolValue]&&!(asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)){
    job=GSImportStream(asset,directory,account,quality,localIdentifier,resuming,authorization,progress,&failure);return;
   }
   // asset was resolved on dev.tqmane.gunshot.asset-import. Keep every PhotoKit
   // operation that touches it on this same serial queue; only immutable identifiers
   // may cross queues. GSExportAsset remains for callers that already own an asset.
   NSArray *files=GSWriteOriginalResources(asset,directory,&reserved,authorization,progress,&failure,nil);
   if(files&&authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return;}
   // Small and large copies have separate lanes; admission reserves disk atomically.
   NSDate *date=[asset.creationDate copy];
   if(files)job=GSImportFilesWithSource(files,&reserved,account,quality,date,localIdentifier,authorization,progress,&failure);
  } @finally {
   [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
   @synchronized(GSStorageAdmissionLock()){GSExportReservedBytes-=reserved;}
  }
 }});} @finally {
  [lanes lock];[sources removeObject:localIdentifier];[available addIndex:lane];[lanes broadcast];[lanes unlock];
 }
 if(error)*error=failure;return job;
}
