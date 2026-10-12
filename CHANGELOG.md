# Changelog

All notable changes to this project are documented here. This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses Semantic Versioning.

## [Unreleased]

## [1.0.0] - 2026-10-12

First public release.

### Added

- Package builder: compose DSCv3 configuration fragments into a versioned ZIP with pinned `dsc` and PowerShell runtimes and resource modules.
- Windows agent: enforces the configuration on a schedule, handles dependencies between fragments, quarantine, and reboots, and writes JSON Lines results.
- Secured install folder: only SYSTEM and Administrators can access it, links are refused, and an untrusted pre-existing folder is moved aside and replaced with a fresh secure folder. Files unpacked during install are checked for links and must stay inside the install folder.
- Azure VM Application delivery: publish, deploy, and clean up. Published versions are tagged `EnableBlockBlobToPageBlobReplication=True`, so they don't count against the `UnmanagedStorageAccountCount` quota.
- Optional Azure Monitor reporting: ship run, resource, and bootstrap results to Log Analytics tables with the Azure Monitor Agent, plus a Grafana compliance dashboard.
- Guidance for Azure quotas, package-container access, VM network access for reporting, and connecting large fleets.
- Schemas for the configuration file, package manifest, and run results.
- Basic and advanced examples, a quickstart, and an Azure Pipelines release example.
- CI for Windows PowerShell 5.1 and PowerShell 7.

[Unreleased]: https://github.com/microsoft/dsc-orchestrator/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/microsoft/dsc-orchestrator/releases/tag/v1.0.0