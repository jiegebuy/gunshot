#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
// These methods run on a worker queue. UI callbacks remain on the main queue.
NSArray<NSURL *> *GSExportAsset(PHAsset *asset, NSURL *directory, NSError **error);
NSString *GSImportFiles(NSArray<NSURL *> *files, NSString *account, NSString *quality, NSDate *date, NSError **error);
// Resolve PhotoKit by local identifier on the preparation worker and check the
// persistent queue identity before any original bytes are exported.
NSString *GSImportPhotoIdentifier(NSString *localIdentifier, NSString *account, NSString *quality, NSError **error);
typedef BOOL (^GSImportAuthorizationCheck)(void);
typedef void (^GSImportStorageProgress)(NSDictionary *status);
// A free serial lane is reserved per source until export/seal completes. Equal
// sources cannot overlap; unrelated sources never wait behind a hash collision.
// Staging storage still bounds how far preparation can run ahead of uploads.
#define GS_IMPORT_LANES 12
NSString *GSImportFilesWithProgress(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,
 GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error);
NSString *GSImportPhotoIdentifierWithProgress(NSString *localIdentifier, NSString *account, NSString *quality,
 GSImportAuthorizationCheck authorization, GSImportStorageProgress progress, NSError **error);
NSString *GSImportPhotoIdentifierChecked(NSString *localIdentifier, NSString *account, NSString *quality,
 GSImportAuthorizationCheck authorization, NSError **error);
