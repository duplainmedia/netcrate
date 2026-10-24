# Building and checking NetCrate

This branch contains the first native guided-setup implementation. It is not a completed fresh-install release.

## Build

Use a Windows x64 development machine with .NET Framework 4.8 and its C# compiler. From the repository root, run:

```powershell
.\src\desktop\Build.ps1
```

The build runs the desktop model, setup controller, native folder, saved-state and settings tests, then writes `build\NetCrate.exe`. Launching that executable opens setup when a NetCrate settings file is absent. It does not read an older deployment's configuration. The software preparation actions run only after the user clicks the preparation button.

The output folder includes the setup engine scripts. Keep them alongside the executable. Normal users should eventually receive an installer; these build commands are for development.

## Current behavior

- The first screen asks "Which computer is this?" and offers Editing Computer and Backup Server.
- A native Windows picker selects the project parent folder or backup storage. Checks reject drive roots, unavailable folders, links, cloud-managed ancestors and unwritable storage.
- Non-secret choices are saved atomically in the current Windows user's NetCrate setup folder. Restarting repeats software and peer checks. A corrupt state file is preserved and reported.
- Software preparation detects role-specific dependencies, installs supported missing packages through pinned WinGet entries, and checks the result before proceeding. A failed or declined installation can be retried.
- The Backup Server cannot advance without a separately saved and confirmed recovery copy. The editing role cannot finish without a successful sample round trip.

The final two gates are tested controller contracts. Repository creation, key protection, recovery export, recipient-bound pairing and the actual sample pipeline are not connected to this build. Their service methods return an unavailable result and cannot mark setup complete. The inherited source and worker scripts also retain fictional deployment constants while shared configuration and protocol work continues. They are not an installation path.

The media modules were checked with Python 3.12.14 and Pillow 12.3. A supported fresh Python distribution and its integrity checks still need validation. The app therefore does not guess a Python installer or downgrade an existing runtime.

## Verification

```powershell
.\tests\installation\Test-Preparation.ps1 -TestRoot "$env:TEMP\NetCrate-Preparation-Test"
$env:PYTHONPATH = "$PWD\src\worker"
python -B -m unittest discover -s tests\worker
Get-ChildItem tests\worker -Filter Test-*.ps1 | ForEach-Object { & $_.FullName }
```

The preparation tests use injected process adapters. They do not install packages. The native folder tests use temporary local folders. Pass `-TestRoot` to the desktop build if the default temporary folder is inside a linked or cloud-managed directory. Use a short temporary path for worker tests because the inherited Windows file operations have path-length limits.

The native FFmpeg test remains opt-in. Package installation, Windows approval, a fresh account, reboot recovery and a two-computer round trip have not been validated by controller tests. Those checks are required before a public release.

For a reproducible view of the actual WPF controls without changing setup choices:

```powershell
.\build\NetCrate.exe --render-setup "$env:TEMP\netcrate-setup.png"
.\build\NetCrate.exe --render-setup "$env:TEMP\netcrate-folders.png" --folders --compact
```

These render modes use an in-memory setup store. They do not install tools or touch a configured backup.
