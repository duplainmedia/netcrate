# Synthetic fixtures

Run Generate-Fixtures.ps1 with PowerShell 7 to reproduce the example metadata using the exported pure identity/validation functions. All identities derive from new `netcrate-public-fixture-v1` seeds; none describe a real snapshot. A snapshot ID is opaque in Restic: the fixture values are representative full hashes, not existing repository objects.

The footage identity hash uses actual PowerShell compressed JSON and the current recipe. `snapshot-nodes.json` contains one invented Restic tree file node. Its content IDs are synthetic, not hashes of the entire original file; Restic chunk IDs and whole-file SHA-256 have distinct meanings. The 41-byte size is synthetic tree metadata, not an exported original. Fixtures do not claim media validation occurred.

`synthetic-payload-spec.json` defines exact UTF-8 stand-in bytes for the two file names in Files-SHA256.csv. No MOV/JPEG files are included. The CSV byte sizes and uppercase SHA-256 values are reproducible from these strings. COMPLETE.json represents the protocol's success shape only; it is not an execution receipt. `delivery.json` is the actual acknowledgement wire filename. `progress.json` has the exact 25-field public schema. Identities link request, footage fingerprint/job, result and ACK consistently. Static dates demonstrate serialization and must not be used as a live request/replay cutoff.

The configuration and credential schema files contain explanatory dummy values, never encrypted real material. They are reference schemas, not installable config or valid credentials.
