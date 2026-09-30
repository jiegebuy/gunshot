# V45 bounded range pipeline

Physical iPad13,8, iPadOS 27.0, 2026-09-30. All tests below kept the
existing iCloud UDP/443 rejection module enabled. A live check found zero
allowed iCloud QUIC connections. The target remains sustained 5 MB/s upload.

## TCP range experiments

One cloud-only original, 247,546,555 bytes, was read repeatedly using owned
60 MiB cache windows. Adjacent requests were 5 MiB. Probe v10/v11 waited
for each batch before scheduling another batch; v12 uses the production
rolling pipeline. These sequential trials are subject to network variation.

| Reader | Seconds | MB/s | Outcome |
| --- | ---: | ---: | --- |
| One request, v10, first run | 109.279 | 2.27 | Complete |
| Four requests, v10 | 86.339 | 2.87 | Complete |
| Two requests, v10 | 112.948 | 2.19 | Complete |
| One request, v10, retry | 127.436 | 1.94 | Complete |
| Eight requests, v11 | 103.960 | 2.38 | Complete |
| Four requests, v11, repeat | 95.121 | 2.60 | Complete |
| Production rolling reader, v12 | 88.467 | 2.80 | Complete |
| Ordinary PhotoKit resource reference | 24.444 | 10.13 | Complete |

All complete reads produced SHA-256
`755a2b960330ecea37d9718d5ca6f51e62dee760ba90556d704134733c47667c`.
The ordinary resource reference was deliberately run last, to avoid warming
the Photos original before the range trials. Its first data arrived after
24.062 seconds; the new production reader's first data arrived after 11.732
seconds. The production range trial started and ended locallyAvailable=false.

A separate one-request trial failed after 110,100,480 bytes with
CloudAsset.AssetManager.AssetError code 0. The cause is not established; it
is excluded from throughput comparisons, not hidden as a successful retry.
An earlier original_not_found result was a diagnostic input typo.

The results do not justify increasing concurrency to eight. They also do
not establish sustained end-to-end upload improvement over v44. Ordinary
PhotoKit's much faster full-original path and the previously observed
20-50 ms TCP setup times support investigating range scheduling/delivery
overhead rather than blaming all multi-second gaps on HTTPS connection setup.

## Production change

Commit 5a8faca replaces the sequential 20 MiB request adapter with a rolling
queue of at most four adjacent 5 MiB requests. Resume requests align to the
next 5 MiB boundary. Loader callbacks only buffer bounded data. The import
thread validates source identity and persists bytes strictly in file order;
it then refills the queue without waiting for the entire previous batch.

Each source has at most 20 MiB of application-owned range payload queued.
The existing four-source admission limit and 60 MiB cache windows remain.
This is not a total process RAM or total PhotoKit disk-cache limit. In the
diagnostic batch trials, sampled owned allocation exceeded the window size
(about 182 MB for four requests and 203 MB for eight). Runtime free-space
guards and ownership-checked cleanup remain required.

Errors do not advance the consumer checkpoint. Cancellation is sent to all
pending requests before waiting, with a shared 15-second drain deadline.
Unconfirmed cancellation prevents subsequent sources in that process.
There is no automatic retry of uncertain Google commit outcomes.

## Validation

- Foundation tests exercise deliberately out-of-order callbacks and a later
  request that can finish only after the next batch would have started. They
  check ordered output, the four-request bound, unaligned resume, duplicate
  completion, late data, short reads, overrun, remote/consumer errors,
  cancellation, timeout, and unconfirmed cancellation. AddressSanitizer passed.
- The exact production reader completed the full cloud original and matched
  the independent ordinary PhotoKit reference hash.
- A byte-cap cancellation at 70 MiB returned the expected interruption. In
  the same process, a subsequent read from 50 MiB completed the remaining
  195,117,755 bytes with the same sourceVersion. This exercises recovery after
  cancellation without clearing the process-wide cancellation guard. The
  diagnostic labels a nonzero-offset hash as prefixSHA256/readComplete=false;
  that label does not mean the requested suffix was truncated.
- General tmp was empty after the full read, cancellation, and suffix read.
  The post-range filesystem inventory found no owned range-cache files.
  It did find approximately 58.8 MB allocated in system-managed CloudKit and
  dyld caches, including sparse CloudKit files. These were not deleted and
  must not be reported as zero total cache usage.
- Core/race, ABI, exporter, cache ownership, range tests, and all package
  builds passed. The UIKit smoke job failed with "unchanged timer polls
  replaced the switch or moved the settings list". No settings code was
  changed in this patch; the complete workflow is not green.

Builds:
- https://github.com/jiegebuy/gunshot/actions/runs/36698976695
- https://github.com/jiegebuy/gunshot/actions/runs/36699157102

Local evidence is under `.build/photokit-results/result-speed-v10-*.json`,
`result-speed-v11-*.json`, `result-speed-v12-*.json`, and
`storage-v12-after-production.json`. The suffix trial overlapped a read-only
main-app checkpoint inventory and is not used as a speed measurement.

Signed v45 IPA SHA-256:
`42ce3b3889f76e3b9e9377a097b0fce64c0b022e7bc2e87ad01b2b80818475b9`.
Installation and real-album upload measurements are recorded separately below.

## Installation

V45 was installed and launch-verified (PID 29928). Before launch, all 23
checkpoint/spool hashes for nine retained jobs matched, as did their logical
lengths and allocated bytes. State was byte-for-byte unchanged after install.
After launch, settings, queue IDs, completionRevision 20765, all 21,052 source
receipts, and all 20,765 fingerprint receipts remained intact.

The existing 43 failed entries were preserved; this speed patch does not claim
to resolve historical commit-outcome-unknown entries. The original album was
stopped for installation. The user has been asked to start it again; sustained
Google acknowledgement throughput for v45 has not yet been measured.

Local installation evidence: `.build/v45-resume-before.json`,
`.build/v45-resume-after.json`, `.build/v45-state-before-install.json`,
`.build/v45-state-after-install.json`, and `.build/v45-launch-result.json`.
