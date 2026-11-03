# 0.1.1 development verification

On 3 November 2026, all 32 verification groups passed against commit `5dcab259ff572d4c77a840c40642a82389ec48ce`. The source remained unchanged during the run. Python ran 20 tests, with one inherited legacy callback test explicitly skipped. Scoped reliability and versioning reviews cleared all blocking findings.

Native fixtures covered long and empty-file recovery, receipt publication failure and upgrade reconciliation, fresh snapshots after later requests, source exclusion, interrupted cleanup and journal migration, retained-byte hashes, endpoint restart, HTTPS rejection, and the existing media workflow. Destructive operations used newly generated repositories with identity and exact-target guards. Separate Windows sessions and physical machines were not tested.

The compiled application and package use `0.1.1`; Windows metadata uses `0.1.1.0`. A constructed main window reported `NetCrate 0.1.1`. Actual binary metadata, embedded manifests, malformed versions, strict tag matching, stale builds and a compiled `0.1.2` fixture passed. No release or tag was created.

All 53 packaged files matched the executable, source and version documents. The versioned archive and compatibility alias are byte-identical.

| Artifact | SHA-256 |
| --- | --- |
| `NetCrate-0.1.1-Windows-x64.zip` | `9ab6d015485a6c0c68ba9b9e5bdb825e58239d892ea590c07cda5573ecea7929` |
| Combined result summary | `8b83caaf4484a5d6e6b55abdafade9bf80d4212cc9c63312e9742dc3ab22baa4` |

Local commands, tool hashes, outputs and reviews are retained under `build/verification/0.1.1`. The [remaining work](experimental-roadmap.md) includes real-machine acceptance and [maintenance history saturation](https://github.com/duplainmedia/netcrate/issues/10). NetCrate remains experimental.

## NCS validation of merged main

Separate NCS validation reported results for merge commit `0bc86416c642c4377c243d30cb308c20887fd3f5`, version `0.1.1`. Ten desktop groups, package verification, local pairing, folder/media workflows, recovery, interrupted cleanup, reconnect and append-only deletion protection passed. The initial script suite passed 28 of 29 groups. Python passed 19 tests with one inherited skip.

After correcting a missing recovery fixture, the bridge exposed a Windows PowerShell 5.1 bootstrap extraction failure at a 266-character path. Fresh shorter-root recovery and bridge checks passed. [Issue 13](https://github.com/duplainmedia/netcrate/issues/13) tracks the unfixed limitation. These reported results do not validate PR 12.

Source-PC pairing, changed-version backups/restores, physical network/storage interruptions, separate-account recovery, reboot/sign-in, tasks, firewall and cross-session acceptance remain outstanding. Existing backups, credentials and configuration were preserved; no reboot or live firewall/task changes were reported.
