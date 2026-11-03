# 0.1.2 development verification

On 3 November 2026, focused checks covered maintenance history capacity, interrupted cleanup, maintenance status, the desktop build and versioned packaging.

The new admission regression first reproduced issue 10 at 256 harmless failures. It checks oldest-safe retirement, protected journal bytes, refusal when all records are protected and validation before deletion. Destructive, unknown and malformed stages remain protected, including differently cased stage fields. This regression runs in Windows CI.

The guarded native cleanup fixture passed with generated repositories. It verified interrupted forget/prune handling, journal preservation at capacity, fresh cleanup confirmation and retained file hashes. The maintenance review and desktop suites passed. Version checks covered the actual `0.1.2` executable and embedded manifest, a compiled `0.1.3` fixture, stale builds, malformed versions, tag matching and installed documents.

The repository README uses the existing tracked logo. No release or tag was created. Physical-machine acceptance remains on the [experimental roadmap](experimental-roadmap.md).
