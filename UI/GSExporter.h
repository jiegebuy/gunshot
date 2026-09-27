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
// Serial preparation lanes: an equal source always uses the same lane. Each
// iCloud original carries a fixed request latency, so a few lanes cannot keep
// eight uploads supplied; staging storage still bounds how far they run ahead.
#define GS_IMPORT_LANES 12
NSString *GSImportFilesWithProgress(NSArray<NSURL *> *files,NSString *account,NSString *quality,NSDate *date,
 GSImportAuthorizationCheck authorization,GSImportStorageProgress progress,NSError **error);
NSString *GSImportPhotoIdentifierWithProgress(NSString *localIdentifier, NSString *account, NSString *quality,
 GSImportAuthorizationCheck authorization, GSImportStorageProgress progress, NSError **error);
NSString *GSImportPhotoIdentifierChecked(NSString *localIdentifier, NSString *account, NSString *quality,
 GSImportAuthorizationCheck authorization, NSError **error);
