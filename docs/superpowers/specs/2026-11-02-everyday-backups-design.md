# NetCrate everyday backups

## Approved scope

The user approved roadmap steps 1-5 and requested implementation, using multiple agents if useful. Build on draft commit f50962a0c925f76519f66c54fe8dbc1f8aac81ff. NetCrate becomes useful for ordinary folder backups with optional media processing. Preserve the existing filmmaker workflow. Deliver a private development build, not a public release.

## Intent and acceptance

1. Establish a reproducible baseline, run existing meaningful checks, and reconcile the old release plan with implemented behavior.
2. Back up ordinary folders with no media dependency. Backup completion is independent from optional proxy completion. Existing installations preserve their media behavior; new setup exposes a clear choice. Use ordinary local folders; retain path containment, link rejection and explicit limitations for OneDrive placeholders, locked files and unsupported locations.
3. Through the desktop app, browse backed-up dates and files, select a file or folder, and recover into a new separate destination without overwriting existing files. Verify restoration. Support a recovery workflow using the saved recovery file on a fresh account/computer without relying on the original account's DPAPI secrets.
4. Configure automatic schedules through the app. Persist schedules, catch up once after missed runs, avoid overlapping/duplicate jobs, retry interrupted work, and show the last successful backup separately from media status. Keep the existing signed-in operation requirement explicit; signed-out services are outside this pass.
5. Show storage warnings and understandable errors; expose backup health checks and explicit retention controls. Retention defaults to preserving backups. Preview candidates and require a deliberate user action before any pruning. Preserve append-only transport and keep destructive maintenance on the repository-owning server. Never execute retention against installed production data while developing.

## Approach

Continue the C# WPF/.NET Framework 4.8 desktop, PowerShell engine, Restic storage and Python media tools. Extend the current queue and tested setup action bridge. Build one application with ordinary backups and optional media features. A filmmaker-only release was considered but the user chose general backups with optional filmmaking features. A new general storage engine or cross-platform rewrite adds scope without serving this milestone.

## Constraints

- Work only in the isolated checkout for this chat. Do not modify the original checkout or installed applications, scheduled tasks, firewall, credentials, production repositories or footage.
- Use generated files and disposable repositories for tests. No real data transmission.
- Preserve repository identity validation, protected credentials, source/snapshot binding, safe paths and immutable verified media versions.
- Keep secrets out of logs, command arguments, ordinary settings and Git history.
- No main merge, public publication or installed-production migration in this pass.
- Two real computers, independent sign-in/reboot/network acceptance and public-release preparation remain roadmap step 6. Automated local tests cannot establish those claims.
- Use plain language in UI and docs. Describe actual implemented and verified behavior.

## Builder decisions

This document records the already-approved roadmap. Builders may settle routine interface and implementation choices and record significant decisions in the plan ledger. The first release stays Windows x64, one source and one backup server. Both accounts must be signed in while work runs. Retention implementation must preserve recovery and protocol dependencies, not just delete by age.

## Experimental source publication

On 3 November, the scope changed to preparing a PR for experimental source publication, with the known review findings logged and a prioritized follow-up plan. The user will merge and make the repository public. The PR keeps the tested implementation, documents the unresolved issues, and does not claim a clean final review or supported release. Unfinished implementation work is preserved separately rather than included. See [the experimental roadmap](../../experimental-roadmap.md).
