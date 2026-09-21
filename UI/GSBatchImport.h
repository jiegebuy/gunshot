#pragma once
#import <Foundation/Foundation.h>

// Providers run on the import worker, one item at a time. For PhotoKit batches
// they return an NSString localIdentifier, never a PHAsset/PHFetchResult.
typedef id (^GSBatchItemProvider)(NSUInteger index);
typedef void (^GSBatchProgress)(NSDictionary *snapshot);
FOUNDATION_EXPORT BOOL GSStartBatchImport(NSUInteger count, NSString *source, BOOL assets,
 GSBatchItemProvider provider, NSString *account, NSString *identity,
 GSBatchProgress progress, GSBatchProgress completion);
FOUNDATION_EXPORT void GSStopBatchImport(BOOL backgroundExpired);
FOUNDATION_EXPORT NSDictionary *GSBatchImportSnapshot(void);
// Copy stable PhotoKit identifiers without retaining framework objects across queues.
FOUNDATION_EXPORT GSBatchItemProvider GSPhotoIdentifierProvider(NSArray *identifiers);
