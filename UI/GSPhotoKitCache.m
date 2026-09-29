#import "GSPhotoKitCache.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

static NSMutableSet<NSString *> *GSActivePhotoCaches;
static Class GSPhotoTaskContext;
static NSMutableDictionary<NSString *, NSNumber *> *GSPhotoCacheCreations;

@interface NSFileManager (GSPhotoKitCache)
- (NSURL *)gs_photoURLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain appropriateForURL:(NSURL *)url create:(BOOL)create error:(NSError **)error;
@end
@implementation NSFileManager (GSPhotoKitCache)
- (NSURL *)gs_photoURLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain appropriateForURL:(NSURL *)url create:(BOOL)create error:(NSError **)error {
    NSString *root = ((id (*)(id, SEL))objc_msgSend)(GSPhotoTaskContext, @selector(currentCachePath));
    if (directory != NSItemReplacementDirectory || !root)
        return [self gs_photoURLForDirectory:directory inDomain:domain appropriateForURL:url create:create error:error];
    @synchronized(GSActivePhotoCaches) {
        if (![GSActivePhotoCaches containsObject:root]) {
            if (error) *error = [NSError errorWithDomain:@"Gunshot.PhotoCacheClosed" code:1 userInfo:nil];
            return nil;
        }
        NSURL *owned = [[NSURL fileURLWithPath:root isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        if (![self createDirectoryAtURL:owned withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:error]) return nil;
        GSPhotoCacheCreations[root] = @([GSPhotoCacheCreations[root] unsignedIntegerValue] + 1);
        return owned;
    }
}
@end

@implementation GSPhotoKitCache {
    NSURL *_directory;
    dev_t _device;
    ino_t _inode;
}
+ (instancetype)create:(NSError **)error {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        GSPhotoTaskContext = NSClassFromString(@"GSPhotoKitTaskContext");
        if (![GSPhotoTaskContext respondsToSelector:@selector(currentCachePath)] ||
            ![GSPhotoTaskContext respondsToSelector:@selector(performWithCachePath:operation:)]) { GSPhotoTaskContext = Nil; return; }
        GSActivePhotoCaches = [NSMutableSet set];
        GSPhotoCacheCreations = [NSMutableDictionary dictionary];
        Method original = class_getInstanceMethod(NSFileManager.class, @selector(URLForDirectory:inDomain:appropriateForURL:create:error:));
        Method replacement = class_getInstanceMethod(NSFileManager.class, @selector(gs_photoURLForDirectory:inDomain:appropriateForURL:create:error:));
        method_exchangeImplementations(original, replacement);
    });
    if (!GSPhotoTaskContext) {
        if (error) *error = [NSError errorWithDomain:@"Gunshot.PhotoCacheUnavailable" code:1 userInfo:nil];
        return nil;
    }
    GSPhotoKitCache *cache = [self new];
    NSURL *base = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"GoToHP-PhotoSource" isDirectory:YES];
    cache->_directory = [base URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:cache.directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error]) return nil;
    struct stat st;
    if (lstat(cache.directory.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode)) return nil;
    cache->_device = st.st_dev; cache->_inode = st.st_ino;
    @synchronized(GSActivePhotoCaches) { [GSActivePhotoCaches addObject:cache.directory.path]; }
    return cache;
}
- (NSURL *)directory { return _directory; }
- (BOOL)perform:(dispatch_block_t)operation {
    @synchronized(GSActivePhotoCaches) { if (![GSActivePhotoCaches containsObject:_directory.path]) return NO; }
    ((void (*)(id, SEL, id, id))objc_msgSend)(GSPhotoTaskContext, @selector(performWithCachePath:operation:), _directory.path, operation);
    return YES;
}
- (NSDictionary *)statistics {
    unsigned long long bytes = 0, files = 0;
    for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:_directory.path]) {
        struct stat st;
        if (!lstat([[_directory URLByAppendingPathComponent:relative] fileSystemRepresentation], &st) && S_ISREG(st.st_mode)) {
            files++; bytes += (unsigned long long)st.st_blocks * 512;
        }
    }
    @synchronized(GSActivePhotoCaches) {
        return @{@"ownedCacheFiles": @(files), @"ownedCacheAllocatedBytes": @(bytes), @"ownedCacheDirectoriesCreated": GSPhotoCacheCreations[_directory.path] ?: @0};
    }
}
- (NSString *)sourceVersionForSize:(unsigned long long)size {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^([0-9a-f]{42}_[0-9a-f]{42})_([0-9]+)_([0-9]+)$" options:0 error:nil];
    NSString *identity = nil;
    for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:_directory.path]) {
        NSString *name = relative.lastPathComponent;
        NSTextCheckingResult *match = [pattern firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
        if (!match) continue;
        unsigned long long start = [[name substringWithRange:[match rangeAtIndex:2]] longLongValue];
        unsigned long long end = [[name substringWithRange:[match rangeAtIndex:3]] longLongValue];
        NSString *key = [name substringWithRange:[match rangeAtIndex:1]];
        if (start >= end || end > size || (identity && ![identity isEqual:key])) return nil;
        identity = key;
    }
    if (!identity) return nil;
    NSData *bytes = [[NSString stringWithFormat:@"photokit-range-v1\n%llu\n%@", size, identity] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}
- (BOOL)remove:(NSError **)error {
    @synchronized(GSActivePhotoCaches) {
        [GSActivePhotoCaches removeObject:_directory.path];
        [GSPhotoCacheCreations removeObjectForKey:_directory.path];
        struct stat st;
        if (lstat(_directory.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || st.st_dev != _device || st.st_ino != _inode) {
            if (error) *error = [NSError errorWithDomain:@"Gunshot.PhotoCacheReplaced" code:1 userInfo:nil];
            return NO;
        }
        return [NSFileManager.defaultManager removeItemAtURL:_directory error:error];
    }
}
@end
