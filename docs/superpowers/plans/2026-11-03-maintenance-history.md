# Maintenance history capacity

Fix [issue 10](https://github.com/duplainmedia/netcrate/issues/10) on a branch from merged main `0bc86416c642c4377c243d30cb308c20887fd3f5`. Execute inline with test-first debugging, then obtain an independent review. The user authorized autonomous work and requested a PR.

Only validated terminal records with no unfinished destructive work may be retired. For ApplyRetention, missing stages and the known Confirmed/Completed stages are safe; ForgetStarted, ForgetVerified, PruneStarted and unknown or malformed stages remain protected. Queued/running records remain protected. Preserve the 256-record bound, oldest-safe-first behavior and validation before any deletion. Do not change repository operations or production state.

- [x] Reproduce saturation with 256 harmless attention records.
- [x] Add real admission tests for safe terminal cases, mixed protected journals, a fully protected history, unknown stages and malformed identity. Verify preserved bytes, not just counts.
- [x] Implement a small fail-closed retirement predicate and retain existing admission locking.
- [x] Run the new regression, native cleanup/history regression, maintenance checks, desktop/versioning and package checks using disposable Temp fixtures.
- [x] Add the existing logo to the README header and validate its tracked asset path.
- [x] Set the next development patch to `0.1.2`, retain Unreleased notes and remove the resolved roadmap limitation. Do not invent a release/tag.
- [ ] Obtain an independent scoped review, push the branch and open a PR. Leave merge and publication to the user.
