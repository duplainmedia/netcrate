# Experimental status and next steps

NetCrate is being shared as experimental source code for evaluation and contribution. It is not ready to be relied on as a sole backup or promoted as a dependable backup product. Keep independent copies of important data. There is no supported public binary release.

The implemented Windows workflow includes ordinary folder backups, optional media processing, selective recovery, daily schedules and explicit server-side retention. Local verification passed 26 check groups and a separate foreground-window retention test. A subsequent [whole-branch review](reviews/2026-11-03-everyday-backups.md) found the open issues below. The [verification record](verification-2026-11-03.md) describes both the evidence and its limits.

## Known issues

1. [Backup success can be announced before the recovery receipt exists](https://github.com/duplainmedia/netcrate/issues/3). If receipt publication fails after originals are written, the dashboard can advertise a backup date that independent app recovery cannot yet open. A success notification is not sufficient evidence of recoverability in this build.
2. [Recovery rejects some filenames that backup accepts](https://github.com/duplainmedia/netcrate/issues/2). A legal 241-character filename can prevent its entire parent directory from being browsed through recovery, including short-named siblings.
3. [Interrupted pruning cannot be finished when no new removal candidates remain](https://github.com/duplainmedia/netcrate/issues/4). Following the current retry instruction can report completion without reclaiming the unreferenced space left by a verified forget.
4. [Source admission can duplicate work across Windows sessions](https://github.com/duplainmedia/netcrate/issues/5). The same account in separate sessions can bypass session-local admission and runtime locks.
5. [Ordinary backup errors lose their actionable cause](https://github.com/duplainmedia/netcrate/issues/7). Unsupported entries and incomplete reads can become generic advice and repeated retries of the unchanged source.
6. [Storage dates need readable local formatting](https://github.com/duplainmedia/netcrate/issues/6). Health details and preview rows currently show verbose UTC wire values.
7. [The developer guide overstated snapshot preservation](https://github.com/duplainmedia/netcrate/issues/8). This PR corrects that statement by distinguishing media generation and delivery from explicitly confirmed Folder retention. The tracking issue can close when the correction is merged.

## Plan of attack

First, resolve completion truthfulness and recovery-name support in issues 3 and 2. Keep the existing original snapshot checkpoint for retry, but advertise success only after the required receipt is available. Test a failed receipt write through history, notifications and independent recovery, then prove that retry uses the same snapshot. Test native backup-date browsing and byte-for-byte recovery of a long-named file together with a short-named sibling.

Next, resolve cleanup retry, cross-session exclusion and actionable error reporting in issues 4, 5 and 7. Cleanup after a verified forget must require a new preview and confirmation, recheck bindings and dependencies, and avoid repeating an ambiguous destructive step. Add independent-process exclusion tests for the shared source mutex namespace. Carry bounded, nonsecret failure categories through the queue to useful dashboard actions, while preserving the last successful backup.

Then, complete the date display improvement in issue 6 and retain the documentation correction in issue 8. Keep UTC values for storage and comparison, and use readable local times with an offset for display.

After the fixes receive focused regression coverage and review, rebuild the package and rerun the combined native backup, recovery, media, scheduling, maintenance and transport checks. Verify retained snapshots by restoring and hashing their bytes. Confirm that package contents match the tested runtime files. Passing those checks is a prerequisite to reconsidering a supported release, not a substitute for real-machine acceptance.

Finally, test an actual source computer and NCS Tower with disposable data. Cover first setup under distinct Windows accounts, task registration and elevation, sign-in after reboot, disconnected and reconnected storage, private-network address changes, interrupted work, and recovery without the original profile. Record what actually passes before recommending use with important files.

Both accounts must remain signed in. Health checks currently cover repository metadata and structure rather than reading every stored data byte. Retention is deliberately limited to positively verified ordinary Folder backups, preserves media and unresolved dependencies, and has a finite preview limit. The certificate is self-signed and paired directly; automatic renewal and rotation are not implemented. These limits remain explicit while further work is planned.
