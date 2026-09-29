# Physical-device PhotoKit streaming results

2026-09-29, iPad13,8, iPadOS 27.0. Independent PhotoKit Probe app; production
Google Photos v40 was not replaced and its original album task was stopped.
Data was hashed and discarded, without a Google upload or library mutation.
Device-local asset identifiers and media URLs are intentionally omitted here.

## Original-byte path verified

`requestPlayerItemForVideo` with original/high-quality options and private
`streamingAllowed = YES` produced a `photos-avasset` AVURLAsset. Its retained
player item owns a `CloudAsset.LoadingRequestHandler` resource-loader delegate.
The diagnostic app supplied duck-typed loading requests with 1 MiB ranges.
It did not read private object memory, export credentials, or transcode media.

For an initially cloud-only 261,547,802-byte MOV:

- A 1 MiB prefix arrived in 7.106 seconds; free space fell about 5.5 MB and the
  original remained unavailable locally in PhotoKit metadata.
- The full 250-range stream took 85.696 seconds, with first bytes at 6.556
  seconds. Its length and SHA-256 matched a subsequent ordinary original
  resource request, which delivered its first callback at 24.541 seconds.
- Both complete SHA-256 values were
  `76384a1c828ebb740a9ca8c73da4ea2176797613921ee17112cf8773591cd521`.
- Free space fell about 467.5 MB during the full stream. This disproves a
  small bounded-cache claim for the unmodified v2 experiment.

After the full stream and normal comparison, the probe's own cache/tmp files
occupied 447,475,712 allocated bytes. Their logical sizes summed to about
6.69 GB because individual range files have sparse prefixes. Logical sizes
must not be mistaken for actual allocated storage. Killing and restarting the
probe did not remove these files. No Photos cache was purged.

For a separate initially cloud-only 84,458,021-byte video, a first request at
offset 41,943,040 returned 1,048,576 bytes in 7.363 seconds. Its interval hash
was `261dcac11ae920e7b4ac74e04578da4ff375a1f84a11327c6ca2d4ce04ca7b93`.
It matched the same interval read from the subsequently downloaded original
exactly. This establishes original-byte seeking for that sample, not durable
upload resume.

## Reader lifetime control

Version 3 reopened scoped image managers/player items every 20 MiB and removed
completed synthetic requests from the delegate's task mapping. The weak loader
reference was nil after every window. Nevertheless, a full 84,458,021-byte
read left 160,079,872 additional temporary allocated bytes. Reader deallocation
alone did not bound disk use. The full hash again matched resource-local:
`bda1ae4d47c6079fc8685efccbac0ecdb81bfe644d5330f76d28f36ac42d2654`.

Version 4 adds opt-in reclamation of newly-created range files only after a
window is fully consumed and its loader has been released. Files must belong
to this probe's temporary directory and match observed range bounds/layout.
It does not unlink active-reader files, pre-existing files, or Photos storage.
Full-content and post-restart interval verification are required before any
conclusion about its safety or storage bound.

### Window reclamation result

An initially cloud-only 247,546,555-byte MP4 completed in 199.526 seconds,
using twelve windows of at most 20 MiB. First bytes arrived at 10.044 seconds.
The original remained locally unavailable in PhotoKit metadata afterward.
The full hash matched a subsequent normal original resource read:
`755a2b960330ecea37d9718d5ca6f51e62dee760ba90556d704134733c47667c`.

Every window released its loader and removed four new temporary range files,
with no skipped files or deletion errors. After each reclamation the temporary
allocated bytes returned to the same pre-run baseline. The maximum observed
additional temporary allocation was 74,244,096 bytes (70.8 MiB); final extra
temporary allocation was zero. Existing 607,547,392 bytes of prior experimental
temporary files were not altered by this mode.

Device free space went from 6,162,477,056 to 6,149,652,480 bytes, with a sampled
minimum of 6,074,068,992. Thus this did not leave a whole new original on disk,
but temporary-file measurements are not a strict whole-device storage bound.
The run was slower than the normal 26.492-second full-original request because
the diagnostic path serializes range/window requests. It prioritizes bounded
storage, not peak throughput, and no performance optimum has been established.

After killing/restarting the probe, reopening the same original at offset
104,857,600 returned 1,048,576 bytes in 12.446 seconds. The new temporary range
file was reclaimed again. Its SHA-256 was
`541c2adf9550431e6c7c36e2b7de10a6ba9ec1373d533f7b4a8fa75cdb7527dd`.
The same interval read from the normal original matched exactly. This proves
reopening an evicted source interval across a process restart on this sample;
it does not yet prove recovery of an interrupted Google upload.

## Other modes

- `downloadIsTransient = YES` alone yielded zero bytes before cancellation
  in two cold-resource trials (180 and 60 seconds). A normal request afterward
  succeeded. This setting did not establish streaming in these experiments.
- `requestAVAssetForVideo` with `streamingAllowed` returned nil without an
  error in one cold trial. `requestPlayerItemForVideo` returned the custom
  asset in about half a second, but that URL is not directly HTTP-readable.
- Normal `requestAVAssetForVideo` returned a fully allocated local file in
  about 20 seconds for a 226,264,371-byte MOV. Its hash matched resource-local.

## Remaining checks

The v6/v7 probes subsequently tested the exact `UI/GSPhotoKitRangeSource` used
by v41, with owned TaskLocal cache scopes. During a 5 MiB request the scope
contained one range file with 5,267,456 allocated bytes; the host's general
temporary directory stayed empty. The file had disappeared after reader
teardown, and the owned scope was removed successfully.

The production reader completed a 94,759,440-byte MOV in 83.388 seconds, with
first consumed data at 7.219 seconds. Its full SHA-256 matched the normal
original: `a7fbe0600ed53619b4f9029250bdbc6e481d8fd84c85cedbefe81eb2a1fad832`.
After process restart, a read from offset 52,428,800 delivered the remaining
42,330,640 bytes. Both the source signature and the tail hash matched. The
independently verified tail SHA-256 was
`b14ba9466edc08a74045f3b4a49bd4e398e1c69da5e87a50ff0c77d00473a795`.

Go tests now verify nonzero resume across engine restart after disk prefix
deallocation, preserved full hashes, rejection of changed versions/sizes,
corrupt retained tails/checkpoints, missing or rewound sessions, uncheckpointed
tail truncation, premature EOF, and storage-checkpoint failure. Native tests
exercise concurrent TaskLocal scopes without redirecting unrelated callers.
No Google receipt, edited/Live Photo identity matrix, or background-suspension
recovery has been verified on this path yet.

Production integration must bind the chosen original and a stable version to
the saved source offset/hash state, respect existing queue backpressure, and
only reclaim producer-owned cache after durable consumption. The diagnostic
reclaimer cannot be copied wholesale into the Photos host: other PhotoKit
requests can use the host's temporary directory concurrently. V41 uses the
isolated TaskLocal source ownership scheme above instead.
Keep missing/rewound Google sessions and ambiguous library commits fail-closed.
An unsupported/changed loader must report an explicit fallback/storage choice,
not silently cache a multi-GB file while claiming bounded streaming.

PhotoKit's progress reaches 1 when the player item is delivered, so it is not
the network download progress. Network counters are device-wide and include
other activity; they cannot be presented as this resource's traffic.

## Inspected implementation references

- [CloudAssets runtime headers](https://github.com/qingralf/iOS26-Runtime-Headers/tree/master/PrivateFrameworks/CloudAssets.framework)
- [iOS 26.1 CloudAssets implementation](https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/main/System/Library/PrivateFrameworks/CloudAssets.framework/CloudAssets/CloudAssets.mm)

The inspected delegate special-cases an offset-0, length-2 read with synthetic
zeroes. The probe uses 1 MiB chunks and never uses that special request as
original-content evidence. Private API behavior can differ by OS release.
