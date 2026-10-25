# Configuration reference

Normal setup writes configuration automatically. Use the [setup guide](setup.md) for installation; these details are for maintainers.

`%LOCALAPPDATA%\NetCrate\Engine\settings.json` contains non-secret role, installation identity, source and worker identities, project root, state and processing roots, proxy recipe, polling interval, tool paths and the identities of the two Restic repositories. The completed desktop settings file points to the same owned state. Original footage and generated results use separate repositories.

Editing repository addresses require HTTPS. Worker bindings use owned local repository folders and record the corresponding remote address for request validation. Source snapshot paths are derived from the selected Windows project root. A project must be an immediate child of that root. Link ancestors, traversal, reserved names and case collisions are rejected.

Passwords, identity keys and pending pairing records are stored separately using current-user DPAPI. The installation identity, Windows SID and owned state root bind each protected record to its installation. Do not move those records to another Windows account. Use independently saved recovery details to unlock backup repositories after losing the original account.

The active setup and runtime use the shared modules in `src/shared`. Older imported scripts and synthetic examples remain regression references. Their fictional deployment constants are not configuration templates for a fresh installation.
