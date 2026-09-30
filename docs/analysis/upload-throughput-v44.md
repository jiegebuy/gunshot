# V44 throughput measurements

Physical iPad13,8, iPadOS 27.0, 2026-09-30. Target remains approximately 5 MB/s.

## Implementation and installation

Commit 79f8137 raises only the in-process embedded append limit to 8 MiB.
Streaming imports respect the existing 65 MiB queue window. Original fsync
and atomic source checkpoint persistence still precede successful append.
Per-job counters report accepted bytes, call count, Go mutex wait time, and
append processing time. They do not measure Objective-C GSCoreQueue wait.

V44 was signed, installed, and launch-verified. All 23 checkpoint/spool hashes
for nine retained jobs and all logical file lengths matched before launch.
Four retained sparse files allocated fewer blocks after the old process closed;
the strict allocation-equality helper therefore failed. No checkpoint hash or
logical length changed. Settings, queue identifiers, 21,047 source receipts,
and 20,760 fingerprint receipts were preserved. Four old range jobs subsequently
passed the production retained-tail hash check and resumed from nonzero offsets.

Signed IPA SHA-256:
`9b1d13df5848261da1e997030c442f701c512b6568aa9a10b625361a4cd681a2`.

Core/race, ABI, native exporter, cache ownership, and all package builds passed:
https://github.com/jiegebuy/gunshot/actions/runs/36686673401
The complete workflow is not green: the UIKit smoke fixture first timed out
during simulator installation; its retry reached the fixture but failed its
presentation deadline. Do not describe this as a complete regression pass.

## Observed bottleneck

In the first 93.1036-second four-stream observation, source prefixes advanced
99,614,720 bytes and Google acknowledgements advanced 103,809,024 bytes, about
1.1 MB/s. The extra acknowledgements drained bytes already present at the
start. Embedded append processing used 1.316 seconds across all four jobs;
measured Go mutex wait was 2,415 nanoseconds. This does not implicate append
processing as the dominant delay in this interval.

The subsequent 148.917-second, approximately one-second trace showed exact
5 MiB source delivery batches. Individual streams sometimes waited 10-35
seconds between batches. A later 15-second bucket reached 4.83 MB/s source
supply and 3.66 MB/s acknowledgement advance, without a code or route change.
The user's screenshot independently showed a 5.09 MB/s instantaneous upload
peak. Neither a peak nor a short bucket establishes sustained 5 MB/s.

TCP setup in sampled iCloud connections was usually 20-50 ms, with one
136 ms example. Larger application stalls require investigating range delivery
and request scheduling, not attributing the entire gap to TCP setup.

## Transport constraint and next experiment

A temporary transport comparison restored the existing iCloud TCP module in
its finally block. The user then explicitly required QUIC to remain blocked.
The live module was rechecked, other modules were unchanged, and no allowed
iCloud QUIC connection remained active. All further tests must keep it blocked.

The inspected iOS 26.1 CloudAssets implementation divides source requests into
5 MiB ranges. This is a hypothesis-generating reference, not proof that every
iOS 27 internal detail is identical. Probe v10 compares one, two, and four
adjacent requests on the same loader while retaining the 60 MiB owned-cache
window, at most 20 MiB of out-of-order memory, and ordered hash verification.
No such change has been made to the production reader yet.

Local evidence (ignored by Git):
- `.build/v44-observation-20260930-011956/`
- `.build/v44-timeline-20260930-012824.json`
- `.build/v44-network-timeline-20260930-013107.json`
- `.build/icloud-transport-ab-20260930-013607.json`

Implementation reference:
https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore/blob/main/System/Library/PrivateFrameworks/CloudAssets.framework/CloudAssets/CloudAssets.mm
