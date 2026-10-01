#import "GSBatchImport.h"
#import "GSExporter.h"
#import "GSNativeAccount.h"
#import "../Shared/IPCProtocol.h"

@interface GSImportBatch : NSObject
@property(atomic,copy) NSString *stopReason;
@property(nonatomic,copy) NSString *account;
@property(nonatomic,copy) NSString *identity;
@end
@implementation GSImportBatch @end
static GSImportBatch *GSCurrentBatch;
static NSDictionary *GSLastBatch;
static dispatch_queue_t GSBatchQueue;

NSDictionary *GSBatchImportSnapshot(void){
 @synchronized(GSImportBatch.class){return GSLastBatch?:@{@"active":@NO};}
}
void GSStopBatchImport(BOOL backgroundExpired){
 @synchronized(GSImportBatch.class){GSCurrentBatch.stopReason=backgroundExpired?@"background_expired":@"cancelled";}
}
static void GSRecordBatch(NSDictionary *snapshot){@synchronized(GSImportBatch.class){GSLastBatch=[snapshot copy];}}
static void GSRecordPreparation(NSMutableDictionary *state,NSDictionary *event){
 for(NSString *key in event){
  NSString *counter=[key isEqual:@"exportedBytesDelta"]?@"exportedBytes":[key isEqual:@"cloudProgressDelta"]?@"cloudProgressUnits":[key isEqual:@"stagedBytesDelta"]?@"stagedBytes":[key isEqual:@"sourceReadBytesDelta"]?@"sourceReadBytes":nil;
  if(counter)state[counter]=@([state[counter]unsignedLongLongValue]+[event[key]unsignedLongLongValue]);
  else state[key]=event[key];
 }
 GSRecordBatch(state);
}
static NSString *GSCheckBatchAccount(GSImportBatch *batch){
 if(batch.stopReason)return batch.stopReason;
 if(batch.identity){
  __block BOOL valid=NO;
  dispatch_sync(dispatch_get_main_queue(),^{valid=GSNativeIdentityMatches(batch.identity);});
  if(!valid)return @"account_changed";
 }
 NSDictionary *accounts=GSRequest(@{@"op":@"accounts"},nil);
 if(!accounts)return @"service_unavailable";
 return [accounts[@"selected"]isEqual:batch.account]?nil:@"account_changed";
}
static NSString *GSPreparePhotos(GSImportBatch *batch,NSUInteger count,NSUInteger workers,NSUInteger videoWorkers,
 GSBatchItemProvider provider,NSString *quality,NSMutableDictionary *state,GSBatchProgress progress){
 // Classify bounded metadata pages on this queue; only identifiers enter workers.
 NSMutableArray *photos=[NSMutableArray array],*videos=[NSMutableArray array],*rangeVideos=[NSMutableArray array];
 state[@"stage"]=@"scanning";GSRecordBatch(state);
 for(NSUInteger base=0;base<count;base+=256){@autoreleasepool{
  NSString *reason=GSCheckBatchAccount(batch);if(reason)return reason;
  NSMutableArray *items=[NSMutableArray array],*ids=[NSMutableArray array];
  for(NSUInteger i=base;i<MIN(count,base+256);i++){
   id item=provider(i)?:NSNull.null;[items addObject:item];
   if([item isKindOfClass:NSString.class]&&[item length])[ids addObject:item];
  }
  NSMutableSet *videoIDs=[NSMutableSet set],*rangeIDs=[NSMutableSet set];
  if(ids.count){
   PHFetchResult *found=[PHAsset fetchAssetsWithLocalIdentifiers:ids options:nil];
   [found enumerateObjectsUsingBlock:^(PHAsset *asset,NSUInteger i,BOOL *stop){
    if(asset.mediaType==PHAssetMediaTypeVideo&&asset.localIdentifier){
     [videoIDs addObject:asset.localIdentifier];
     if(GSPhotoAssetSupportsBoundedRanges(asset))[rangeIDs addObject:asset.localIdentifier];
    }
   }];
  }
  for(id item in items){NSMutableArray *target=[rangeIDs containsObject:item]?rangeVideos:[videoIDs containsObject:item]?videos:photos;[target addObject:item];}
  GSRecordPreparation(state,@{@"scannedItems":@(MIN(count,base+256))});
 }}
 NSObject *lock=[NSObject new];
 __block NSTimeInterval lastUpdate=0;
 NSMutableDictionary *failures=[NSMutableDictionary dictionary];
 state[@"preparationWorkers"]=@(workers);
 state[@"videoPreparationWorkers"]=@(videoWorkers);
 // Retry deferred originals after the other exports release their reservations.
 // Three passes bound repeated iCloud downloads when an original cannot fit.
 for(NSUInteger pass=0;pass<3;pass++){
 __block NSUInteger nextPhoto=0,nextVideo=0,nextRange=0,active=0,activeLegacy=0;
 NSMutableArray *deferredPhotos=[NSMutableArray array],*deferredVideos=[NSMutableArray array],*deferredRanges=[NSMutableArray array];
 if(pass){
  state[@"storageRetryPass"]=@(pass);state[@"stage"]=@"waiting_storage";GSRecordBatch(state);
  for(NSUInteger tick=0;tick<10;tick++){
   NSString *reason=GSCheckBatchAccount(batch);if(reason)return reason;
   [NSThread sleepForTimeInterval:0.2];
  }
 }
 dispatch_group_t group=dispatch_group_create();
 for(NSUInteger worker=0;worker<workers;worker++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  while(YES){@autoreleasepool{
   id item=nil;BOOL video=NO,range=NO;
   @synchronized(lock){
    if(batch.stopReason)break;
    // Full-resource PhotoKit reads stay serial. Bounded cloud ranges can use
    // additional video workers while the remaining workers prepare photos.
    if(worker<videoWorkers){
     if(nextVideo<videos.count&&!activeLegacy){item=videos[nextVideo++];video=YES;activeLegacy++;}
     else if(nextRange<rangeVideos.count){item=rangeVideos[nextRange++];video=YES;range=YES;}
    }
    if(!item){if(nextPhoto>=photos.count)break;item=photos[nextPhoto++];}
    active++;state[@"activePreparations"]=@(active);
    state[@"stage"]=@"exporting";GSRecordBatch(state);
   }
   NSString *reason=GSCheckBatchAccount(batch);NSError *error=nil;NSString *job=nil;
   for(NSUInteger attempt=0;attempt<3&&!reason&&[item isKindOfClass:NSString.class];attempt++){
    error=nil;job=GSImportPhotoIdentifierWithProgress(item,batch.account,quality,
    ^BOOL{return GSCheckBatchAccount(batch)==nil;},^(NSDictionary *storage){
     @synchronized(lock){GSRecordPreparation(state,storage);}
    },&error);
    if(job||![error.domain isEqual:@"Gunshot.IPC"])break;
    reason=GSCheckBatchAccount(batch);
    if(!reason)[NSThread sleepForTimeInterval:0.2*(attempt+1)];
   }
   if(!reason)reason=GSCheckBatchAccount(batch);
   @synchronized(lock){
    active--;if(video&&!range)activeLegacy--;state[@"activePreparations"]=@(active);
    if(reason){if(!batch.stopReason)batch.stopReason=reason;}
    // Repeated failure isolated to this asset is recorded and remains retryable.
    // Account/service failures above still stop the batch, rather than skipping
    // the rest of the library when the service is unavailable.
    else {
     BOOL space=!job&&[error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSFileWriteOutOfSpaceError;
     if(space){
      [(range?deferredRanges:video?deferredVideos:deferredPhotos)addObject:item];
      if(!pass)state[@"storageDeferred"]=@([state[@"storageDeferred"]unsignedIntegerValue]+1);
      state[@"lastStorageFailure"]=error.userInfo[@"storage"]?:@{};
     }else{
      if(pass)state[@"storageDeferred"]=@([state[@"storageDeferred"]unsignedIntegerValue]-1);
      state[@"processed"]=@([state[@"processed"]unsignedIntegerValue]+1);
      NSString *key=job?@"queued":@"failed";state[key]=@([state[key]unsignedIntegerValue]+1);
      if(!job){
       NSString *code=item==NSNull.null?@"inaccessible":[error.domain isEqual:@"Gunshot.DuplicateSafety"]?@"commit_outcome_unknown":[error.domain isEqual:@"Gunshot.IPC"]?@"queue_rejected":@"export_failed";
       failures[code]=@([failures[code]unsignedIntegerValue]+1);
      }
     }
    }
    state[@"remaining"]=@(count-[state[@"processed"]unsignedIntegerValue]);state[@"failureCodes"]=[failures copy];
    GSRecordBatch(state);
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(progress&&now-lastUpdate>=0.25){lastUpdate=now;NSDictionary *snapshot=[state copy];dispatch_async(dispatch_get_main_queue(),^{progress(snapshot);});}
   }
  }}
 });
 dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
 if(batch.stopReason)return batch.stopReason;
 if(!deferredPhotos.count&&!deferredVideos.count&&!deferredRanges.count)return nil;
 photos=deferredPhotos;videos=deferredVideos;rangeVideos=deferredRanges;
 }
 if([state[@"storageDeferred"]unsignedIntegerValue])return @"storage_deferred";
 return batch.stopReason;
}
BOOL GSStartBatchImport(NSUInteger count,NSString *source,BOOL assets,GSBatchItemProvider provider,
 NSString *account,NSString *identity,GSBatchProgress progress,GSBatchProgress completion){
 NSCAssert(NSThread.isMainThread,@"Start import on main");
 if(!count||!provider||!account.length)return NO;
 GSImportBatch *batch=[GSImportBatch new];batch.account=[account copy];batch.identity=[identity copy];
 source=source&&[@[@"picker",@"album",@"share"]containsObject:source]?source:@"share";
 NSMutableDictionary *state=[@{@"active":@YES,@"source":source,@"total":@(count),@"processed":@0,@"queued":@0,@"failed":@0,@"remaining":@(count),@"stage":@"starting"}mutableCopy];
 @synchronized(GSImportBatch.class){
  if(GSCurrentBatch)return NO;
  GSCurrentBatch=batch;GSLastBatch=[state copy];
  if(!GSBatchQueue)GSBatchQueue=dispatch_queue_create("dev.tqmane.gunshot.batch-import",DISPATCH_QUEUE_SERIAL);
 }
 dispatch_async(GSBatchQueue,^{@autoreleasepool{
  NSString *reason=GSCheckBatchAccount(batch);
  NSDictionary *options=reason?nil:GSRequest(@{@"op":@"options"},nil);
  if(!reason&&!options)reason=@"service_unavailable";
  NSString *quality=options[@"quality"]?:@"original";
  NSUInteger processed=0,queued=0,failed=0;
  NSMutableDictionary *failures=[NSMutableDictionary dictionary];
  NSTimeInterval lastUpdate=0;
  if(assets&&!reason){
   // Preparation must outpace uploads: 1.5 workers per upload slot, at least 4.
   NSUInteger concurrent=MAX((NSUInteger)1,[options[@"concurrent"]unsignedIntegerValue]);
   NSUInteger workers=MIN(count,MIN((NSUInteger)GS_IMPORT_LANES,MAX((NSUInteger)4,concurrent+concurrent/2)));
   NSUInteger videoWorkers=MIN(workers,MAX((NSUInteger)1,MIN((NSUInteger)4,concurrent/2)));
   reason=GSPreparePhotos(batch,count,workers,videoWorkers,provider,quality,state,progress);
  }
  for(NSUInteger index=0;!assets&&index<count&&!reason;index++){@autoreleasepool{
   reason=GSCheckBatchAccount(batch);if(reason)break;
   state[@"stage"]=@"exporting";GSRecordBatch(state);
   id item=provider(index);NSError *error=nil;
   if(!item){processed++;failed++;failures[@"inaccessible"]=@([failures[@"inaccessible"]unsignedIntegerValue]+1);}
   else if(assets){
    // Providers deliberately carry only immutable localIdentifier strings.
    // PHAsset/PHFetchResult objects never survive across our dispatch queues.
    NSString *job=[item isKindOfClass:NSString.class]?GSImportPhotoIdentifierWithProgress(item,batch.account,quality,^BOOL{
     return GSCheckBatchAccount(batch)==nil;
    },^(NSDictionary *storage){
     GSRecordPreparation(state,storage);
     if(progress){NSDictionary *snapshot=[state copy];dispatch_async(dispatch_get_main_queue(),^{progress(snapshot);});}
    },&error):nil;
    if(!reason)reason=GSCheckBatchAccount(batch);
    if(!reason&&job){processed++;queued++;}
    else if(!reason){
     if([error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSFileWriteOutOfSpaceError){
      // The exporter has removed this asset's partial files. A large original
      // must not prevent smaller remaining photos from being processed.
      processed++;failed++;failures[@"storage_deferred"]=@([failures[@"storage_deferred"]unsignedIntegerValue]+1);
      state[@"storageDeferred"]=failures[@"storage_deferred"];
      state[@"lastStorageFailure"]=error.userInfo[@"storage"]?:@{};
     }
     else if([error.domain isEqual:@"Gunshot.IPC"])reason=@"queue_rejected";
     else {processed++;failed++;failures[@"export_failed"]=@([failures[@"export_failed"]unsignedIntegerValue]+1);}
    }
   }else{
    NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    BOOL created=[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
    NSArray *files=nil;NSDate *date=nil;BOOL scoped=NO;
    if(!created)reason=@"local_storage";
    else {NSURL *url=item;scoped=[url startAccessingSecurityScopedResource];NSDictionary *attr=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];if(attr){files=@[url];date=attr[NSFileModificationDate];}}
    if(!reason)reason=GSCheckBatchAccount(batch); // Cloud export may outlive sign-in or cancellation.
    if(!reason&&!files){
     if([error.domain isEqual:NSCocoaErrorDomain]&&error.code==NSFileWriteOutOfSpaceError)reason=@"local_storage";
     else {processed++;failed++;failures[@"export_failed"]=@([failures[@"export_failed"]unsignedIntegerValue]+1);}
    }
    if(!reason&&files){
     state[@"stage"]=@"queueing";GSRecordBatch(state);
     NSString *job=GSImportFilesWithProgress(files,batch.account,quality,date,^BOOL{return GSCheckBatchAccount(batch)==nil;},^(NSDictionary *storage){
      GSRecordPreparation(state,storage);
      if(progress){NSDictionary *snapshot=[state copy];dispatch_async(dispatch_get_main_queue(),^{progress(snapshot);});}
     },&error);
     if(!reason)reason=GSCheckBatchAccount(batch);
     if(!reason&&job){processed++;queued++;}else if(!reason)reason=@"queue_rejected";
    }
    if(scoped)[item stopAccessingSecurityScopedResource];
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
   }
   state[@"processed"]=@(processed);state[@"queued"]=@(queued);state[@"failed"]=@(failed);state[@"remaining"]=@(count-processed);state[@"failureCodes"]=[failures copy];GSRecordBatch(state);
   NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
   if(progress&&now-lastUpdate>=0.25){lastUpdate=now;NSDictionary *snapshot=[state copy];dispatch_async(dispatch_get_main_queue(),^{progress(snapshot);});}
  }}
  state[@"active"]=@NO;state[@"stage"]=reason?@"stopped":@"finished";
  if(reason)state[@"stopReason"]=reason;
  NSDictionary *final=[state copy];
  // Release the reservation before notifying UI, allowing an explicit retry.
  @synchronized(GSImportBatch.class){GSLastBatch=final;GSCurrentBatch=nil;}
  if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(final);});
 }});
 return YES;
}
GSBatchItemProvider GSPhotoIdentifierProvider(NSArray *identifiers){
 NSArray *selection=[identifiers copy];
 return ^id(NSUInteger index){
  if(index>=selection.count)return nil;
  id value=selection[index];return [value isKindOfClass:NSString.class]&&[value length]?[value copy]:nil;
 };
}
