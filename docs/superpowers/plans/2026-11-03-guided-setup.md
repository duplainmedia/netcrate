# Guided setup implementation plan

Use `superpowers:subagent-driven-development` for independent feature components, with root integration and independent reviews. The user approved the written design and requested implementation without further product approval loops.

Goal: deliver a clear setup wizard with informed software approval, easier recovery and automatic private-network pairing.

Spec: `docs/superpowers/specs/2026-11-03-guided-setup-design.md`.

Base: merged main `49507c1fa5675441c906d2abd0dfc12ef29f14f5`, isolated owned clone, branch `codex/guided-setup`. Existing design commit is `ca357c9`.

## Global constraints

- Keep C# WPF/.NET Framework 4.8 and Windows PowerShell 5.1 bootstrap to pinned PS7. No new hosted service or crypto wire format.
- New development version `0.2.0`; no release, tag, merge or live machine setup/task/firewall/data changes.
- Consent precedes first bootstrap download and is bound to the reviewed role/mode/folder/catalog plan. Check again is read-only.
- Preserve protected identity/repository state, both code comparisons, certificate/payload binding, repository checks and signed acknowledgment.
- Temporary TLS pairing port 8201, exact local/source IPv4, 128 KiB frames, 5-second connect/handshake, 15-second frame deadline, 15-minute listener lease and 1–10-second retry backoff.
- Recovery secrets remain outside generic state/progress/logs/arguments; clipboard history/cloud flags are DWORD zero; expire after 2 minutes without erasing later user clipboard data.
- Tests use generated Temp fixtures and loopback only; simulate firewall rules and installation approval. Actual separate-machine acceptance remains explicit follow-up.

## Review focus

- No consent bypass through PS5 bootstrap, retry, NetBird or stale reviewed choices.
- Retry/reopen/concurrent windows must not replace pending identities or reset confirmation.
- Listener, helper and exact owned firewall rule cleanup, including stale rules after abnormal termination.
- Clear recovery copy semantics, no secret persistence and no deletion of later clipboard contents.
- Every visible wizard state has one appropriate primary action and truthful completion/waiting status.

## Task 1 — software planning and progress

Own `install/NetCrate.SoftwarePlan.psm1`, `install/NetCrate.Dependencies.psm1` and `tests/installation/Test-SoftwarePlan.ps1`. Do not edit Engine, action bridge or C# files in parallel.

Produce `Get-NetCrateSoftwarePlan -Root <Engine> -BootstrapRoot <Setup/Bootstrap> -Role Source|Worker -BackupMode Folder|Media -Folder <path>` returning `{Version=1;PlanId;Packages;Changes}`. Packages include Name, Version, Purpose, Source, License, Destination, Scope, Status. Derive identities from the checked-in catalog and include both PowerShell locations. PlanId binds role/mode/folder/package identities; no downloads, extraction, writes or process execution during planning.

Produce `Assert-NetCrateSoftwarePlan ... -PlanId <accepted hash>` and an optional `-Progress` scriptblock on acquisition/extraction/install functions. Progress records contain package name/version/phase/counts only. Root integrates the plan and progress into the active bridge and UI.

- [ ] Write/run failing tests for exact package matrix, missing/cache/reuse/repair metadata, deterministic and invalidated PlanId, side-effect freedom under PS5, acceptance mismatch and ordered safe progress.
- [ ] Implement minimal real planning and progress hooks.
- [ ] Run PS5 and PS7 planning tests and existing dependency/path regressions; report RED/GREEN evidence and integration instructions.
- [ ] Independent feature review and scoped commit.

## Task 2 — network pairing component

Own new setup transport/backend/helper files, new `src/desktop/setup/NetworkSetup*.cs`, focused transport/lease tests, and `install/NetCrate.Engine.psm1` for TLS identity and stable pairing extraction. Do not edit the shared action bridge, SetupState/Controller/View or Build in parallel.

Produce a dedicated `INetworkPairingService` and typed nonsecret status/request models in new C# files. Methods cover network inspection/peers, start/connect, poll, confirm and stop/dispose. Send root the exact public signatures before integration. The existing WindowsSetupService can be used through an extension dispatch interface supplied by root; new PS actions route to a dedicated module. Keep waiting cancellable and distinct from installing/busy transactions.

Reuse existing signed request/encrypted reply without file dialogs. Use a private owner pipe/owned process job for the helper, server TLS identity later authenticated by the reply, exact peer selection and a separate explicitly approved firewall lease guardian. Cache exact request/reply for idempotent retry. Protect all pairing mutations with owner/installation mutex, including manual fallback. Share factorized legacy pairing actions so checks/credentials activate through the same gates.

- [ ] Write/run failing bounded loopback tests for transport framing, two confirmations, pending certificate binding, request/reply retry, changed/competing/expired/tampered sessions, cancellation and status secrecy.
- [ ] Implement private peer discovery with validated pinned NetBird JSON/manual fallback, exact-address listener/client, safe helper lifecycle and simulated firewall lease contract.
- [ ] Verify no reply before server confirmation, no source activation before confirmation, actual repository/signed-ack checks, manual fallback and resume behavior. Do not modify live firewall/tasks.
- [ ] Independent feature review and scoped commit.

## Task 3 — recovery export and paste

Own `install/NetCrate.Repositories.psm1`, new dedicated recovery-transfer script(s), new `src/desktop/setup/RecoveryTransfer*.cs` and focused recovery/clipboard tests. Do not edit the generic bridge/models/view/build in parallel.

Produce `IRecoveryTransferService` for an ephemeral recovery document copy and compatible paste-based recovery. Use a dedicated result/channel, not generic SetupResult or persisted state. Provide a clipboard abstraction with history/cloud exclusion, two-minute ownership-checked clearing and explicit Clear now; real clipboard integration is user-initiated only. Ordinary local C-drive export must work and preserve existing destinations.

- [ ] Write/run failing tests for document compatibility, local export/no overwrite/overlap, private permissions, clipboard formats/expiry/new-content preservation and no generic-state/log persistence.
- [ ] Implement shared recovery document serialization, dedicated ephemeral bridge, clipboard lifecycle and paste-to-recovery context without exposing secrets to generic status.
- [ ] Run existing repository and originals recovery checks with generated repositories; report exact public signatures and view integration instructions.
- [ ] Independent feature review and scoped commit.

## Task 4 — root wizard and integration

Own `SetupState.cs`, `SetupController.cs`, `SetupView.cs`, `WindowsSetupService.cs`, `ISetupService.cs` extension contracts, `install/Invoke-SetupAction.ps1`, desktop/CI build integration and view/controller tests. Integrate Engine software hooks only after Task 2 releases that file.

Use explicit preparation/recovery and connection substates without reinterpreting persisted old SetupStep numeric values. Add plan review/acceptance and structured progress; make the pre-bootstrap Plan action read-only, enforce acceptance before Prepare and before optional NetBird installation, and keep inspection read-only. Poll a bounded nonsecret sidecar for package progress while preserving final JSON parsing.

Render role-specific pages with a consistent footer and one current primary action; display a checklist and current/waiting/completed evidence. Give folder input an editable full path, physical-drive picker and actionable exact-path validation. Give recovery its own page with Save, Copy, Show/Clear, separate-copy acknowledgment or honest local-only continuation. Add paste recovery entry. Delegate network operations to Task 2's service and display only the correct current identity/peer action. Automatic connection/sample verification follows successful prerequisites.

- [ ] Add failing controller/view tests for review gate, changed-choice invalidation, navigation, recovery substates, every pairing state and automatic check ordering.
- [ ] Implement/integrate approved components, retaining old installation/state/backup compatibility.
- [ ] Run native desktop suites and inspect actual rendered wizard pages at minimum/default sizes; correct spacing, clipping and keyboard access.
- [ ] Run all relevant shared, pairing, preparation, recovery and transport fixtures; refresh Windows CI. Fix integration failures with focused RED/GREEN tests.
- [ ] Update VERSION/Unreleased changelog/setup/roadmap, build/version/package verification and record limitations.
- [ ] Independent final review, address actionable findings, push/open PR and verify final Windows CI. Leave merge to user.

Root owns commits, shared interfaces, integration and the execution ledger. Parallel implementers edit only their listed files and return reports before root stages their work.
