#import "../Shared/GSLocalization.h"
#import "GSExporter.h"
#import "../Shared/IPCProtocol.h"
static NSArray<NSURL *> *GSWriteOriginalResources(PHAsset *asset,NSURL *directory,NSError **error){
 NSArray *resources=[PHAssetResource assetResourcesForAsset:asset];NSMutableArray *chosen=[NSMutableArray array];
 PHAssetResourceType type=asset.mediaType==PHAssetMediaTypeVideo?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto;
 for(PHAssetResource *r in resources)if(r.type==type){[chosen addObject:r];break;}
 if(asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)for(PHAssetResource *r in resources)if(r.type==PHAssetResourceTypePairedVideo){[chosen addObject:r];break;}
 if(!chosen.count||((asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive)&&chosen.count!=2)){
  if(error)*error=[NSError errorWithDomain:@"Gunshot" code:2 userInfo:@{NSLocalizedDescriptionKey:GSL(@"Original media resources are unavailable.")}];return nil;
 }
 NSMutableArray *files=[NSMutableArray array];
 for(PHAssetResource *r in chosen){
  NSURL *url=[directory URLByAppendingPathComponent:r.originalFilename.lastPathComponent];
  if([NSFileManager.defaultManager fileExistsAtPath:url.path])return nil;
  PHAssetResourceRequestOptions *options=[PHAssetResourceRequestOptions new];options.networkAccessAllowed=YES;
  dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSError *exportError=nil;
  [PHAssetResourceManager.defaultManager writeDataForAssetResource:r toFile:url options:options completionHandler:^(NSError *e){exportError=e;dispatch_semaphore_signal(done);}];
  dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
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
 dispatch_sync(exports,^{@autoreleasepool{files=GSWriteOriginalResources(asset,directory,&failure);}});
 if(error)*error=failure;return files;
}
static NSString *GSImportFilesWithSource(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,NSString *sourceID,NSError **error){
 // The caller's NSError ** is autoreleasing storage. Never write it from the
 // per-chunk pool: draining that pool would free the error before ARC retains
 // it in the caller. Keep failures strongly owned until all chunk pools exit.
 NSError *failure=nil;
 @try {
 NSMutableArray *resources=[NSMutableArray array];
 for(NSURL *u in files){NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:u.path error:&failure];if(!attrs||![attrs[NSFileType]isEqual:NSFileTypeRegular])return nil;[resources addObject:@{@"name":u.lastPathComponent,@"size":attrs[NSFileSize]}];}
 NSMutableDictionary *request=[@{@"op":@"begin",@"account":account?:@"",@"quality":quality?:@"original",@"timestamp":@((long long)(date?:NSDate.date).timeIntervalSince1970),@"resources":resources}mutableCopy];
 if(sourceID.length)request[@"sourceID"]=sourceID;
 NSDictionary *begin=GSRequest(request,&failure);
 NSString *identifier=begin[@"id"];if(!identifier)return nil;
 if([begin[@"duplicate"]boolValue])return identifier;
 BOOL success=NO;
 @try {
 for(NSUInteger i=0;i<files.count;i++){
  NSFileHandle *f=[NSFileHandle fileHandleForReadingAtPath:files[i].path];if(!f)return nil;
  @try {unsigned long long offset=0;while(YES){@autoreleasepool{
   NSData *chunk=[f readDataUpToLength:32768 error:&failure];if(!chunk)return nil;if(!chunk.length)break;
   if(!GSRequest(@{@"op":@"append",@"id":identifier,@"index":@(i),@"offset":@(offset),@"data":[chunk base64EncodedStringWithOptions:0]},&failure))return nil;
   offset+=chunk.length;
  }}} @finally {[f closeAndReturnError:nil];}
 }
 NSDictionary *sealed=GSRequest(@{@"op":@"seal",@"id":identifier},&failure);success=sealed!=nil;return sealed[@"id"];
 } @finally {if(!success)GSRequest(@{@"op":@"cancel",@"id":identifier},nil);}
 } @finally {if(error)*error=failure;}
}
NSString *GSImportFiles(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,NSError **error){
 return GSImportFilesWithSource(files,account,quality,date,nil,error);
}
NSString *GSImportPhotoIdentifier(NSString *localIdentifier,NSString *account,NSString *quality,NSError **error){
 return GSImportPhotoIdentifierChecked(localIdentifier,account,quality,nil,error);
}
NSString *GSImportPhotoIdentifierChecked(NSString *localIdentifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,NSError **error){
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
   NSArray *files=GSWriteOriginalResources(asset,directory,&failure);
   if(files&&authorization&&!authorization()){failure=[NSError errorWithDomain:@"Gunshot.Authorization" code:1 userInfo:nil];return;}
   if(files)job=GSImportFilesWithSource(files,account,quality,asset.creationDate,localIdentifier,&failure);
  } @finally {[NSFileManager.defaultManager removeItemAtURL:directory error:nil];}
 }});
 if(error)*error=failure;return job;
}
