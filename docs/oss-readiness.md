# Microsoft OSS release review

## Complete
- [x] MIT license in place.
- [x] Standard Microsoft SECURITY, SUPPORT, CODE_OF_CONDUCT, and CONTRIBUTING files.
- [x] Internal-only release files removed.
- [x] Fresh public history prepared.
- [x] Internal names scrubbed from release content.
- [x] GitHub Actions CI configured for both supported PowerShell shells.

## Open
- [ ] Microsoft OSS release approval, including business and CELA review.
- [ ] Enable the CLA bot on the repository.
- [ ] Add Component Governance and an SBOM for release artifacts.
- [ ] Harden install-root ACLs: the agent does not harden permissions on `C:\ProgramData\DscOrchestrator` before running as SYSTEM.
- [ ] Test on Windows Server; only Windows 11 25H2 has been tested.
- [ ] Confirm the DSC Orchestrator name and trademark as part of the review.
