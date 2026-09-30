# V42 observation and V43 throughput changes

Physical iPad13,8, iPadOS 27.0, 2026-09-30. Target: approximately 5 MB/s.

## V42 installed and measured

V42 (1621b4f) preserved eight resumable jobs and all twenty private checkpoints
across installation. Queue state, settings, and both completion receipt logs
matched their installation baselines. The settings fixture needed the new
metadata-eligibility stub (1727bfe); the subsequent complete CI passed:
https://github.com/jiegebuy/gunshot/actions/runs/36680972319

After the user restarted the original album, two photos.googleapis.com
connections sent 41,800,400 and 77,747,253 bytes in 60.0947406 seconds. Their
combined sustained rate was 1,989,320 bytes/s, versus the earlier 175,644
bytes/s observation. The proxy policy remained cn2. This is an observed
improvement, not an isolated attribution to any one code change.

Two old originals resumed from nonzero offsets and retained stable session
fingerprints during observation. Their Google offsets repeatedly caught up
to within 256 KiB of the received source prefix. After the third available
stream finished, the two remaining range sources supplied about 1.4 MB/s
combined. The next bottleneck was therefore source supply during these
samples, not a queue waiting behind unacknowledged Google bytes.

## Source-only comparison

The normal album was stopped before running the independent probe. The same
128,559,955-byte original remained locally unavailable before and after all
three range runs. Each owned cache was removed at window completion; the
general temporary directory remained empty. Runs were sequential, so upstream
cache warmth and network variation are not controlled.

| Request | Window | Seconds | MB/s | Sampled peak owned cache |
| --- | --- | --- | --- | --- |
| 1 MiB | 20 MiB | 100.717 | 1.276 | 59,568,128 bytes |
| 20 MiB | 60 MiB | 60.957 | 2.109 | 125,980,672 bytes |
| 1 MiB | 60 MiB | 79.971 | 1.608 | 173,232,128 bytes |

All complete hashes matched a subsequent ordinary PhotoKit original request,
which took 18.206 seconds and made the original locally available:
`ba057a9c1a1730cd9906563cb1147cd9a659fd08f6af38ae61e24b926a2e1565`.

Local evidence is in `.build/photokit-results/result-speed-v8-*.json` and
`.build/upload-route-20260929-235948.json`. Media identities and credentials
are intentionally excluded here.

## V43 implementation

Use 20 MiB range requests and 60 MiB reader windows; keep the initial identity
probe at 1 MiB. Album preparation and streaming uploads reserve half the user's
configured concurrency, capped at four. The process-wide range-reader cap is
also four. Full-resource video reads remain serialized; photo preparation and
ready-file uploads retain independent capacity. Queue data remains bounded at
65 MiB per producer. Source caches are separate additional storage, reclaimed
only after durable consumption and window teardown.

The larger source window and four concurrent producers require a new
physical-device upload measurement. The source-only comparison does not
establish 5 MB/s end-to-end throughput.

## Production reader and installation checks

The v9 probe used the exact V43 reader on a separate 139,955,954-byte original.
It completed the full read in 77.150 seconds. After restarting the probe, a
read from 59,768,832 (57 MiB, deliberately crossing the new window boundary)
delivered the remaining 80,187,122 bytes with the same source version. The
full hash and resumed tail hash matched independent ordinary PhotoKit reads:

- Full: `9f08ecef2379a67a2eff8bc42c94b44b027d8d946d418fd8ee5a23278d433bb2`
- Tail: `12f76389d1acdf875817326673ee75564d5465dfdf6bc03d9ab14c46503f556f`

The general temporary directory and owned range-cache directory were empty
afterward. Other probe cache files were left alone. Local evidence:
`.build/photokit-results/result-speed-v9-*.json`.

All V43 CI jobs passed at 1515ce3:
https://github.com/jiegebuy/gunshot/actions/runs/36683254358

V43 was installed and launch-verified. Eight interrupted jobs and twenty
private checkpoint hashes/retained-file allocations matched the pre-install
baseline exactly. Queue state, options, 21,043 source receipts and 20,756
fingerprint receipts were preserved. Signed package SHA-256:
`8bfc2252de1719543483ca666b5448a5fd4befc01bf46ed98b2612ced7c27aea`.
