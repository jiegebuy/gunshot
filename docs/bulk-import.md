# Bulk import and HEIC troubleshooting (0.2.2)

## Import an album

Open **GoToHP settings → Uploads → Choose album**. Smart albums and user albums are listed; folders open their child albums. Confirm the album's accessible item count to start. Folders are navigation containers, not recursive upload selections. Limited photo-library permission may hide albums or exclude photos; grant access to the intended originals first.

The album path uses a PhotoKit fetch result instead of returning thousands of results from PHPicker. A bounded pool of up to 12 workers prepares originals. One worker prepares videos; the others prepare photos. The video worker borrows photos after exhausting videos. This bounds PhotoKit's unmeasured full-video caching before data callbacks arrive. Only one preparation batch may run in the host process. Queued upload concurrency remains controlled by the upload setting. The normal photo picker permits 100 selections per invocation; that is an application limit, not an Apple-documented threshold at which the picker fails.

Keep Google Photos open while preparing. **Stop preparing** takes effect after the current original; already queued jobs continue subject to upload conditions. An expired background task stops preparation. Reopen the app and select the remainder; normal account/quality/content deduplication avoids repeating jobs already in the queue. Pending selections that have not reached the durable queue do not survive process termination. Preparation stops if the destination changes or the service is unavailable. Before starting an export, storage pressure waits for recovery; partial originals that cannot fit are deferred individually. Read-only account, source and capacity checks remain available during a backend storage fault.

An inaccessible identifier or an individual original-export failure is counted separately and does not abort the rest of the selection. Media classification runs off the main thread in pages of 256 and matches results by identifier, not by returned order. Only identifiers cross into preparation workers; each worker fetches its own PhotoKit asset. HEIC/HEIF resources are copied without conversion to JPEG. Live Photos retain the original still and paired video. This change does not weaken upstream's pairing checks or claim that an incomplete Live Photo was uploaded.

Completed exports use separate serial copy lanes for files totaling at most 32 MiB and for larger originals. A 128 MiB small-file allowance keeps photos entering the upload queue while an oversized video occupies its normal budget; the 128-job limit and physical free-space reserve still apply. Capacity uses actual filesystem free bytes, not purgeable estimates. Each export chunk atomically reserves its immediate write and future queue copy across all workers. Admission transfers the completed export's reservation to the copy lane without double-counting; failures release unused reservations after cleanup. A copy lane defers work that would wait on exported files behind it. Background progress includes metadata scanned, PhotoKit/cloud progress and bytes actually copied into the queue.

## What the reports establish

[Issue #21](https://github.com/tqmane/gunshot/issues/21) reports that selecting about 2,000 photos fails while five work. The attached screenshot shows **Unable to Load Items** in the system picker. Two 7.20.2 diagnostics show 114 completed and one failed job, with no new import history. This is consistent with a picker failure before its completion callback, not evidence of 2,000 failed HTTP uploads. Cancel that picker and use the album path.

The separate HEIC report has 60 completed, eight failed and one cancelled original-quality job. The old diagnostic schema does not identify their media formats or failure reasons, so it cannot establish that all 60 HEIC transfers failed, nor identify the cause of the eight failures. The account and transport were connected. The new diagnostics separate:

- `batchImport`: the most recent host preparation's source, stage, counts and fixed failure/stop codes. This describes import into the queue, not successful cloud storage. It is in-memory and resets when the app process exits.
- `completionMonitor.uploadSummary.mediaTypes`: persisted queue counts grouped as HEIC/HEIF, HEIC Live Photo, other Live Photo, JPEG, PNG, video or other, plus allowlisted failure codes. Filenames, identifiers, raw error messages and tokens are not included.
- `photosIntegration`: native synchronization requests/waits. A queue job marked completed is not proof that Google Photos has already refreshed its grid or that quota treatment was verified.

After reproducing a problem on 0.2.2, export diagnostics before restarting the app. For a failed HEIC job, inspect the queue's error and retry after resolving photo access, iCloud, network or account conditions. An uncertain commit needs cloud-side checking before retrying. No new real-device HEIC failure was reproducible from the aggregate report alone; device/server verification remains necessary.

## Regression coverage

- 2,000 selected identifiers, bounded fetches, reordered/missing results, individual export failure, account change, cancellation, unavailable IPC, queue rejection and retry.
- Photos following blocked videos still prepare; small copies finish while a large copy is blocked; concurrent copies respect disk reservations and recover from space loss or append failure.
- 60 HEIC/HEIF original resources including a Live Photo through the real exporter and chunked importer against PhotoKit/IPC fixtures; every source byte and timestamp is compared. A second run makes one original unreadable and verifies the other 59 are queued. These fixtures test byte preservation and orchestration, not image decoding or Google's servers.
- Media/failure diagnostic aggregation and privacy, plus existing serialized Pixel XL / policy 3 commit tests.
- UIKit presentation/translation checks and builds for jailed, rootless and rootful.

On-device follow-up: an album of 2,000 mixed originals; 60 real HEIC/HEIF photos; Live Photos; cloud-only originals; limited/full photo access; low disk space; cancel/reselect; and app closure during preparation. Verify actual cloud items, original downloads, pairing and native display independently.
