#import "../Shared/GSLocalization.h"
#import "GSExporter.h"
#import "../Shared/IPCProtocol.h"
#import "GSImportStorage.h"

static BOOL GSWaitForStorage(NSURL *directory,unsigned long long needed,unsigned long long incoming,BOOL limitQueue,
 GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 BOOL waited=NO;NSError *failure=nil;
 @try {
 while(YES){@autoreleasepool{
  if(authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return NO;}
  NSDictionary *capacity=GSRequest(@{@"op":@"import_capacity"},&failure);if(!capacity)return NO;
  unsigned long long free=GSStorageFreeBytes(directory),retained=[capacity[@"retainedBytes"]unsignedLongLongValue];
  unsigned long long buffered=[(capacity[@"bufferedBytes"]?:capacity[@"retainedBytes"])unsignedLongLongValue];
  NSUInteger bufferedJobs=[(capacity[@"bufferedJobs"]?:capacity[@"retainedJobs"])unsignedIntegerValue];
  BOOL space=free<GSStorageReserve||needed>free-GSStorageReserve;
  BOOL queue=limitQueue&&GSStorageQueueFull(buffered,bufferedJobs,incoming);
  // Allow one oversized asset when only small, unresolved failures remain.
  if(incoming>GSStorageQueueLimit&&buffered<GSStorageQueueLimit&&![capacity[@"releasableBytes"]unsignedLongLongValue])queue=NO;
  BOOL paused=[capacity[@"paused"]boolValue];
  if(!space&&!queue&&!paused){if(waited&&progress)progress(@{@"stage":@"exporting"});return YES;}
  // With no room even to begin, wait instead of marking thousands of assets
  // failed in a tight loop. A partially exported oversized asset may be deferred.
  BOOL beforeExport=limitQueue&&incoming==0;
  if((space||queue)&&!beforeExport&&![capacity[@"releasableBytes"]unsignedLongLongValue]){
   failure=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{NSLocalizedDescriptionKey:GSL(@"Not enough space to prepare this original while keeping free space available."),@"storage":@{@"freeBytes":@(free),@"requiredAdditionalBytes":@(needed),@"reserveBytes":@(GSStorageReserve),@"retainedBytes":@(retained)}}];return NO;
  }
  waited=YES;
  if(progress)progress(@{@"stage":paused?@"waiting_upload_resume":@"waiting_storage",@"freeBytes":@(free),@"bufferedBytes":@(buffered),@"retainedBytes":@(retained),@"reserveBytes":@(GSStorageReserve),@"bufferLimitBytes":@(GSStorageQueueLimit)});
#if GS_TEST_STORAGE
  [NSThread sleepForTimeInterval:0.001];
#else
  [NSThread sleepForTimeInterval:2];
#endif
 }}
 } @finally {if(error)*error=failure;}
}
static NSArray<NSURL *> *GSWriteOriginalResources(PHAsset *asset,NSURL *directory,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 if(!GSWaitForStorage(directory,64ULL<<20,0,YES,authorization,progress,error))return nil;
 NSArray *resources=[PHAssetResource assetResourcesForAsset:asset];NSMutableArray *chosen=[NSMutableArray array];
 PHAssetResourceType type=asset.mediaType==PHAssetMediaTypeVideo?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto;
 for(PHAssetResource *r in resources)if(r.type==type){[chosen addObject:r];break;}
 if(asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)for(PHAssetResource *r in resources)if(r.type==PHAssetResourceTypePairedVideo){[chosen addObject:r];break;}
 if(!chosen.count||((asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)&&chosen.count!=2)){
  if(error)*error=[NSError errorWithDomain:@"Gunshot" code:2 userInfo:@{NSLocalizedDescriptionKey:GSL(@"Original media resources are unavailable.")}];return nil;
 }
 NSMutableArray *files=[NSMutableArray array];__block unsigned long long exported=0,lastSpaceCheck=0;__block NSTimeInterval lastSpaceTime=0;
 for(PHAssetResource *r in chosen){
  NSURL *url=[directory URLByAppendingPathComponent:r.originalFilename.lastPathComponent];
  if([NSFileManager.defaultManager fileExistsAtPath:url.path])return nil;
  PHAssetResourceRequestOptions *options=[PHAssetResourceRequestOptions new];options.networkAccessAllowed=YES;
  if(![NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:@{NSFilePosixPermissions:@0600}])return nil;
  NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:url.path];if(!file)return nil;
  dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSError *exportError=nil;
  PHAssetResourceManager *manager=PHAssetResourceManager.defaultManager;
  NSLock *requestLock=[NSLock new];__block PHAssetResourceDataRequestID requestID=0;__block BOOL cancelWanted=NO;
  void(^cancel)(void)=^{[requestLock lock];cancelWanted=YES;PHAssetResourceDataRequestID current=requestID;[requestLock unlock];if(current)[manager cancelDataRequest:current];};
  // PhotoKit delivers on a serial queue. Keep only the current callback's bytes
  // and reserve enough free disk for the complete exported asset's queue copy.
  PHAssetResourceDataRequestID started=[manager requestDataForAssetResource:r options:options dataReceivedHandler:^(NSData *data){@autoreleasepool{
   if(exportError)return;
   NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
   if(exported==0||exported-lastSpaceCheck>=16ULL<<20||now-lastSpaceTime>=1){
    if(!GSWaitForStorage(directory,exported+2*data.length+(32ULL<<20),0,NO,authorization,progress,&exportError)){cancel();return;}
    lastSpaceCheck=exported;lastSpaceTime=now;
   }
   if(![file writeData:data error:&exportError]){cancel();return;}
   exported+=data.length;
  }} completionHandler:^(NSError *e){if(!exportError)exportError=e;dispatch_semaphore_signal(done);}];
  [requestLock lock];requestID=started;BOOL cancelNow=cancelWanted;[requestLock unlock];if(cancelNow)[manager cancelDataRequest:started];
  dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
  [file closeAndReturnError:nil];
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
 dispatch_sync(exports,^{@autoreleasepool{files=GSWriteOriginalResources(asset,directory,nil,nil,&failure);}});
 if(error)*error=failure;return files;
}
static NSString *GSImportFilesWithSource(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,NSString *sourceID,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 // The caller's NSError ** is autoreleasing storage. Never write it from the
 // per-chunk pool: draining that pool would free the error before ARC retains
 // it in the caller. Keep failures strongly owned until all chunk pools exit.
 NSError *failure=nil;
 @try {
 NSMutableArray *resources=[NSMutableArray array];
 unsigned long long totalSize=0;
 for(NSURL *u in files){NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:u.path error:&failure];if(!attrs||![attrs[NSFileType]isEqual:NSFileTypeRegular])return nil;totalSize+=[attrs[NSFileSize]unsignedLongLongValue];[resources addObject:@{@"name":u.lastPathComponent,@"size":attrs[NSFileSize]}];}
 NSURL *storage=[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
 if(!GSWaitForStorage(storage,totalSize,totalSize,YES,authorization,progress,&failure))return nil;
 if(progress)progress(@{@"stage":@"queueing"});
 NSMutableDictionary *request=[@{@"op":@"begin",@"account":account?:@"",@"quality":quality?:@"original",@"timestamp":@((long long)(date?:NSDate.date).timeIntervalSince1970),@"resources":resources}mutableCopy];
 if(sourceID.length)request[@"sourceID"]=sourceID;
 NSDictionary *begin=GSRequest(request,&failure);
 NSString *identifier=begin[@"id"];if(!identifier)return nil;
 if([begin[@"duplicate"]boolValue])return identifier;
 BOOL success=NO;
 @try {
 for(NSUInteger i=0;i<files.count;i++){
  NSFileHandle *f=[NSFileHandle fileHandleForReadingAtPath:files[i].path];if(!f)return nil;
  @try {unsigned long long offset=0,lastSpaceCheck=0;while(YES){@autoreleasepool{
   if(offset==0||offset-lastSpaceCheck>=16ULL<<20){
    if(!GSWaitForStorage(storage,16ULL<<20,0,NO,authorization,progress,&failure))return nil;
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
  }}} @finally {[f closeAndReturnError:nil];}
 }
 NSDictionary *sealed=GSRequest(@{@"op":@"seal",@"id":identifier},&failure);success=sealed!=nil;return sealed[@"id"];
 } @finally {if(!success)GSRequest(@{@"op":@"cancel",@"id":identifier},nil);}
 } @finally {if(error)*error=failure;}
}
NSString *GSImportFiles(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,NSError **error){
 return GSImportFilesWithSource(files,account,quality,date,nil,nil,nil,error);
}
NSString *GSImportFilesWithProgress(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 return GSImportFilesWithSource(files,account,quality,date,nil,authorization,progress,error);
}
NSString *GSImportPhotoIdentifier(NSString *localIdentifier,NSString *account,NSString *quality,NSError **error){
 return GSImportPhotoIdentifierChecked(localIdentifier,account,quality,nil,error);
}
NSString *GSImportPhotoIdentifierChecked(NSString *localIdentifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,NSError **error){
 return GSImportPhotoIdentifierWithProgress(localIdentifier,account,quality,authorization,nil,error);
}
NSString *GSImportPhotoIdentifierWithProgress(NSString *localIdentifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 if(!localIdentifier.length||!account.length){if(error)*error=[NSError errorWithDomain:@"Gunshot" code:3 userInfo:nil];return nil;}
 // One transaction queue spans source lookup -> PhotoKit export -> queue begin.
 // This prevents two native callbacks for the same asset from both scanning and staging it.
 static dispatch_queue_t imports;static dispatch_once_t once;
 dispatch_once(&once,^{imports=dispatch_queue_create("dev.tqmane.gunshot.asset-import",DISPATCH_QUEUE_SERIAL);});
 __block NSString *job=nil;__block NSError *failure=nil;
 dispatch_sync(imports,^{@autoreleasepool{
  if(authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return;}
  NSDictionary *existing=GSRequest(@{@"op":@"source_lookup",@"account":account,@"quality":quality?:@"original",@"sourceID":localIdentifier},&failure);
  if(existing&&[existing[@"found"]boolValue]){
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
  @try {
   // asset was resolved on dev.tqmane.gunshot.asset-import. Keep every PhotoKit
   // operation that touches it on this same serial queue; only immutable identifiers
   // may cross queues. GSExportAsset remains for callers that already own an asset.
   NSArray *files=GSWriteOriginalResources(asset,directory,authorization,progress,&failure);
   if(files&&authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return;}
   if(files)job=GSImportFilesWithSource(files,account,quality,asset.creationDate,localIdentifier,authorization,progress,&failure);
  } @finally {[NSFileManager.defaultManager removeItemAtURL:directory error:nil];}
 }});
 if(error)*error=failure;return job;
}
