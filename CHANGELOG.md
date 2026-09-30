# Changelog

All notable changes to this project are documented here. This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses Semantic Versioning.

## [Unreleased]

## [1.1.0] - 2026-09-30

### Added

- Azure quota and package-container access guidance for VM Application delivery.
- Azure Monitor reporting guidance for VM network access and connecting large fleets.

### Changed

- Published VM Application versions are tagged with `EnableBlockBlobToPageBlobReplication=True`, so Azure replicates them as page blobs that don't count against the `UnmanagedStorageAccountCount` quota.

## [1.0.1] - 2026-09-28

### Security

- An untrusted install folder is now moved aside and replaced with a fresh secure folder, instead of being cleaned in place.
- Permission changes, renames, and deletes in the install folder now act on the folder that was checked, so it cannot be swapped out partway through.
- Files unpacked during install are checked for links and must stay inside the install folder.

### Fixed

- DscRoot paths with trailing separators are normalized, and drive or share roots are rejected.
- Configuration values keep their original string, number, or true/false type when written to YAML.
- Inline dependency lists preserve commas inside resource references.
- Failed upgrades restore the previous runtime so enforcement remains runnable.
- Removal waits for a running enforcement run to finish, also removes the previous runtime folder, and reports failure when the scheduled task or runtime files cannot be removed.
- The Grafana VM inventory panels load when the Resource Group filter is set to All.
- The Grafana Module logs row stays in its place near the bottom instead of pushing the Current State panels down.

## [1.0.0] - 2026-09-26

First release.

### Added

- Package builder: compose DSCv3 configuration fragments into a versioned ZIP with pinned `dsc` and PowerShell runtimes and resource modules.
- Windows agent: enforces the configuration on a schedule, handles dependencies between fragments, quarantine, and reboots, and writes JSON Lines results.
- Secured install folder: only SYSTEM and Administrators can access it, links are refused, and an untrusted pre-existing folder is reset.
- Azure VM Application delivery: publish, deploy, and clean up.
- Optional Azure Monitor reporting: ship run, resource, and bootstrap results to Log Analytics tables with the Azure Monitor Agent, plus a Grafana compliance dashboard.
- Schemas for the configuration file, package manifest, and run results.
- Basic and advanced examples, a quickstart, and an Azure Pipelines release example.
- CI for Windows PowerShell 5.1 and PowerShell 7.

[Unreleased]: https://github.com/microsoft/dsc-orchestrator/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/microsoft/dsc-orchestrator/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/microsoft/dsc-orchestrator/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/microsoft/dsc-orchestrator/releases/tag/v1.0.0
