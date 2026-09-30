# Original streaming and disk usage

Single-resource PhotoKit imports can negotiate an unknown-length Scotty upload
before the resource reader reaches EOF. Live Photos and file-provider imports
continue to use their complete-resource paths.

The range source uses private CloudAsset original-byte ranges for cloud-only
videos on iOS 27, up to 8 GiB. A 1 MiB probe establishes the resource's opaque
signature before queue admission. V43 requests use up to 20 MiB chunks and reader
windows of at most 60 MiB, with at most four range sources per host process. Local
resources, photographs, and earlier systems retain the existing reader.
An incompatible cloud loader fails explicitly instead of silently starting a
full-original download. This remains an unsupported private API integration.

V43 album preparation reserves half the upload concurrency for videos, with a
minimum of one and a maximum of four workers (two at concurrency 4, four at 8).
Metadata-eligible bounded cloud sources can use these workers; full-resource
PhotoKit videos remain serialized. Photo preparation keeps independent workers,
and the process-wide four-source cap still covers non-album entry points.
The streaming upload scheduler uses the same limits and leaves room for ready
files. Larger reader windows reduce PhotoKit setup overhead while preserving
per-window ownership and reclamation; their physical cache is additional to
the queue window below. See [throughput measurements](analysis/upload-throughput-v43.md).

V44 passes up to 8 MiB per synchronous in-process append, subject to the
remaining producer window. PhotoKit callbacks are no longer unconditionally
split at 1 MiB. The queue still fsyncs bytes and the source checkpoint before
returning; this amortizes durable writes without acknowledging volatile data.
The JSON/Mach transport retains its smaller limit. Streaming diagnostics
include append calls/bytes, engine-lock wait time, and append processing time.

Swift TaskLocal ownership propagates from our request into CloudAssets tasks.
Only tasks carrying an active owned lease redirect item-replacement directories
into `Library/Caches/GoToHP-PhotoSource`. Other callers retain FileManager's
normal behavior. A completed window revokes/removes its own directory; there
is no scan/deletion of the host's general temporary or Photos caches. Marked
leases left by a terminated process are reclaimed on the next initialization.

## Bounded queue storage

New streaming producers request `streamBounded` at `begin`. When the response
confirms it, they query `stream_window` before each append. The queue also
enforces the limit independently: at most 65 MiB of unreclaimed file data per
producer. This accommodates the maximum supported 64 MiB server granularity
and the byte retained for explicit finalization. Multiple producers each have
their own window. PhotoKit's current callback buffer is additional memory.

Streaming uploads persist a learned chunk target with their private session.
The target starts at 8 MiB, adjusts toward twelve seconds per acknowledgement
between 1 and 32 MiB, and halves after an interrupted transfer. Server
granularity remains authoritative. Successful chunks can immediately schedule
the next available prefix; empty attempts and failures retain their backoff.

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
- New range-source jobs persist a private `.source.json` checkpoint containing
  original signature, expected size, received offset, and SHA-256 state. Every
  successful append fsyncs its bytes and atomically persists the checkpoint
  before the native source can release its cache. On restart, a fresh source
  signature must match; the released hash prefix is restored and the retained
  tail is rehashed against the checkpoint. Only then is a nonzero offset
  returned. A partially written tail beyond the checkpoint is truncated.
  Legacy jobs without this checkpoint continue using verified replay.
- Missing, expired, replaced, or rewound remote sessions cannot read zeros out
  of a deallocated prefix. The job requires a fresh original import. Selecting
  the source again replaces that precommit job, not an uncertain library commit.
- The final byte remains local until producer EOF. No preupload call finalizes
  media, and seal excludes concurrent use of the session by two upload workers.

Tests verify actual allocated blocks, original hashes, resumed wire bytes,
changed replay content, bounded producer admission, interrupted reclamation,
and rejection of missing/rewound/replaced sessions. CI runs allocation tests
on both Linux and macOS/APFS, plus native JSON and binary PhotoKit fixtures.
The C ABI smoke test exercises the production jailed role selector for window
queries and recovers an interrupted zero-byte import through append and seal.

## Public PhotoKit Path

This bounds the application's queue copy, not PhotoKit's own original cache.
`requestDataForAssetResource` provides no original byte-range/seek parameter.
The public iOS 27 resource-manager header still exposes only network permission
and progress on this data-request path.
The inspected iOS 17 runtime headers separate resource availability from file
streaming; private options such as `downloadIsTransient` and
`pruneAfterAvailableOnLowDisk` are cache-policy hints, not an original-byte
streaming contract, and are not enabled based only on their names.

Consequently a file may still be downloaded completely by PhotoKit before its
first callback. PhotoKit progress at first data and a pre-EOF Google receipt
prove overlapping reading/upload, not overlapping iCloud network traffic.

This is a limitation of the current PhotoKit source, not proof that iCloud
originals cannot be streamed. The 2026-09-29 investigation found a direct HTTP
source in released rclone v1.75.1, including Photos, Range reads, and ADP/PCS
authorization. It is not integrated into this app yet. See
[iCloud original streaming research](analysis/icloud-original-streaming.md)
for evidence, authentication requirements, and the additional recovery work.

An isolated iPadOS 27 experiment subsequently obtained original-byte ranges
through the private streaming player-item CloudAsset loader. A 261,547,802-byte
read matched the normal PhotoKit original's SHA-256 exactly. The v40 source
predates this integration. A later windowed experiment reclaimed its own
temporary range files while reading a 247,546,555-byte original, with matching
full hash and 74,244,096 peak extra temporary allocated bytes. Durable source
resume was subsequently implemented and fault-tested in v41. The installed
Google pipeline still needs device-side acknowledgement/restart verification.
See [PhotoKit probe results](../experiments/photokit/RESULTS.md).

Research references:

- https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS27.0.sdk/System/Library/Frameworks/Photos.framework/Headers/PHAssetResourceManager.h
- https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS18.0.sdk/System/Library/Frameworks/Photos.framework/Headers/PHAssetResourceManager.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/Frameworks/Photos.framework/PHAssetResourceRequest.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/Frameworks/Photos.framework/PHAssetResourceRequestOptions.h
