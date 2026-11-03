# Reliability fix continuation

> **For agentic workers:** Resume the interrupted repair with one implementation owner and scoped reviews. Use the systematic-debugging and test-driven-development skills. The user explicitly authorized autonomous execution without oversight.

**Goal:** Resolve open issues 2, 3, 4, 5, 6 and 7, add consistent application versioning and a public changelog, verify the resulting build, and prepare a follow-up PR.

**Architecture:** Keep the existing WPF, PowerShell and Restic implementation. Preserve early originals checkpoints, but distinguish them from positively receipted completion. Recovery, queue projection and notifications must agree. A deliberate cleanup retry must operate only on a verified prior forget and never repeat an ambiguous forget.

**Tech Stack:** Windows x64, C# WPF on .NET Framework 4.8, PowerShell 7.6.5, Restic 0.19.1 and the existing pinned native tools.

**Spec:** The requirements are the six remaining findings in [the whole-branch review](../../reviews/2026-11-03-everyday-backups.md) and the [experimental roadmap](../../experimental-roadmap.md). The documentation correction in issue 8 was already merged.

## Global constraints

- Work in the existing isolated clone on `codex/recovery-reliability-fixes`, based on merged main at `24b7f30f144b0c937a87cf94d8a9c90e2786cf69`. Do not modify the original checkout or main.
- Use generated data, new ordinary Temp roots, fixture markers, expected native repository IDs and exact targets. Never apply maintenance to an installed or production repository.
- Preserve append-only HTTPS, current-user DPAPI, owner/repository/source binding, immutable media, bounded native streams, UTF8 bridge handling and safe no-overwrite recovery without historical ACLs.
- Keep credentials and raw native diagnostics out of queue records, ordinary settings, command arguments and user-facing errors.
- Preserve legacy record semantics, missing-mode Media defaults, successful originals independently of later media failures, and the last successful recovery point after a newer failed attempt.
- Keep the experimental notice and real-machine acceptance limitations. No live task/firewall changes, repository visibility changes, automatic merge or supported-release claim.
- Prepare the follow-up PR for the user to merge. Use complete professional sentences without label fragments or unnecessary colons in its description.

## Review focus

1. A valid 241-character leaf and a short sibling must both browse and restore with exact bytes; unsafe names and links must still fail.
2. Receipt publication failure must not replace last success or emit a completion notification; retry must expose the same snapshot through independent recovery.
3. Verified forget followed by failed prune must permit a separately previewed and confirmed cleanup when no new candidates exist; ambiguous journals, stale previews and replay must fail closed.
4. Source admission and runtime ownership must use a shared owner/installation namespace and exclude independent contenders. Same-session tests must not be reported as actual separate-logon acceptance.
5. Unsupported source entries and native incomplete reads must retain a bounded useful failure category through to the dashboard without leaking diagnostics.

## Fix wave

This continues the prior interrupted fix wave rather than splitting shared queue/runtime work among parallel writers. The prior partial filename patch is saved in stash `7bfc88d177d34a56ef7d1fe0e1743a1fd6b83c55`; it is unverified and must not be blindly applied.

### Recovery and completion truthfulness

**Files:** `src/shared/NetCrate.Configuration.psm1`, `src/shared/NetCrate.Workflow.psm1`, `src/shared/NetCrate.Queue.ps1`, `src/desktop/{AppModel,GuidedModel}.cs`, `tests/installation/{Test-OriginalsRestore,Test-OrdinaryBackup,Test-LegacyCheckpoint}.ps1`, and focused desktop/installation regressions as needed.

- [ ] Reproduce each reported mismatch before changing product code and record the failing assertion.
- [ ] Support ordinary legal Windows names consistently across backup, browse and materialization. Native recovery must hash-match a 241-character leaf and its short sibling.
- [ ] Persist an explicit distinction between a stored-original checkpoint and confirmed receipt publication. Publish confirmation durably before media work; make dashboard/history/notifications consume it. Preserve safe older completion semantics and retry the same immutable snapshot.
- [ ] Persist allowlisted, bounded failure categories for unsupported entries, inaccessible/incomplete sources and unavailable storage. Display concrete actions, clear resolved failures and preserve previous success.
- [ ] Run the native receipt-fault, ListBackups, retry, long-name and dashboard/notification regressions. Record commands and actual output.

### Cleanup, exclusion and display

**Files:** `src/shared/NetCrate.Maintenance.psm1`, `src/shared/NetCrate.Schedule.ps1`, `src/shared/Invoke-NetCrateRuntime.ps1`, `install/Invoke-SetupAction.ps1`, `src/desktop/{MaintenanceView.cs,setup/SetupState.cs,setup/WindowsSetupService.cs}`, and focused native/desktop fixtures.

- [ ] Reproduce the zero-candidate cleanup retry failure, lock namespace defect and unreadable date display before fixing them.
- [ ] Offer an explicit preview/confirmation for completing a verified prior forget. Bind the fresh preview to the prior operation and current owner, repositories, inventories and dependencies. Quiesce the endpoint, keep native locks, never repeat forget, and do not retry automatically or report ambiguous cleanup as completed.
- [ ] Verify actual forget followed by interrupted prune, a fresh zero-new-candidate cleanup confirmation, exact native argv and retained-byte restore. Exercise stale/ambiguous/replayed refusal.
- [ ] Use shared owner/installation-scoped source admission and runtime mutexes. Test independent participants and the shared namespace without holding admission locks across native work.
- [ ] Format local storage dates with an explicit offset or zone while leaving canonical UTC persistence and ordering unchanged. Cover the actual view and preview row.
- [ ] Run the focused amended-code checks, commit the fixes, and write the per-finding RED/GREEN report.

## Integration

Before integration, implement the user's added versioning request as a separate task. Use root `VERSION` containing `0.1.1` as the single source for three-part app/product versions and four-part Windows metadata ending in `.0`. Generate assembly attributes and the Win32 manifest rather than maintaining duplicate version literals. The older untagged assembly label `1.1.1.0` and manifest label `1.0.0.0` are normalized to the experimental sequence; no previous release or tag is invented.

Include `VERSION` and concise public `CHANGELOG.md` in the package and installed copy. Keep work under Unreleased until publication, then use a dated version entry. Derive the visible app title, `NetCrate-0.1.1-Windows-x64.zip` filename and CI artifact from the same source; keep the existing unversioned ZIP alias for compatibility. Packaging must reject an executable with stale assembly, file, informational or embedded-manifest metadata. Validate release tag names against `v` plus `VERSION` without creating tags or releases. Data/protocol versions and dependency pins remain separate.

The guarded versioning integration fixture must inspect actual compiled metadata and ZIP contents, reject a stale fixture executable and an independently mismatched embedded manifest, reject malformed/out-of-range version inputs, and preserve the repository's real source/build during mutation tests. Versioning gets its own implementation report and scoped review. One product writer at a time.

- [ ] Generate a fix-only package from the merged-main base to the implementation head. Have the original final reviewer verify all five Important findings, the date-display Minor and new breakage in this fix diff.
- [ ] Resolve load-bearing findings from that review with focused failing regressions and scoped follow-up review. In particular, ambiguous older receipt records, stage-based cleanup eligibility and a later request after an immutable pending snapshot must remain safe.
- [ ] Run the controller's combined native verification once against stable product code, including any added regression fixtures and the existing foreground-window retention test. Verify the ZIP contents against the executable and runtime sources.
- [ ] Update the experimental roadmap, README and verification record to describe actual resolved and remaining work. Link the six issues from the follow-up PR without closing them before merge.
- [ ] Push the feature branch, prepare the PR, inspect GitHub checks and report its actual status. Leave physical-machine acceptance, merge and visibility changes to the user.
