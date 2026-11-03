# Third-party software

NetCrate's own code uses the MIT License. The following tools retain their own licenses. Their executables are not committed to this repository.

| Software | Purpose | Upstream license | Installation status |
| --- | --- | --- | --- |
| [PowerShell](https://github.com/PowerShell/PowerShell) | Runs background tasks | MIT | Private 7.6.5 runtime. |
| [Restic](https://github.com/restic/restic) | Encrypted backup and verification | BSD 2-Clause | Preparation pins 0.19.1. |
| [FFmpeg, Gyan Windows build](https://www.gyan.dev/ffmpeg/builds/) | Video processing | GPL v3 for the selected full build | Backup Server preparation pins 9.0.1. |
| [CPython](https://www.python.org/) | Media-processing runtime | Python Software Foundation License | Private 3.14.9 runtime. |
| [Pillow](https://github.com/python-pillow/Pillow) | Contact sheets | HPND | Private 12.3.0 wheel. |
| [bcrypt](https://github.com/pyca/bcrypt) | Backup endpoint authentication | Apache 2.0 | Private 5.0.0 wheel. |
| [rest-server](https://github.com/restic/rest-server) | Private backup endpoint | BSD 2-Clause | Private 0.14.0 executable. |
| [NetBird](https://github.com/netbirdio/netbird) | Private connection between computers | BSD 3-Clause for the client; other components have separate terms | 0.81.3 installer when absent; account sign-in uses its UI. |

Preparation downloads official or identified upstream distributions, checks pinned SHA-256 digests and preserves their accompanying license files. It never bypasses a digest mismatch. NetBird installation and the private firewall rule may request Windows approval. Other tools are installed privately for the current user.

Exact download locations and digests are recorded in [the dependency manifest](install/dependencies.json). NetCrate's application package does not include those third-party executables. The selected FFmpeg build includes GPL components; its license and corresponding source information remain available from [Gyan](https://www.gyan.dev/ffmpeg/builds/).

Before distributing a binary package, review the exact dependency distributions, preserve their notices, and meet any source-offer or redistribution requirements. Source-only development does not establish that a future installer meets those requirements.
