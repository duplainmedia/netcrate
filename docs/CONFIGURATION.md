# Configuration reference

Normal setup writes configuration automatically. Use the [setup guide](setup.md) for installation; these details are for maintainers.

`%LOCALAPPDATA%\NetCrate\Engine\settings.json` contains non-secret role, installation identity, source and worker identities, project root, state and processing roots, proxy recipe, polling interval, tool paths and the identities of the two Restic repositories. The completed desktop settings file points to the same owned state. Original footage and generated results use separate repositories.

Editing repository addresses require HTTPS. Worker bindings use owned local repository folders and record the corresponding remote address for request validation. Source snapshot paths are derived from the selected Windows project root. A project must be an immediate child of that root. Link ancestors, traversal, reserved names and case collisions are rejected.

Passwords, identity keys and pending pairing records are stored separately using current-user DPAPI. The installation identity, Windows SID and owned state root bind each protected record to its installation. Do not move those records to another Windows account. Use independently saved recovery details to unlock backup repositories after losing the original account.

The active setup and runtime use the shared modules in `src/shared`. Older imported scripts and synthetic examples remain regression references. Their fictional deployment constants are not configuration templates for a fresh installation.

## Server storage maintenance

The signed-in Worker runtime owns storage checks and retention requests. The dashboard defaults to **Keep all backups**; no retention runs automatically. A deliberate preview and separate confirmation are required, and previews expire after 15 minutes or become stale when the repository or dependency evidence changes. For this private build, a preview is limited to 256 completed Folder originals and 256 candidate removals. Media, legacy and unknown originals, control/receipt records, all Results, at least the newest completed backup per folder, and referenced originals are retained. Incomplete or conflicting evidence blocks deletion.

The server checks the actual bound local repository IDs and owning storage marker before maintenance, temporarily stops the append-only endpoint for a confirmed apply, and keeps Restic locking enabled. A journal records forget and prune separately; an interrupted or ambiguous step requires attention and a new preview. Checks cover repository metadata and structure, not a full read of all file data. A warning appears below 5 GiB free on the owning volume. Keep the owning Windows account signed in while queued work runs.
