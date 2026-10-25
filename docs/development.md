# Development and verification

Build on Windows x64 with .NET Framework 4.8:

```powershell
.\src\desktop\Build.ps1
```

The build runs desktop model, setup controller, persistence, folder, timeout and accessibility checks. `build\NetCrate.exe` opens setup if this Windows account has no completed NetCrate settings. The build folder includes the backend scripts and a generated sample clip. Preparation starts only after the user selects it.

Normal users follow [setup](setup.md). They do not run development commands or edit configuration files.

## Runtime

The app stores its owned engine under `%LOCALAPPDATA%\NetCrate\Engine`. It keeps a separate installation identity, current-user DPAPI records, pinned tool distributions, repository bindings and durable job state. The two repositories have independently generated passwords. The backup endpoint uses TLS 1.3, bcrypt authentication, private repositories and append-only access. A scoped Windows Firewall rule permits the paired editing address only.

Pairing uses signed public requests and encrypted replies bound to both installation identities. Manual device and connection code comparisons precede credential activation. Connection checks verify the actual repository identities and a signed acknowledgement. Network sign-in uses NetBird's own UI.

One owned task runs under the installing Windows account when it is signed in. It resumes at sign-in after a reboot. It does not run as SYSTEM or claim signed-out service operation. Development tests do not register this task or alter an installed deployment.

The active entry points are `install/Invoke-SetupAction.ps1`, `src/shared/Invoke-NetCrateRuntime.ps1` and `src/worker/netcrate_media.py`. Older imported source and worker scripts are retained as reference while migration and compatibility checks continue. They are not called by guided installation.

## Media and delivery

The default recipe is `half-prores-v2`: half-size ProRes Proxy, 10-bit 4:2:2, source frame rate, PCM 24-bit audio, source metadata and timecode. The alternative `quarter-prores-v1` uses quarter-size video. Contact sheets contain twelve source frames at 1232 by 1176 pixels, without a creative LUT.

Requests identify an exact successful source snapshot and a recipe-dependent footage fingerprint derived from Restic content identities. The server independently derives that identity, restores with verification, encodes and checks the media. Reusing a generation creates a new association that preserves both the newly requested snapshot and the original generation snapshot.

The Editing Computer validates signatures, identities, recipe, manifest membership, sizes and hashes before promoting an immutable version under the project's `Proxies\NetCrate` folder. Unexpected files, links, path traversal and case collisions are rejected. No operation deletes earlier backup snapshots or proxy versions.

## Tests

Run shared configuration, protocol, pairing and dependency tests with PowerShell 7.6.5. Supply a new, ordinary local folder for each filesystem fixture. Avoid OneDrive paths: rejecting linked ancestors is intentional.

`tests/installation/Test-Workflow.ps1` accepts explicit Restic, Python and FFmpeg paths, plus an optional rest-server path for the authenticated HTTPS workflow. It uses generated footage and new repositories, checks unchanged-footage reuse, changed recipes, interrupted delivery, queue resume, retained versions and corrupt results. `Test-Transport.ps1` also checks certificate rejection. These fixtures require local loopback networking; restricted sandboxes may block it.

`tests/worker` and the older source helper tests cover inherited media and protocol behavior. They are regression checks, separate from fresh installation acceptance.

Before public release, verify on two separate Windows computers: fresh-account installation, NetBird sign-in, firewall approval, file exchange, sample delivery, a real project, offline resume, sign-in after reboot and recovery with the saved file under a fresh account. A localhost fixture does not establish those results.
