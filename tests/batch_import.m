#import "../UI/GSBatchImport.h"
#import "../UI/GSExporter.h"
#include <assert.h>

static NSString *Identity=@"identity-A",*Account=@"a@example.com";
static NSUInteger Queued,Exports,Fetches,MaxFetch,LiveAssets,PeakAssets;
static BOOL FailExport,FailQueue,SwitchDuringExport,CancelDuringExport,Offline,LargeOriginal;
static BOOL RecoverLarge,UncertainCommit,CancelDuringRetry;
static NSUInteger LargeAttempts;
static NSString *LastDirectory;
static dispatch_semaphore_t VideoRelease;
static NSUInteger ActiveVideos,PeakVideos,StartedVideos;
// Preparation runs several workers; fixture counters must not race.
static void Count(NSUInteger *counter){@synchronized(NSNull.null){(*counter)++;}}
@interface PHFetchResult ()
@property(nonatomic,strong) NSArray *items;
@end
@implementation PHFetchResult
- (void)enumerateObjectsUsingBlock:(void (^)(PHAsset *,NSUInteger,BOOL *))block{
 BOOL stop=NO;NSUInteger i=0;for(PHAsset *asset in self.items){block(asset,i++,&stop);if(stop)break;}
}
@end
@implementation PHAsset
- (instancetype)init{if((self=[super init])){LiveAssets++;PeakAssets=MAX(PeakAssets,LiveAssets);}return self;}
- (void)dealloc{LiveAssets--;}
+ (PHFetchResult *)fetchAssetsWithLocalIdentifiers:(NSArray *)ids options:(id)options{
 assert(!NSThread.isMainThread);Fetches++;MaxFetch=MAX(MaxFetch,ids.count);
 NSMutableArray *items=[NSMutableArray array];
 // PhotoKit need not preserve requested order and may omit inaccessible IDs.
 for(NSString *identifier in ids.reverseObjectEnumerator){
  if([identifier isEqual:@"missing"])continue;
  PHAsset *asset=[PHAsset new];asset.localIdentifier=identifier;asset.mediaType=[identifier hasPrefix:@"video-"]?PHAssetMediaTypeVideo:PHAssetMediaTypeImage;asset.creationDate=[NSDate dateWithTimeIntervalSince1970:123];[items addObject:asset];
 }
 PHFetchResult *result=[PHFetchResult new];result.items=items;return result;
}
@end
BOOL GSNativeIdentityMatches(NSString *identifier){assert(NSThread.isMainThread);return [identifier isEqual:Identity];}
NSDictionary *GSRequest(NSDictionary *request,NSError **error){
 assert(!NSThread.isMainThread);if(Offline)return nil;
 if([request[@"op"]isEqual:@"accounts"])return @{@"selected":Account};
 if([request[@"op"]isEqual:@"options"])return @{@"quality":@"original"};
 assert(NO);return nil;
}
NSArray *GSExportAsset(PHAsset *asset,NSURL *directory,NSError **error){
 assert(!NSThread.isMainThread);Count(&Exports);LastDirectory=directory.path;
 NSURL *photo=[directory URLByAppendingPathComponent:@"original.heic"];
 [@"original" writeToURL:photo atomically:YES encoding:NSUTF8StringEncoding error:nil];
 if(SwitchDuringExport)dispatch_sync(dispatch_get_main_queue(),^{Identity=@"identity-B";});
 if(CancelDuringExport)dispatch_sync(dispatch_get_main_queue(),^{GSStopBatchImport(YES);});
 if(FailExport&&[asset.localIdentifier isEqual:@"500"]){if(error)*error=[NSError errorWithDomain:@"private filename/token must not escape" code:7 userInfo:nil];return nil;}
 if([asset.localIdentifier isEqual:@"1000"]){
  NSURL *movie=[directory URLByAppendingPathComponent:@"paired.mov"];[@"paired" writeToURL:movie atomically:YES encoding:NSUTF8StringEncoding error:nil];return @[photo,movie];
 }
 return @[photo];
}
NSString *GSImportFiles(NSArray *files,NSString *account,NSString *quality,NSDate *date,NSError **error){
 assert(!NSThread.isMainThread&&[account isEqual:@"a@example.com"]&&[quality isEqual:@"original"]);
 assert(date.timeIntervalSince1970==123);
 if(FailQueue)return nil;
 Count(&Queued);for(NSURL *file in files)assert([NSFileManager.defaultManager fileExistsAtPath:file.path]);return @"job";
}
NSString *GSImportPhotoIdentifierChecked(NSString *identifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,NSError **error){
 assert(!NSThread.isMainThread&&[account isEqual:@"a@example.com"]&&[quality isEqual:@"original"]);Count(&Exports);
 if(authorization&&!authorization())return nil;
 if(VideoRelease&&[identifier hasPrefix:@"video-"]){
  @synchronized(NSNull.null){StartedVideos++;ActiveVideos++;PeakVideos=MAX(PeakVideos,ActiveVideos);}
  assert(dispatch_semaphore_wait(VideoRelease,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
  @synchronized(NSNull.null){ActiveVideos--;}
 }
 if(SwitchDuringExport)dispatch_sync(dispatch_get_main_queue(),^{Identity=@"identity-B";});
 if(CancelDuringExport)dispatch_sync(dispatch_get_main_queue(),^{GSStopBatchImport(YES);});
 if(authorization&&!authorization())return nil;
 if([identifier isEqual:@"missing"]){if(error)*error=[NSError errorWithDomain:@"Gunshot" code:4 userInfo:nil];return nil;}
 if([identifier isEqual:@"large"]){
  Count(&LargeAttempts);
  if(LargeOriginal&&(!RecoverLarge||LargeAttempts==1)){if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{@"storage":@{@"freeBytes":@123}}];return nil;}
 }
 if(UncertainCommit){if(error)*error=[NSError errorWithDomain:@"Gunshot.DuplicateSafety" code:1 userInfo:nil];return nil;}
 if(FailExport&&[identifier isEqual:@"500"]){if(error)*error=[NSError errorWithDomain:@"private filename/token must not escape" code:7 userInfo:nil];return nil;}
 if(FailQueue){if(error)*error=[NSError errorWithDomain:@"Gunshot.IPC" code:5 userInfo:nil];return nil;}
 Count(&Queued);return @"job";
}
NSString *GSImportPhotoIdentifier(NSString *identifier,NSString *account,NSString *quality,NSError **error){
 return GSImportPhotoIdentifierChecked(identifier,account,quality,nil,error);
}
NSString *GSImportPhotoIdentifierWithProgress(NSString *identifier,NSString *account,NSString *quality,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 return GSImportPhotoIdentifierChecked(identifier,account,quality,authorization,error);
}
NSString *GSImportFilesWithProgress(NSArray *files,NSString *account,NSString *quality,NSDate *date,GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error){
 return GSImportFiles(files,account,quality,date,error);
}
static NSDictionary *Run(NSArray *ids){
 __block NSDictionary *done=nil;
 BOOL started=GSStartBatchImport(ids.count,@"picker",YES,GSPhotoIdentifierProvider(ids),@"a@example.com",@"identity-A",nil,^(NSDictionary *state){assert(NSThread.isMainThread);done=state;});assert(started);
 assert(!GSStartBatchImport(1,@"picker",YES,^id(NSUInteger i){return nil;},@"a@example.com",nil,nil,nil));
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
 while(!done&&deadline.timeIntervalSinceNow>0){
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  if(CancelDuringRetry&&[GSBatchImportSnapshot()[@"stage"]isEqual:@"waiting_storage"])GSStopBatchImport(NO);
 }
 assert(done&&![done[@"active"]boolValue]);
 if(LastDirectory)assert(![NSFileManager.defaultManager fileExistsAtPath:LastDirectory]);
 return done;
}
int main(void){@autoreleasepool{
 NSMutableArray *ids=[NSMutableArray array];for(NSUInteger i=0;i<2000;i++)[ids addObject:[NSString stringWithFormat:@"%lu",(unsigned long)i]];
 ids[99]=@"missing";ids[777]=NSNull.null;FailExport=YES;
 NSDictionary *result=Run(ids);
 assert(Queued==1997&&[result[@"queued"]unsignedIntegerValue]==1997&&[result[@"failed"]unsignedIntegerValue]==3&&[result[@"remaining"]unsignedIntegerValue]==0);
 assert(Fetches>0&&MaxFetch<=256&&PeakAssets<=256&&LiveAssets==0); // Metadata never crosses into preparation queues.
 assert([result[@"stage"]isEqual:@"finished"]&&![result[@"stopReason"]length]);
 NSString *json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]encoding:NSUTF8StringEncoding];
 assert(![json containsString:@"identity-A"]&&![json containsString:@"example.com"]&&![json containsString:@"original.heic"]&&![json containsString:@"private filename"]);
 FailExport=NO;FailQueue=YES;NSUInteger before=Queued;result=Run(@[@"0",@"1"]);
 assert(Queued==before&&[result[@"stage"]isEqual:@"finished"]&&[result[@"failed"]intValue]==2&&[result[@"failureCodes"][@"queue_rejected"]intValue]==2);
 FailQueue=NO;SwitchDuringExport=YES;result=Run(@[@"0",@"1"]);
 assert(Queued==before&&[result[@"stopReason"]isEqual:@"account_changed"]);
 SwitchDuringExport=NO;Identity=@"identity-A";CancelDuringExport=YES;result=Run(@[@"0",@"1"]);
 assert(Queued==before&&[result[@"stopReason"]isEqual:@"background_expired"]);
 CancelDuringExport=NO;Offline=YES;result=Run(@[@"0"]);assert([result[@"stopReason"]isEqual:@"service_unavailable"]);
 Offline=NO;result=Run(@[@"0",@"1"]);assert(Queued==before+2&&[result[@"queued"]intValue]==2);
 LargeOriginal=YES;LargeAttempts=0;before=Queued;result=Run(@[@"0",@"large",@"1"]);
 assert(Queued==before+2&&[result[@"processed"]intValue]==2&&[result[@"remaining"]intValue]==1&&LargeAttempts==3);
 assert([result[@"stage"]isEqual:@"stopped"]&&[result[@"stopReason"]isEqual:@"storage_deferred"]);
 assert([result[@"storageDeferred"]intValue]==1&&[result[@"failed"]intValue]==0&&[result[@"lastStorageFailure"][@"freeBytes"]intValue]==123);
 RecoverLarge=YES;LargeAttempts=0;before=Queued;result=Run(@[@"0",@"large",@"1"]);
 assert(Queued==before+3&&LargeAttempts==2&&[result[@"processed"]intValue]==3&&[result[@"remaining"]intValue]==0);
 assert([result[@"failed"]intValue]==0&&[result[@"storageDeferred"]intValue]==0&&[result[@"stage"]isEqual:@"finished"]);
 RecoverLarge=NO;
 CancelDuringRetry=YES;LargeAttempts=0;result=Run(@[@"large"]);CancelDuringRetry=NO;
 assert(LargeAttempts==1&&[result[@"stopReason"]isEqual:@"cancelled"]&&[result[@"remaining"]intValue]==1&&[result[@"failed"]intValue]==0);
 LargeOriginal=NO;result=Run(@[@"large"]);assert([result[@"queued"]intValue]==1);
 UncertainCommit=YES;result=Run(@[@"uncertain"]);UncertainCommit=NO;
 assert([result[@"failureCodes"][@"commit_outcome_unknown"]intValue]==1&&![result[@"failureCodes"][@"export_failed"]intValue]);
 // Videos come first in the album and never complete until released. Later photos must still queue.
 NSMutableArray *mixed=[NSMutableArray array];for(NSUInteger i=0;i<20;i++)[mixed addObject:[NSString stringWithFormat:@"video-%lu",(unsigned long)i]];
 for(NSUInteger i=0;i<6;i++)[mixed addObject:[NSString stringWithFormat:@"photo-%lu",(unsigned long)i]];
 VideoRelease=dispatch_semaphore_create(0);__block NSDictionary *mixedResult=nil;before=Queued;
 assert(GSStartBatchImport(mixed.count,@"album",YES,GSPhotoIdentifierProvider(mixed),@"a@example.com",@"identity-A",nil,^(NSDictionary *state){mixedResult=state;}));
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];BOOL photosDone=NO;
 while(!photosDone&&deadline.timeIntervalSinceNow>0){
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  @synchronized(NSNull.null){photosDone=Queued==before+6&&StartedVideos>0;}
 }
 assert(photosDone&&!mixedResult);
 @synchronized(NSNull.null){assert(StartedVideos==1&&ActiveVideos==1);}
 for(NSUInteger i=0;i<20;i++)dispatch_semaphore_signal(VideoRelease);
 deadline=[NSDate dateWithTimeIntervalSinceNow:5];
 while(!mixedResult&&deadline.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
 assert(mixedResult&&[mixedResult[@"queued"]unsignedIntegerValue]==mixed.count&&[mixedResult[@"scannedItems"]unsignedIntegerValue]==mixed.count);
 assert(StartedVideos==20&&PeakVideos==1&&ActiveVideos==0);
 VideoRelease=nil;
 NSLog(@"PASS later photos prepare with one blocked video and video preparation stays serial after photos finish");
 NSLog(@"PASS oversized original is deferred while later photos continue and remains retryable");
 NSLog(@"PASS 2000 identifier-only selections, missing IDs, individual export failure, account switch, cancellation, queue/IPC failure, retry and private batch diagnostics");
}}
