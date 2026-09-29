# iCloud original streaming research

Research date: 2026-09-29. Scope: deliver original iCloud network bytes to the
existing Google uploader before the whole original arrives on the device.
This includes an isolated physical-device experiment, not a new capability in
the installed production v40 uploader.

## Recommendation

The private PhotoKit player-item loader now has verified original-byte range
reads on one iPadOS 27 device. An isolated 20 MiB-window experiment also
reclaimed completed temporary ranges while preserving a matching full original
hash, with about 74 MB peak additional temporary storage for a 248 MB video.
Production cache ownership and durable upload recovery still need integration
and verification. This evidence updates the earlier
conclusion that only an HTTP source had a concrete path forward. See
[PhotoKit experiment results](../../experiments/photokit/RESULTS.md).

An alternative is an iCloud Photos HTTP source using the released rclone API as the
starting point. Keep the existing gotohp Google upload and library-commit path.
There is no requirement to replace that destination with rclone's Google
Photos backend or to run a NAS. An in-app Go integration is a candidate;
its iOS build, authorization UX, and background behavior still need validation.

The proposed data path is:

```text
iCloud Photos records/lookup -> fresh original downloadURL
    -> bounded HTTP Range reader
    -> existing streaming queue and Google Scotty acknowledgements
    -> durable hash checkpoint -> reclaim acknowledged disk blocks
```

This bypasses PhotoKit's original-download cache for this source. The
application can pause its HTTP reader or request only the next bounded range
while Google catches up. TCP/TLS buffers are additional memory, but no complete
original file is inherently needed for the source transfer. Achieving this in
gotohp requires implementation and a real-account experiment.

## Verified Upstream Support

Rclone **v1.75.1**, released 2026-09-04, contains iCloud Photos support. The
release tag resolves to commit `687d264b689b8c49a67e2e52a8a5e0caa01c04ce`.
This is not just an unreleased branch or an iCloud Drive-only feature.

- `service = photos` exposes personal/shared photo libraries and albums.
- `api/photos.go` selects `resOriginalRes` for an original. Live Photo video,
  RAW alternatives, and edited renders have separate resource keys.
- `PhotosObject.Open` calls `LookupDownloadURL` on each open, applies Range
  options to an HTTP GET, and returns the response body as `io.ReadCloser`.
  It does not download a complete local media file first.
- `LookupDownloadURL` refreshes a URL using CloudKit `records/lookup` and the
  record, library zone, and resource key. A URL is not a durable resource ID.
- `api/session.go` includes Photos-specific PCS cookies and trusted-device
  approval through `requestPCS` for Advanced Data Protection (ADP).
- The documented FUSE `--vfs-cache-mode full` example adds a media cache.
  That example is not the intended integration; use the HTTP reader directly.

The inspected `icloudpd` implementation independently demonstrates original
URLs and `Range: bytes=<start>-` with a streaming response. Its current docs
still exclude ADP. That limitation must not be generalized to current rclone,
whose released docs and Photos-specific PCS implementation support it.

## Authentication and Source Identity

The rclone route needs a separate Apple web session: Apple account sign-in,
2FA, and `Access iCloud Data on the Web` enabled. For ADP, trusted-device
approval may additionally be required. Do not require disabling ADP based on
the older icloudpd documentation. Session/PCS renewal may require user action;
unattended access cannot be promised indefinitely.

Photo library permission does not expose reusable Apple web-session cookies.
Do not extract native iCloud credentials or silently reuse unrelated browser
sessions. Keep any newly authorized session in private credential storage;
never include cookies, signed download URLs, or passwords in diagnostics.

Resource identity must include the Apple account/library, zone/area, record,
resource key, expected size, and an available resource version/fingerprint.
Do not assume a PhotoKit local UUID or `PHCloudIdentifier` string equals the
web CPLMaster record name. Do not match by filename alone. Initially a separate
iCloud album source is easier to validate than transparent mapping of every
existing PhotoKit selection. Existing completed receipts and ambiguous Google
commits still need reconciliation before this becomes a bulk import source.

Only explicitly selected original resources qualify. `resJPEGFullRes`, video
playback derivatives, and alternate RAW representations must not silently
replace the originally selected resource. Treat Apple's `fileChecksum` as
opaque version evidence until its algorithm/semantics are verified; do not
assume it equals gotohp's SHA-1 or SHA-256.

## Recovery Work Still Required

Rclone supplies useful HTTP and authentication machinery, not the complete
gotohp durable transfer contract. In the inspected release, `PhotosObject.Open`
accepts both HTTP 200 and 206 and returns only the body; it does not itself
require a matching `Content-Range` for a nonzero resume. Its `Hash` method
returns `hash.ErrUnsupported`. The adapter must retain response metadata and
perform these checks before allowing bytes into a previously released spool.

1. Use bounded ranges and request identity encoding. Require HTTP 206 and an
   exact `Content-Range` start/total on nonzero resumes. Reject an ignored Range
   response (HTTP 200), unexpected encoding, incorrect body length, and
   inconsistent size. HTTP 416 alone is not proof of successful completion.
2. Refresh an expired URL through the same record/resource lookup. Compare
   version evidence and size before using a replacement URL. Stop on a changed
   original; do not combine an old uploaded prefix with a new resource tail.
3. Persist source identity, hash state, and the durable local receive boundary.
   Distinguish downloaded bytes, Google-acknowledged bytes, and released bytes.
   Resume downloads after the durable local boundary, with upload recovery
   independently querying the same Google session's acknowledged position.
4. Add source-specific recovery to `internal/service/streaming.go`. Today's
   `resumeStream` resets verification to zero and requires a full PhotoKit
   replay. A Range-capable source cannot just submit a nonzero append or set a
   counter: restore validated prefix hash state and rehash the retained tail,
   bound to unchanged source identity and the existing upload checkpoint.
5. Preserve the fail-closed behavior of `GotohpCore/stream_spool.go.txt`: a
   missing, replaced, expired, or rewound Google session must never upload
   holes as zero bytes. A fresh original download can start a new precommit
   transfer, but not blindly retry `commit_outcome_unknown`.
6. Keep EOF, final-byte handling, original hashes, and the library commit in
   the existing destination pipeline. A successful download is not a Google
   library completion receipt.

The 65 MiB window is per producer, not a whole-app memory/disk limit. Start the
experiment with one remote video and a global budget. A fallback to PhotoKit
must not silently download a multi-GB original while promising bounded storage.

An in-process HTTP reader is also subject to iOS suspension. Range checkpoints
allow it to continue after rescheduling; they do not make a killed application
execute continuously. Background scheduling is a separate integration concern.

## New Apple APIs Checked

### Existing resource callback

The iOS 27 `PHAssetResourceManager.h` still has no byte-offset/length option for
`requestDataForAssetResource`. Callback chunks are not a guarantee of chunks
delivered directly from the iCloud network. Private cache-policy option names
are not enough to establish that guarantee either.

### PhotoKit background upload extension

Apple provides `PHBackgroundResourceUploadExtension` from iOS 26.1, replaced
by the async `PHBackgroundResourceUploadJobExtension` in iOS 27. It delegates
resource uploads and scheduling to the system and may improve lock-screen and
background reliability.

However, Apple's guide says the system downloads asset resources before
processing. It does not promise bounded iCloud download-to-upload streaming.
Its resumable protocol is the IETF draft with OPTIONS capability detection,
HTTP 104, and Upload-Offset, not Google's Scotty protocol. It is not a direct
substitute for the current resumable uploader. Protocol interoperability,
library commit handling, extension signing, and actual disk usage would all
need independent tests. A protocol relay is conceivable but does not by itself
remove the system's source-cache behavior.

### iOS 27 exported CloudKit assets

`PHAssetResourceManager.exportedAssetID(for:)` can reference an existing iCloud
Photos original without copying its bytes locally. Apple documents
`CKAsset.ExportedAssetID` as enabling a server-side CKAsset copy, potentially
between containers. It is valid only on the originating device and expires
after a few days; it is not a downloadable URL that can be handed to Google.

A possible longer-term route is a same-device import into an app-owned
CloudKit record, then an authorized CloudKit download/relay to Google. That
would require an app CloudKit container and signing capabilities, validation of
asset-size/quota/ADP constraints, and a separate server/API design. No working
end-to-end transfer was established here. Do not reject it as impossible, but
do not present it as a working solution for the current sideloaded application.

## Acceptance Experiment

No Apple web credentials were requested and no separate iCloud web HTTP
original was downloaded. An independent PhotoKit Probe app was installed and
tested; the production Google Photos v40 binary was unchanged. Existing v40
evidence proves reading/upload/reclamation overlap only. The new isolated
loader evidence is recorded separately and is not a Google upload test.

For the proposed source, acceptance must include:

- Fault-injected HTTP tests for ignored/malformed Range responses, URL expiry,
  changed originals, short bodies, crashes, and lost Google sessions.
- A user-authorized original's initial small range and a nonzero range, with
  overlapping bytes matching. Do not log the signed URL or response cookies.
- A cloud-only video: first Google acknowledgement while that source's actual
  HTTP received bytes remain below its total size. Correlate by job and source,
  not device-wide traffic or PhotoKit progress percentages.
- Pause/restart with the same source version: resume both sides from their
  respective durable offsets, keep allocation bounded, and verify full original
  content before the final library commit.
- Validation of original/Live Photo/RAW identity and existing completion records
  before enabling the new source for a whole album.

## Sources

All were read during this investigation. Rclone links are pinned to the
released tag, not its moving default branch.

- [Rclone v1.75.1 release](https://github.com/rclone/rclone/releases/tag/v1.75.1)
- [Rclone iCloud configuration and ADP](https://github.com/rclone/rclone/blob/v1.75.1/docs/content/iclouddrive.md)
- [PhotosObject.Open and Hash](https://github.com/rclone/rclone/blob/v1.75.1/backend/iclouddrive/icloudphotos.go)
- [Resource selection and LookupDownloadURL](https://github.com/rclone/rclone/blob/v1.75.1/backend/iclouddrive/api/photos.go)
- [Photos PCS cookies and approval](https://github.com/rclone/rclone/blob/v1.75.1/backend/iclouddrive/api/session.go)
- [Client authorization and renewal](https://github.com/rclone/rclone/blob/v1.75.1/backend/iclouddrive/api/client.go)
- [icloudpd streaming/Range source](https://github.com/icloud-photos-downloader/icloud_photos_downloader/blob/master/src/pyicloud_ipd/services/photos.py)
- [icloudpd authentication limits](https://github.com/icloud-photos-downloader/icloud_photos_downloader/blob/master/docs/authentication.md)
- [iOS 27 resource-manager header](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS27.0.sdk/System/Library/Frameworks/Photos.framework/Headers/PHAssetResourceManager.h)
- [Apple background resource upload guide](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background)
- [Apple exportedAssetID(for:)](https://developer.apple.com/documentation/photos/phassetresourcemanager/exportedassetid(for:))
- [Apple CKAsset.ExportedAssetID](https://developer.apple.com/documentation/cloudkit/ckasset/exportedassetid)
- [Apple CKAsset.init(importing:)](https://developer.apple.com/documentation/cloudkit/ckasset/init(importing:))
