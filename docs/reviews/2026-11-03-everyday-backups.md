# Everyday backups: whole-branch review

**Range:** f50962a0c925f76519f66c54fe8dbc1f8aac81ff..ff8001413094e515101c3ee1f12a8d16c2e0f279. **Gate:** merge to the private release-preparation branch, not release to main.

## Strengths

- The implementation retains the media default for missing legacy fields while making Folder explicit for new setups. Pairing authenticates the requested mode and server capability; ordinary jobs skip media tools, polling and Results publication.
- Native exit status and the full snapshot ID are checked before checkpointing originals. Recovery selects immutable IDs, validates stored metadata, privately stages only selected members, verifies extracted bytes and publishes with a no-overwrite rename. The output does not inherit a historical user's ACLs.
- The server, not the remote client, owns destructive maintenance. Exact candidate IDs, dependency signatures, protected local bindings, endpoint quiescence, repeated inventory validation, and separate forget/prune journaling meaningfully limit the effects of a stale or interrupted request.
- The checked-in fixtures assert native restored bytes, exact retained snapshot sets, replay rejection and survival of a closed foreground window. The verification note distinguishes real native operations, simulated adverse conditions and outstanding machine acceptance.

## Issues

### Critical

None identified. I did not find a path in the reviewed legitimate flows that silently overwrites a recovery destination or forgets a snapshot outside the confirmed candidate set.

### Important

1. **A valid filename can make an entire backed-up directory impossible to recover in the app.** `src/shared/NetCrate.Workflow.psm1:99` accepts each entry via the local-path check; `src/shared/NetCrate.Restore.psm1:96` checks every sibling using the relative-path validator, which rejects components longer than 240 characters (`src/shared/NetCrate.Configuration.psm1:76`). A read-only probe with a 241-character leaf under `C:\a` (246-character full source path) passed the precise backup validator and failed the precise recovery validator with “The media filename is not supported.” This is within ordinary Windows component limits. The rest of that directory, including a short-named sibling, also becomes unbrowseable because validation runs over the entire tree node list. Align backup and restore name support; prefer supporting these ordinary names, retain traversal/link/ADS/collision rejection, and test native date browsing and restore of both the long name and its short sibling. If any class must remain unsupported, reject it before a successful backup with a useful explanation.

2. **The dashboard can announce a backup that the recovery browser cannot open.** At `src/shared/NetCrate.Workflow.psm1:159` the ID and completion timestamp are persisted before `Write-NetCrateBackupReceipt` at line 165. If the drive disconnects or receipt writing fails there, the queue retains that checkpoint for retry. `src/desktop/GuidedModel.cs:36` already treats it as a success, `src/desktop/AppModel.cs:110` can notify “Backup completed”, but `src/shared/NetCrate.Restore.psm1:155` correctly hides that same v2 snapshot until the receipt exists. If the source is then lost, its advertised recovery date is unavailable through independent recovery. Retain the early checkpoint to prevent a second originals backup, but distinguish “originals written; finalizing backup” from positively receipted success in dashboard/history/notifications. Mark success after receipt publication independently of Results/media and preserve older record semantics. Fault the Primary receipt write after a successful original, check last success and notifications as well as ListBackups, then retry and prove the same ID becomes available.

3. **An interrupted prune cannot be finished by following the supplied retry instruction.** After forget is verified, prune may fail, leaving unreferenced data consuming space (`src/shared/NetCrate.Maintenance.psm1:350`). The UI tells the operator to create a new preview (`src/desktop/MaintenanceView.cs:55`). With the previous candidate IDs already forgotten and no newer backup, the new preview has zero candidates. Apply marks the new operation Completed and returns before prune (`src/shared/NetCrate.Maintenance.psm1:331`). This especially hurts on a nearly full drive: the operator sees successful completion and is unable to reclaim the space without a subsequent unrelated removal. Support a separately previewed, deliberate cleanup of a **verified previous forget** under renewed owner, inventory, dependency and endpoint checks, with no repeat forget and no automatic pruning. If the journal is ambiguous, retain NeedsAttention and give an honest recovery instruction, not a successful no-op. Exercise confirmed forget → interrupted prune → no new candidate → resolved cleanup, with retained-byte verification.

4. **The source queue lock is local to one Windows session, not to the installation.** `src/shared/NetCrate.Schedule.ps1:11` uses a Local named mutex. A dashboard running under the same Windows account in a second session and a signed-in scheduled pass in the first session can both observe no active job and both admit a job for the same folder. The same namespace limitation applies to the source runtime lock at `src/shared/Invoke-NetCrateRuntime.ps1:12`; only Worker gets the cross-session guard at line 21. Task Scheduler's IgnoreNew setting prevents duplicate instances of its one task, but does not serialize the two independent UI/scheduler admissions. Use a shared owner/installation-scoped mutex across sessions for source admission and runtime ownership (as for Worker); keep the admission lock short. The existing four-process fixture runs within one session. Add a regression verifying the shared namespace and exclusion across independent participants; physical multi-session operation, if tested, should be labeled separately.

5. **The source discards the actionable cause of ordinary backup failure.** `src/shared/NetCrate.Queue.ps1:104` catches all failures, records only NeedsAttention/retry time, and drops the cause. For example, a linked child or online-only placeholder produces a specific, locally known validation error at `src/shared/NetCrate.Workflow.psm1:98`; the dashboard instead always tells the user to check the source, connection and server storage (`src/desktop/GuidedModel.cs:45`). The system retries the exact same unsupported tree every 30 seconds, and following its displayed advice will not fix it. Persist a bounded, non-secret category at the failure site (e.g. unsupported link/placeholder, inaccessible or partially read source, storage unavailable), map it to a concrete user action, clear it on success, and preserve previous success. Do not copy raw native stderr into the queue/UI. Cover a locally rejected entry and native incomplete-read case through to the dashboard.

### Minor

- **Storage dates are difficult to read.** `src/desktop/MaintenanceView.cs:51` and `src/desktop/setup/SetupState.cs:131` print wire-format UTC strings, including fractional seconds, in health details and preview rows. Format a short local date/time with a zone for display; keep canonical UTC for comparisons.
- **The developer guide overstates retention guarantees.** `docs/development.md:35` says no operation deletes earlier backup snapshots; the new explicitly confirmed server retention action does. Qualify the statement as a guarantee of media generation/delivery and distinguish it from Folder retention.

## Review and verification scope

Reviewed the supplied 72-file package in passes covering docs/setup; desktop/action bridge; process, configuration, pairing and transport; original completion, recovery, schedule/queue, maintenance and tests. No second full diff was generated. For concrete cross-file risks I read the surrounding path validators and tree traversal (backup/restore mismatch), whole queue state and dashboard projection (premature notification/missing error), and runtime mutexes and task settings (source writers in separate sessions). The only executable behavior probe was the in-memory validator comparison described above. HEAD matched the requested hash; there were no tracked worktree changes. The controller's recorded 26 passing groups, package byte-match and subsequent foreground fixture are evidence for their covered scenarios; none is represented as rerun by this reviewer. No target repository operation or host installation was performed.

## Recommendations

Make the five Important cases focused regressions and resolve them before merging this head. Rebuild and verify the resulting private artifact after product changes. Keep the current physical-machine acceptance checklist separate.

## Declined to judge

- Two physical Windows machines, first use on a distinct account, private network routing, live task/firewall setup, reboot/sign-in and recovery under another real account: explicitly reserved for step 6; the fixtures do not substitute for that acceptance.
- Signed-out operation, multiple source/server pairs, automatic certificate rotation and public release: outside the approved signed-in, one-pair private milestone.
- Administrator/same-user compromise and a full cryptographic/security audit: not part of this integration review. The review did consider normal owner bindings, current-user DPAPI, secret handling, append-only access and destructive-operation exclusion.
- A full-data health scrub, unlimited retention inventory, and exact reclaimed-space forecasts: the current UI/docs explicitly describe metadata-only coverage and finite preview limits, and the product promises no exact deduplication savings.
- Fast recovery at production scale: per-file independent verification costs native launches and extra reads/staging. This is disclosed and no representative throughput target or physical-machine dataset was supplied; the supported-name correctness issue above is independent of speed.
- Enrichment of unknown legacy originals using historical media evidence: explicitly recorded as deferred; legacy recovery remains available with unknown completion and retention protection.

## Assessment

**Ready to merge? No, at ff80014.** The architecture and native fixture evidence support the core approach. Fix the integration gaps above, especially recoverability of a successful backup and truthful completion reporting, before advancing the private branch. This verdict does not require performing step 6 first.
