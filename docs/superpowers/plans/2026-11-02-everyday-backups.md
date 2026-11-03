# NetCrate everyday backups implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans for the approved task-by-task implementation. Steps use checkboxes. The controller coordinates shared-file edits and final integration.

**Goal:** Provide a private Windows build for everyday folder backups, verified selective recovery, automatic signed-in backups and owner-controlled retention.

**Architecture:** Keep WPF as the user entry point, extend the JSON setup action bridge and let the signed-in PowerShell runtime own queued work. Primary holds originals and small completion receipts; Results keeps immutable media and signed protocol records. Independent recovery opens an existing local repository with the exported file and a pinned Restic executable.

**Tech stack:** Windows x64, .NET Framework 4.8 WPF, PowerShell 7.4+ engine, pinned Restic/rest-server, private HTTPS and existing Python-based media pipeline.

**Spec:** [Approved design](../specs/2026-11-02-everyday-backups-design.md)

## Global constraints

- Work only in this chat's isolated checkout. Test with generated inputs, unique ordinary temp directories outside OneDrive, disposable repositories and loopback transport.
- One source, one backup server. Both accounts must be signed in while scheduled work runs. Two physical machines, independent reboot/network acceptance and public release are step 6.
- Preserve append-only private HTTPS, pinned identities/certificates, DPAPI for installed credentials, safe local paths, exact source/snapshot binding and immutable verified media versions.
- Keep secrets out of logs, command arguments, ordinary settings and Git history. Never run retention against an installed repository. No production installs, scheduled-task changes, firewall edits, main merge or publication.

## Review focus

1. Exit 3 may still create a snapshot. Task 2 tests that an incomplete read cannot become a successful new restore point.
2. A crash between originals and media publication must retain the successful backup, even if Results is unavailable. Task 2 tests the separate states.
3. A moved backup drive and a file named with square brackets must restore exact bytes without the old profile. Task 3 tests identity, literal selection and no-overwrite publication.
4. Repeated scheduler ticks, simultaneous manual starts and sign-in after several missed or repeated local times must coalesce. Task 4 uses an injected clock and restart fixtures.
5. A stale retention preview or unresolved media dependency must preserve all affected snapshots. Task 5 tests repository changes and pinned evidence at execution.

## Contracts and decision ledger

| Topic | Contract and reason |
| --- | --- |
| Compatibility | New setup explicitly offers Folder (default) or Media. Existing v1 settings, prepared states, pairing requests and jobs missing mode mean Media. The source's requested mode must fit the server capability. |
| Folder scope | Use the configured ordinary local root or a contained folder for Folder mode. Media retains existing direct-child project semantics. Reject root/ancestor overlaps, links and unsupported offline placeholders. |
| Original success | Full snapshot ID from an exit-zero run, timestamp and mode are independently checkpointed. New successful snapshots have a separate append-only receipt in Primary so recovery and maintenance do not need the source profile. Folder images use a distinct tag (proposed netcrate-folder-originals), Media retains netcrate-originals. Preserve Results and all historical/control/unknown data by default. |
| Queue and UI | Use BackupMode, Project, SnapshotId, BackupCompletedUtc and MediaState (Off/Pending/Ready/NeedsAttention). Keep legacy fields readable. Last success uses the successful snapshot's time even when a later attempt fails. |
| Action bridge | Continue install/Invoke-SetupAction.ps1 and WindowsSetupService. Validate action-specific parameters, role/owner/installation, lengths and path binding. Return Succeeded/Code/Message and explicit bounded metadata as needed. Pass only the input filename and allowlisted action on argv. Independent read-only recovery has its own pre-setup validation path. |
| Schedule | Source-local daily wall-clock time per selected folder. Existing signed-in runtime with stable occurrence IDs; persist scheduling decisions, avoid overlapping originals and resume queue checkpoints. No additional Windows task per folder. |
| Storage | Worker health and retention use the bound local repositories. Explicit preview/apply protects latest backup per folder, media references and all unknown/control data. Never grant remove rights to transport, and never expose a generic Restic command dispatcher. |
| Verification | The controller collects actual commands and outputs, labels fixture vs real-machine validation, records private package path/checksum, and reports unverified checks. Tool paths and prerequisites come from Task 1. |

## Execution

- [x] **1. Establish baseline.** Follow [Task 1](task-1-baseline-brief.md). Read its report before attributing any failure to new work.
- [x] **2. Ship ordinary backup from setup through dashboard.** Follow [Task 2](task-2-brief.md). Publish final queue and receipt formats to dependent tasks.
- [x] **3. Restore selected originals with or without an existing profile.** Follow [Task 3](task-3-brief.md). Use installed or recovery-only credentials with the same selection and verification logic.
- [x] **4. Schedule and report backups.** Follow [Task 4](task-4-brief.md). Use Task 2's actual durable queue contract and preserve manual/media behavior.
- [x] **5. Expose health and limited retention.** Follow [Task 5](task-5-brief.md). Revalidate repository state and actual dependencies before any forget/prune.
- [x] **Integrate.** Build and test the combined private package in this checkout. Verify that packaged actions, dependencies, WPF entry points, docs and stated capabilities match; record recovery SHA-256 and retained-snapshot evidence. Stage only intentional project changes if checkpointing. Leave deployment/publication and step 6 separate.

The combined verification and package checks passed. The final whole-branch review subsequently found five Important issues, which remain open in the [experimental roadmap](../../experimental-roadmap.md). On 3 November the user chose to prepare an experimental-publication PR with those issues logged and further fixes deferred. The user will perform the merge and publication. This scope update does not turn the passing checks into a clean final review.

Builders may begin independent modules and fixtures concurrently after the Task 2 contract is agreed. Serialize edits to WindowsSetupService, Invoke-SetupAction, runtime loop, Build.ps1 and WindowView, or give the controller an explicit integration handoff. Each task owns both its clickable workflow and behavioral tests.
