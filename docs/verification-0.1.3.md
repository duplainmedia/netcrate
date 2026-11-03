# 0.1.3 development verification

On 3 November 2026, the new path regression reproduced the Windows PowerShell 5.1 extraction failure before the fix. It then passed 78 assertions under each of Windows PowerShell 5.1 and pinned PowerShell 7.6.5. Windows CI runs both hosts.

Checks cover short and long extraction paths, verified downloads/cache reuse, preserved damaged archives, package repair, atomic JSON publication, private permissions and rejection of links, traversal, collisions and reserved device names. The download fixture supplies an in-process HTTPS response; file creation, hashing and publication use the real implementation.

Independent review found no product defects and identified a traversal-fixture assertion checking the wrong location. The corrected assertion failed against a deliberately broken temporary copy, then passed against the real implementation.

Fresh native originals-recovery fixtures passed 36 assertions each at short and long roots. Both passed the actual Windows PowerShell 5.1 to pinned PowerShell 7 recovery bridge, including Unicode metadata, literal names, verified bytes and removal of ephemeral inputs. The long fixture verified a pinned tool file at 326 characters and an archive cache path at 276 characters.

The desktop suites, configuration/dependency checks under both hosts, shared-state checks and versioned packaging passed. Version tests covered the actual `0.1.3` executable and a compiled `0.1.4` fixture. Python passed 19 tests with one inherited opt-in integration skip. Initial local runner argument/import/Temp errors were corrected before these passing runs.

No registry, system PowerShell configuration, live tasks, firewall rules, existing backups or credentials were changed. No release or tag was created. Physical-machine and separate-account acceptance remain on the [experimental roadmap](experimental-roadmap.md).
