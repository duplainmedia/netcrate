# Third-party software

NetCrate's own code uses the MIT License. The following tools retain their own licenses. Their executables are not committed to this repository.

| Software | Purpose | Upstream license | Installation status |
| --- | --- | --- | --- |
| [PowerShell](https://github.com/PowerShell/PowerShell) | Runs background tasks | MIT | Private 7.6.5 runtime. |
| [Restic](https://github.com/restic/restic) | Encrypted backup and verification | BSD 2-Clause | Preparation pins 0.19.1. |
| [FFmpeg, Gyan Windows build](https://www.gyan.dev/ffmpeg/builds/) | Video processing | GPL v3 for the selected full build | Backup Server preparation pins 9.0.1. |
| [CPython](https://www.python.org/) | Endpoint authentication and media processing | Python Software Foundation License | Private 3.14.9 runtime. |
| [Pillow](https://github.com/python-pillow/Pillow) | Contact sheets | MIT-CMU | Private 12.3.0 wheel. |
| [bcrypt](https://github.com/pyca/bcrypt) | Backup endpoint authentication | Apache 2.0 | Private 5.0.0 wheel. |
| [rest-server](https://github.com/restic/rest-server) | Private backup endpoint | BSD 2-Clause | Private 0.14.0 executable. |
| [NetBird](https://github.com/netbirdio/netbird) | Private connection between computers | BSD 3-Clause for the client; other components have separate terms | 0.81.3 installer when absent; account sign-in uses its UI. |

Setup lists each required version, purpose, source, license and installation location before asking for approval. Preparation then downloads the approved distributions, checks pinned SHA-256 digests and shows package progress. Verified private copies can be reused. Existing system versions are not replaced. The private bootstrap and background runtime have separate PowerShell locations.

NetBird is optional and receives a separate installation review and Windows approval. Temporary pairing and persistent backup firewall rules have separate, scoped approval. Other tools are installed privately for the current user. NetCrate preserves accompanying license files and never bypasses a digest mismatch.

Exact download locations and digests are recorded in [the dependency manifest](install/dependencies.json). NetCrate's application package does not include those third-party executables. The selected FFmpeg build includes GPL components; its license and corresponding source information remain available from [Gyan](https://www.gyan.dev/ffmpeg/builds/).

Before distributing a binary package, review the exact dependency distributions, preserve their notices, and meet any source-offer or redistribution requirements. Source-only development does not establish that a future installer meets those requirements.
