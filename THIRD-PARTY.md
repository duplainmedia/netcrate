# Third-party software

NetCrate's own code uses the MIT License. The following tools retain their own licenses. Their executables are not committed to this repository.

| Software | Purpose | Upstream license | Installation status |
| --- | --- | --- | --- |
| [PowerShell](https://github.com/PowerShell/PowerShell) | Runs background tasks | MIT | Preparation pins Windows Package Manager to 7.6.5.0. |
| [Restic](https://github.com/restic/restic) | Encrypted backup and verification | BSD 2-Clause | Preparation pins 0.19.1. |
| [FFmpeg, Gyan Windows build](https://www.gyan.dev/ffmpeg/builds/) | Video processing | GPL v3 for the selected full build | Backup Server preparation pins 9.0.1. |
| [CPython](https://www.python.org/) | Media-processing runtime | Python Software Foundation License | Automatic installation is pending runtime and distribution validation. |
| [Pillow](https://github.com/python-pillow/Pillow) | Contact sheets | HPND | Automatic installation is pending. |
| [rest-server](https://github.com/restic/rest-server) | Private backup endpoint | BSD 2-Clause | Server provisioning is pending. |
| [NetBird](https://github.com/netbirdio/netbird) | Private connection between computers | BSD 3-Clause for the client; other components have separate terms | Sign-in and pairing integration are pending. |

Preparation uses the Microsoft Windows Package Manager source and its installer hash verification. It never uses an option that ignores a mismatched installer hash. The software list appears before the user chooses to prepare the computer. Windows can request approval for individual installers.

Package definitions: [PowerShell](https://github.com/microsoft/winget-pkgs/tree/master/manifests/m/Microsoft/PowerShell/7.6.5.0), [Restic](https://github.com/microsoft/winget-pkgs/tree/master/manifests/r/restic/restic/0.19.1), [FFmpeg](https://github.com/microsoft/winget-pkgs/tree/master/manifests/g/Gyan/FFmpeg/9.0.1).

Before distributing a binary package, review the exact dependency distributions, preserve their notices, and meet any source-offer or redistribution requirements. Source-only development does not establish that a future installer meets those requirements.
