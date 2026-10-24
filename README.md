# NetCrate

**NetCrate turns a spare Windows computer into an off-site backup and proxy-processing server for your video projects.**

I’m a team of one working in commercial filmmaking and videography. I built NetCrate to keep a backup of my footage somewhere else and move proxy generation off my editing computer.

The idea is simple: another computer at another location, even one assembled from parts you already have, can do useful work while your main machine stays available for editing. You don’t necessarily need another powerful workstation.

Once you start a backup for a project folder, NetCrate automates the workflow: back up the originals, generate proxies and contact sheets on the other computer, verify the results, and send them back to your editing machine. You can monitor progress without managing every step yourself.

For someone with spare hardware and a suitable second location, it can be an affordable, self-hosted alternative to paying for cloud backup storage, with the added benefit of offloading proxy encoding.

I built it because it makes my own workflow easier. I’m sharing it because it might help another independent filmmaker or small production team put equipment they already own to work.

## Development status

The guided setup is in development. The Windows app now includes the computer choice, native folder picking, saved setup choices, software checks and a dark navy interface. Preparation can install pinned PowerShell, Restic and FFmpeg packages through Windows Package Manager.

Computer pairing, repository and key creation, independent recovery export, automatic Python installation and the sample round trip are still being connected. This build stops at unfinished steps. It cannot complete a new backup installation yet.

The source and worker components are included for development. Their configuration and protocol still need to be generalized and verified together before release. Keep testing separate from existing backups and footage.

See [development and verification](docs/development.md) for build instructions and current limits. There is no packaged release yet.

## License

NetCrate's original code is licensed under the [MIT License](LICENSE). Third-party software retains its own licenses.
