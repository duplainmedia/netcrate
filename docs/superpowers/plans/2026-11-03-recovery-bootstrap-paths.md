# Recovery bootstrap paths implementation plan

Use `superpowers:executing-plans` for inline implementation and one independent final review. The user authorized autonomous work and a separate PR.

Fix [issue 13](https://github.com/duplainmedia/netcrate/issues/13). Windows PowerShell 5.1 fails on ordinary deep extraction paths even though PowerShell 7 succeeds. Validated ordinary local paths must stay the public interface. Use extended Windows paths only at file I/O boundaries under PowerShell 5.1; preserve normalization, link rejection, integrity checks, archive bounds, private ACLs and staged publication. No system settings or production state changes.

PR 12 is open. Branch `codex/recovery-bootstrap-paths` starts at its head `2ed645c3dce4274a358964d37d6cd490a01c17cc`; use that PR's branch as base until it merges. The next development patch is `0.1.3` with no release or tag.

- [x] Add real PowerShell 5.1/7 regression fixtures for long and short paths, JSON records, dependency installation/retry/repair, integrity rejection, traversal/collision/link rejection and private permissions. Observe the long-path failure before implementation.
- [x] In `src/shared/NetCrate.Configuration.psm1`, add `ConvertTo-NetCrateFileSystemPath([string]$LiteralPath)` for validated I/O paths, check links using extended paths under 5.1, and use the adapter for JSON reads/writes. Keep canonical ordinary paths as returned values.
- [x] In `install/NetCrate.Dependencies.psm1`, apply the adapter at download/cache, extraction, stamp, hash and move boundaries. Keep package paths, relative checks, identity and publication behavior.
- [x] Add the regression to Windows CI. Run configuration/dependency checks under both hosts and the actual Windows PowerShell 5.1 recovery bridge on fresh short and long OriginalsRestore fixtures with pinned verified archives. Verify recovered bytes and private ACLs.
- [x] Run desktop suites, versioning and packaging. Set `VERSION` to `0.1.3`, update Unreleased notes and the roadmap with actual evidence. Retain physical-machine acceptance as outstanding.
- [ ] Obtain independent review, push and open the separate PR. Verify Windows CI, leave merge to the user and retarget to main if PR 12 merges during this work.

Review focus includes linked ancestors beyond the legacy path limit, existing package repair, literal Unicode/bracket names, file/directory collisions, and metadata publication through long paths. Tests exercise file effects and byte hashes, not source text.
