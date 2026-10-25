# NetCrate

**NetCrate turns a spare Windows computer into an off-site backup and proxy-processing server for your video projects.**

I’m a team of one working in commercial filmmaking and videography. I built NetCrate to keep a backup of my footage somewhere else and move proxy generation off my editing computer.

The idea is simple: another computer at another location, even one assembled from parts you already have, can do useful work while your main machine stays available for editing. You don’t necessarily need another powerful workstation.

Once you start a backup for a project folder, NetCrate automates the workflow: back up the originals, generate proxies and contact sheets on the other computer, verify the results, and send them back to your editing machine. You can monitor progress without managing every step yourself.

For someone with spare hardware and a suitable second location, it can be an affordable, self-hosted alternative to paying for cloud backup storage, with the added benefit of offloading proxy encoding.

I built it because it makes my own workflow easier. I’m sharing it because it might help another independent filmmaker or small production team put equipment they already own to work.

## Development status

This branch includes a Windows setup wizard for an Editing Computer and a Backup Server. It installs verified tools, creates encrypted backup storage, saves recovery details, connects the computers and runs a sample through the backup and proxy workflow.

Setup uses Windows dialogs and buttons. After setup, choose **Back up a project** in NetCrate. The server creates ProRes Proxy files and contact sheets, and the Editing Computer verifies the returned files before showing them as ready. Earlier proxy versions remain available.

The guided workflow has been tested with disposable repositories and generated footage. Testing on two separate Windows computers, including sign-in after a restart and recovery under a fresh account, is still required before a public release. Both computers must stay on and signed in while tasks run.

See [setting up both computers](docs/setup.md) for the user workflow and [development and verification](docs/development.md) for build instructions. There is no public release download yet.

## License

NetCrate's original code is licensed under the [MIT License](LICENSE). Third-party software retains its own licenses.
