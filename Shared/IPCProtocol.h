#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>

#define GS_SERVICE "dev.tqmane.gunshot.service"
#define GS_MAX_JSON 60000
#define GS_MESSAGE_ID 0x47534831
#define GS_STATE_PATH "/var/mobile/Library/Application Support/GoToHP"
// No complex descriptors, pointers, paths, or client-supplied identities on the wire.
typedef struct { mach_msg_header_t header; uint32_t length; char json[GS_MAX_JSON]; } GSMessage;
#ifdef __cplusplus
extern "C" {
#endif
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_check_in(mach_port_t,const char *,mach_port_t *);
extern kern_return_t bootstrap_look_up(mach_port_t,const char *,mach_port_t *);
#ifdef __cplusplus
}
#endif
FOUNDATION_EXPORT NSDictionary *GSRequest(NSDictionary *request, NSError **error);
#if !GS_JAILED
FOUNDATION_EXPORT NSDictionary *GSIPCDiagnosticsSnapshot(void);
#endif
#if GS_JAILED
// In-process only: bounded binary chunks, no JSON/base64 expansion.
FOUNDATION_EXPORT BOOL GSEmbeddedAppend(NSString *identifier,NSUInteger index,unsigned long long offset,NSData *data,NSError **error);
// Nonblocking, metadata-only; safe while native authorization is in progress.
FOUNDATION_EXPORT NSDictionary *GSEmbeddedRuntimeSnapshot(void);
#endif
