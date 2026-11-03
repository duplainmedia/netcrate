# Experimental status and next steps

NetCrate remains experimental. Keep independent backups. There is no supported public binary release, and real-machine acceptance is incomplete.

## Addressed in 0.1.1 development

Focused native tests and scoped reviews cover these fixes. The issues close when the follow-up PR merges.

- [Recovery names](https://github.com/duplainmedia/netcrate/issues/2) support long filenames alongside short and empty files.
- [Completion reporting](https://github.com/duplainmedia/netcrate/issues/3) requires a published recovery receipt and handles ambiguous older checkpoints conservatively.
- [Cleanup retry](https://github.com/duplainmedia/netcrate/issues/4) uses a fresh preview and confirmation after a verified forget.
- [Source exclusion](https://github.com/duplainmedia/netcrate/issues/5) uses owner-scoped locks shared across Windows sessions.
- [Storage dates](https://github.com/duplainmedia/netcrate/issues/6) display local times with UTC offsets.
- [Backup errors](https://github.com/duplainmedia/netcrate/issues/7) retain safe, actionable categories.

The [preservation documentation](https://github.com/duplainmedia/netcrate/issues/8) was corrected previously. The [changelog](../CHANGELOG.md) records user-facing changes; [the original review](reviews/2026-11-03-everyday-backups.md) remains historical evidence.

## Addressed in 0.1.2 development

[Maintenance history saturation](https://github.com/duplainmedia/netcrate/issues/10) is fixed by retiring safe terminal records before admitting another request. Active operations, ambiguous forget, unfinished cleanup and unknown stages remain protected.

[Focused verification](verification-0.1.2.md) covers history admission, journal preservation, native cleanup, the desktop build and versioned packaging.

## Addressed in 0.1.3 development

[Recovery bootstrap extraction](https://github.com/duplainmedia/netcrate/issues/13) uses validated extended paths for Windows PowerShell 5.1 file I/O. [Focused verification](verification-0.1.3.md) covers short/long roots, the actual recovery bridge, archive checks, link rejection and private permissions.

## Remaining work

[Combined verification](verification-0.1.1.md) passed all 32 groups and the package checks. Next, test the source computer and NCS Tower with disposable data, covering separate accounts, setup/elevation, reboot/sign-in, disconnected storage, network changes, interruption and independent recovery. Record actual results before recommending important-file use.

Both accounts must remain signed in. Health checks cover metadata and structure rather than every stored byte. Retention has a finite preview limit and preserves media and unresolved dependencies. Automatic certificate renewal and rotation are not implemented.
