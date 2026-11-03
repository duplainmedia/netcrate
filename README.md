# NetCrate

NetCrate backs up Windows folders to a computer you control and optionally processes video proxies.

**NetCrate is experimental software.** The current build has known issues affecting recovery, backup completion reporting and storage cleanup. Keep an independent backup of anything important and do not use NetCrate as your only backup. Read the [known issues and fix plan](docs/experimental-roadmap.md) before trying it. Public source availability does not mean the application is ready for dependable backup use.

I’m a team of one working in commercial filmmaking and videography. I built NetCrate to keep a backup of my footage somewhere else and move proxy generation off my editing computer.

The idea is simple: another computer at another location, even one assembled from parts you already have, can do useful work while your main machine stays available for editing. You don’t necessarily need another powerful workstation.

For video projects, NetCrate backs up the originals, generates proxies and contact sheets on the other computer, verifies the results, and sends them back to your editing machine. You can monitor progress without managing every step yourself.

For someone with spare hardware and a suitable second location, it can be an affordable, self-hosted alternative to paying for cloud backup storage, with the added benefit of offloading proxy encoding.

## Development status

This branch includes a Windows setup wizard for an Editing Computer and a Backup Server. New setup defaults to ordinary folder backups, with optional media processing for video projects. It installs verified tools, creates encrypted backup storage, saves recovery details, connects the computers and verifies a generated sample.

Setup uses Windows dialogs and buttons. For ordinary files, choose **Back up a folder** and select the configured source folder or a folder inside it. Backup and media status are tracked separately, but a [known completion-reporting issue](https://github.com/duplainmedia/netcrate/issues/3) can announce success before the recovery receipt is available. In media mode, choose **Back up a project**. The server also creates ProRes Proxy files and contact sheets, and the Editing Computer verifies the returned files before showing them as ready. Earlier proxy versions remain available. Existing installations keep their media workflow.

The guided workflow has been tested with disposable repositories and generated footage. Testing on two separate Windows computers, including sign-in after a restart and recovery under a fresh account, is still required before a supported binary release. Both computers must stay on and signed in while tasks run.

See [setting up both computers](docs/setup.md) for the user workflow and [development and verification](docs/development.md) for build instructions. There is no public release download yet.

## Versioning

NetCrate uses [Semantic Versioning](https://semver.org/) with three numeric components; 0.x builds are experimental. See the [changelog](CHANGELOG.md) for unreleased changes. On release, notes move to a dated version entry and may be reused in GitHub Releases. Release tags use `v` followed by the version. Windows metadata adds `.0`; each component is limited to 65534.

## License

NetCrate's original code is licensed under the [MIT License](LICENSE). Third-party software retains its own licenses.
