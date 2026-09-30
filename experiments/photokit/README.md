# PhotoKit original-byte experiment

Standalone physical-device diagnostic app. It has no Google credentials,
uploader, PhotoKit mutation requests, or original-cache deletion code. Raw
bytes are hashed and discarded. Private setters are ABI-checked at runtime.
The normal Gunshot application is not linked or modified.

Build on macOS using `bash experiments/photokit/build.sh`, then sign the IPA
with an appropriate device provisioning profile. Allow photo library access.
Only run one probe at a time, with the normal importer stopped.

Commands are atomically placed in the app's Documents/command.json. A unique
alphanumeric/hyphen/underscore `id` is required. `inventory` writes up to 1000
recent videos and their original sizes/locality to inventory.json. Other modes
require an `assetID` from that inventory. No media URLs or cookies are logged.

```json
{"id":"cold-transient-1","mode":"resource-transient","assetID":"LOCAL_ID","timeout":180,"maxBytes":1073741824}
```

Modes:

- `resource-local`: original bytes, network disallowed; confirms local access.
- `resource-baseline`: normal original-resource request, network allowed.
- `resource-transient`: same request with `downloadIsTransient = YES`.
- `video-baseline`: original, high-quality AVAsset request.
- `video-streaming`: same AVAsset request with `streamingAllowed = YES`.
- `player-streaming`: original player-item request with streaming enabled.
- `range-loader-streaming`: experimental duck-typed 1 MiB requests to the
  returned CloudAssets resource-loader delegate. This probes its decrypted byte
  ranges without transcode/export. It retains the player item that owns the
  delegate, accepts only the inspected CloudAsset(s) delegate classes, and
  verifies each returned range length. `startOffset` tests nonzero reads.
  This unsupported diagnostic technique is not part of the production uploader.

Version 3 adds `rangeLength` to loader/file reads. `rangeSHA256` and
`rangeComplete` describe the requested interval; they do not imply a full-file
hash. `video-baseline` can seek a local original to verify the same interval.
For loader experiments, `scopedManager: true` creates a separate image manager
and cancels/releases its AVAsset after reading. `releaseCompletedRequests: true`
also removes completed synthetic requests using the delegate cancellation
callback. `windowBytes` reopens a scoped player item for each bounded window,
while preserving the overall hash. These are experimental lifetime controls,
not confirmed cache-eviction APIs. Temporary-file logical and allocated bytes
and weak delegate lifetime are sampled.

Version 4 optionally enables `reclaimWindowTemporaryFiles: true` with
`windowBytes`. After a fully consumed window and confirmed loader release,
it unlinks only range files newly created in that window in this probe's own
temporary directory. The directory name, range filename, bounds, file type,
and logical length must match the observed CloudAssets layout. It rejects
symlinks, unrelated entries, and pre-existing files; it never touches Photos
storage. This is an isolated cache-reclamation experiment, not a supported
CloudAssets cache API or production cleanup policy. Reopen/hash tests are
required to detect stale internal cache state after this intervention.

Version 8 accepts `rangeChunkBytes` (1-20 MiB, default 1 MiB) and reports
per-window elapsed seconds. Compare request sizes and `windowBytes` using
`ownedCache: true` and `releaseCompletedRequests: true`; confirm each owned
cache is removed and the complete original hash matches before adopting
throughput changes. Window size remains capped at 64 MiB.

Version 10 accepts `parallelRanges` (1-4, default 1). More than one submits a
bounded cohort of adjacent requests to the same loader, with each request
capped at 5 MiB and no more than 20 MiB of out-of-order payload held in memory.
Callbacks do not wait for earlier ranges; completed data is hashed in byte
order by the reader. `rangeTimings` records callback and drain times without
media URLs. Compare 5 MiB requests at parallelism 1, 2, and 4 with the same
60 MiB owned window, then verify the full original hash and cache teardown.
Keep the iCloud QUIC-blocking rule enabled during every comparison.

Version 11 extends the diagnostic cohort limit to eight (40 MiB of payload).
Error reports include at most three underlying error domain/code pairs, with
no error descriptions, user-info dictionaries, or credential-bearing URLs.
The production reader and its request limits are unchanged.

For video modes, `delivery: "automatic"` tests automatic rather than high
quality delivery. The undocumented numeric `streamingVideoIntent` is recorded
but not changed based on guessed enum values. File URLs are read as raw bytes;
HTTPS URLs use an ephemeral non-caching session. Compositions and custom URL
schemes are reported as unavailable for raw reading, without a transcoding
fallback. A readable HTTPS body is not proof of an original: compare its full
hash/length against `resource-local` or `resource-baseline` for the same asset.

`current.json` samples elapsed time, source progress, delivered byte count, free
space, and device-wide en0 counters each second. The final result is
`result-ID.json`. `completeSHA256` requires a clean EOF before cancellation and
the byte cap; `prefixSHA256` is not a full original hash. Set maxBytes above the
expected original size. Timeout is capped at ten minutes, bytes at 8 GiB, and
downloads cancel below 1 GiB free. Create `cancel.request` to cancel. If PhotoKit
does not acknowledge cancellation within 15 seconds, restart the diagnostic
app before another command to avoid overlapping experiments.

Use initially cloud-only, similarly sized resources for first-pass comparisons.
A later pass on the same asset is warm-cache unless locality is re-established.
Do not delete or purge the user's Photos cache to manufacture a cold state.
Record both cold state and full original hash comparisons. Device-wide traffic
and PhotoKit progress alone do not prove same-resource network overlap. A full
local file at AV delivery can rule out a bounded raw-file path for that run.
