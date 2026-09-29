# Original streaming and disk usage

Single-resource PhotoKit imports can negotiate an unknown-length Scotty upload
before the resource reader reaches EOF. Live Photos and file-provider imports
continue to use their complete-resource paths.

## Bounded queue storage

New streaming producers request `streamBounded` at `begin`. When the response
confirms it, they query `stream_window` before each append. The queue also
enforces the limit independently: at most 65 MiB of unreclaimed file data per
producer. This accommodates the maximum supported 64 MiB server granularity
and the byte retained for explicit finalization. Multiple producers each have
their own window. PhotoKit's current callback buffer is additional memory.

After a preupload worker exits, the queue reclaims only a prefix acknowledged
in its private, durable upload checkpoint. It extends SHA-1 and SHA-256 states,
fsyncs the original and atomically saves the hash states bound to that exact
session, then deallocates whole MiB ranges with `F_PUNCHHOLE` on APFS (or
`FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE` on Linux). Logical offsets and file
size do not change; allocated disk blocks do. The normal single-file uploader
restores the prefix SHA-1 state and hashes only the remaining tail.

The `.upload-*.json.spool` sidecar is private and must be backed up together
with the upload checkpoint and retained file. It is not a diagnostic export.
Deleting either checkpoint does not permit a fresh upload from a sparse file.

## Recovery

- A crash before deallocation may retain extra blocks, but cannot lose hash
  state. A later reclaim also removes ranges left allocated by that crash.
- Interrupted PhotoKit requests must replay from byte zero. Replayed bytes in
  a deallocated prefix are hashed and checked against its SHA-256 checkpoint;
  retained bytes are compared directly. Preupload remains disabled until all
  previously received bytes have been verified. Nothing is written twice.
- Missing, expired, replaced, or rewound remote sessions cannot read zeros out
  of a deallocated prefix. The job requires a fresh original import. Selecting
  the source again replaces that precommit job, not an uncertain library commit.
- The final byte remains local until producer EOF. No preupload call finalizes
  media, and seal excludes concurrent use of the session by two upload workers.

Tests verify actual allocated blocks, original hashes, resumed wire bytes,
changed replay content, bounded producer admission, interrupted reclamation,
and rejection of missing/rewound/replaced sessions. CI runs allocation tests
on both Linux and macOS/APFS, plus native JSON and binary PhotoKit fixtures.

## Remaining iCloud limitation

This bounds the application's queue copy, not PhotoKit's own original cache.
`requestDataForAssetResource` provides no original byte-range/seek parameter.
The public iOS 18 header still exposes only network permission and progress.
The inspected iOS 17 runtime headers separate resource availability from file
streaming; private options such as `downloadIsTransient` and
`pruneAfterAvailableOnLowDisk` are cache-policy hints, not an original-byte
streaming contract, and are not enabled based only on their names.

Consequently a file may still be downloaded completely by PhotoKit before its
first callback. PhotoKit progress at first data and a pre-EOF Google receipt
prove overlapping reading/upload, not overlapping iCloud network traffic.

Research references:

- https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS18.0.sdk/System/Library/Frameworks/Photos.framework/Headers/PHAssetResourceManager.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/Frameworks/Photos.framework/PHAssetResourceRequest.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/Frameworks/Photos.framework/PHAssetResourceRequestOptions.h
