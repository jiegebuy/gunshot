# Upload throughput investigation, diagnostics 27

Date: 2026-09-29. Installed source: bd0ecb0, v41 final.
This investigation did not modify the running queue, proxy policy, or application.

## Measurements

Diagnostics: `E:/Download/gotohp-upload-diagnostics-27.json`.

- HTTP body-read throughput: 140,356 and 150,186 bytes/s in the two
  exported 60-second snapshots. One active upload request and one active
  worker, despite configured concurrency 8. The batch has one preparation
  and 120 items remaining; it reports `waiting_upload_resume`.
- The active range-source video is 5,326,423,647 bytes. At 23:13:26 local,
  its received prefix was approximately 2.344 GB and the Google checkpoint
  was 2.279 GB. The producer was about 61 MiB ahead of Google, close to the
  bounded queue window. Source and Google checkpoints continued advancing.
- Current device free space was approximately 7.1 GB. The active queue file
  allocated about 60-76 MiB and owned PhotoKit range caches about 16-66 MiB
  in the samples. Large logical sizes of sparse cache files are not physical
  disk allocation. General tmp contained only the 16,906-byte diagnostic.
- The source version matched its durable checkpoint. Five versioned
  range-source jobs had completed, including a 1.595 GB video. This confirms
  that the production range path has been used successfully; the current
  slow transfer is not waiting to download its entire original first.

Surge sampling independently confirmed actual connection throughput:

- `photos.googleapis.com:443` used policy `cn2` over a ShadowTLS connector.
- The same Surge connection, ID 22196, remained active through all samples.
  Its outbound counter increased from 713,085 to 11,440,600 bytes over
  61.075 seconds: **175,644 bytes/s** (about 172 KiB/s).
- iCloud content connections used the direct policy and downloaded ranges
  while the upload continued. A prior `iCloud Photos TCP Test` rule still
  rejects their UDP/443 path; TCP connects succeeded. It does not match the
  Google upload destination and is not implicated by this measurement.
- Instruments networking monitoring for the application PID produced no
  connection samples, so no TCP loss/RTT conclusion is drawn from that tool.

Local evidence files, ignored by Git:

- `.build/v41-observation-20260929-231324/`
- `.build/v41-observation-20260929-231411/`
- `.build/upload-route-20260929-232159.json`
- `.build/network-observation-20260929-231638.json`

## Code findings

1. `UI/GSBatchImport.m:86` reserves video preparation for worker 0 only.
   The other workers prepare photos. Once photos finish, the remaining video
   backlog is processed serially, so raising the upload setting to 8 cannot
   create more ready streams. This restriction predates bounded cloud ranges.
   The range reader already has two process-wide slots, and
   `internal/service/streaming.go:171` permits two preupload workers at the
   current concurrency, but the album producer supplies only one video.
2. `GotohpCore/streaming_upload.go.txt:81` uses a fixed 8 MiB target, subject
   to server granularity and available data. It queries the session before
   each chunk, and `internal/service/streaming.go:241` adds a one-second
   scheduling delay after each successful preupload. The sealed-file path
   has adaptive chunk sizing; this path does not.
3. Each resumable request has a 90-second deadline. An 8 MiB chunk requires
   approximately 48 seconds at the measured connection rate, and cannot fit
   within that deadline below approximately 93,207 bytes/s before overhead.
   The diagnostics contain 13 historical upload-body timeouts, but their
   cumulative counters cannot attribute them to the current video.

The historical mean query latency is 270 ms and authorization latency 10 ms.
Those means and a one-second scheduler gap do not explain an otherwise fast
connection dropping to 176 KB/s. HTTP/2 is disabled and connection reuse is
present. Smaller chunks alone should not be presented as a guaranteed large
throughput improvement.

## Conclusion and next checks

The observed bottleneck is the single active Google upload path. Source bytes
are already available; free storage is sufficient and reclamation is advancing.
Serial album video preparation leaves total throughput exposed to that one
slow connection. Measurements identify the current `cn2` route, but do not
separate node capacity, the node-to-Google path, and Google session behavior.

Recommended follow-up work:

- Compare the same resumed upload over a user-selected alternate route while
  preserving the original session and restoring the original policy afterward.
  A generic speed test or a different computer is not an equivalent control.
- Permit a second eligible bounded cloud-video producer, retaining conservative
  limits for full-resource PhotoKit paths and preserving the global cache cap.
- Carry adaptive chunk sizing and failure shrinkage into streaming preupload,
  retaining server-authoritative offsets, durability, and explicit finalization.
- Measure acknowledged bytes, body-read bytes, source lead, disk allocation,
  and active connections together. Do not parallelize offsets of one Scotty
  session without a verified server contract.
