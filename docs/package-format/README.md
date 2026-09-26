# Input and package format

This document defines the minimal input consumed by the core builder and the ZIP contract delivered to a host. The Azure VM Application adapter should publish the ZIP as an opaque artifact and read package identity from its root `manifest.json`.

The input contract is [dsc-orchestrator-config.schema.json](../../src/core/contracts/dsc-orchestrator-config.schema.json); the ZIP manifest contract is [package-manifest.schema.json](../../src/core/contracts/package-manifest.schema.json). The builder validates both contracts before returning a package.

## Authoring input

Place a `dsc-orchestrator.config.json` beside the fragment tree. It selects fragments, scalar render parameters, and exact resource-module versions:

```json
{
  "schemaVersion": "1.0",
  "name": "example-configuration",
  "version": "1.2.3",
  "group": "desktop-engineering",
  "role": "session-host",
  "parameters": {
    "RegistryPath": "HKLM:\\SOFTWARE\\Example\\Application",
    "Enabled": true
  },
  "fragments": [
    {
      "name": "baseline",
      "path": "fragments/baseline.dsc.yaml"
    }
  ],
  "modules": [
    {
      "name": "Example.Resources",
      "version": "1.0.0"
    }
  ]
}
```

`schemaVersion` must be `1.0`; `name` uses letters, digits, dots, underscores, or hyphens; and the package `version` uses `major.minor.patch`. Resource-module versions accept `major.minor.patch` or `major.minor.patch.revision`; missing version components compare as zero. Optional `group` and `role` are nonempty caller metadata (up to 128 characters). `parameters` is optional and supports scalar values only. `ConfigurationName` and `ConfigurationVersion` are reserved render tokens populated from the top-level fields. Use whole-scalar tokens such as `{{ RegistryPath }}` in fragment YAML.

Each fragment must declare DSC's bundled configuration schema with `$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json`; the builder validates rendered fragments against the schema from the pinned DSC CLI.

Each fragment entry requires a unique `name` and a relative `.dsc.yaml` `path`. Paths resolve from the directory containing the config file and cannot escape that directory. The optional `modules` array requires a unique module name and exact version for each PowerShell resource module.

The composer overwrites the selected generated fragment files but does not delete existing output. If an existing `configs/` tree contains an unselected `.dsc.yaml`, composition fails and leaves it untouched; use a fresh `OutputPath` when changing the fragment set.

Stage modules before packaging:

```powershell
# Default: registered PSGallery repository
.\src\core\package\Save-DSCv3ResourceModules.ps1 `
    -ConfigPath .\dsc-orchestrator.config.json `
    -OutputPath .\artifacts\modules

# A custom repository URI is registered for this staging operation only
.\src\core\package\Save-DSCv3ResourceModules.ps1 `
    -ConfigPath .\dsc-orchestrator.config.json `
    -OutputPath .\artifacts\modules `
    -RepositoryUri 'https://packages.example.invalid/nuget/v2'

# A local module tree uses <LocalPath>\<ModuleName>\<Version>\...
.\src\core\package\Save-DSCv3ResourceModules.ps1 `
    -ConfigPath .\dsc-orchestrator.config.json `
    -OutputPath .\artifacts\modules `
    -LocalPath .\module-cache
```

The module staging script returns objects describing the staged name, actual version-folder name, source, and path. When repository and declared versions differ only by omitted zero components, staging accepts the match and reports the actual folder name. The package manifest and ZIP use that same version folder under `modules/<module>/<version>`. The composer returns its configuration identity, hash, manifest path, and fragment/resource counts. The package builder returns the final ZIP path and package metadata; none of these core scripts writes ADO output variables.

## Produced ZIP

The archive is named `dsc-orchestrator-<name>-<version>.zip`. Entries are at the ZIP root; there is no enclosing directory.

```text
manifest.json                 Package and fragment contract
metadata.json                 Build/runtime context sidecar
version.txt                   Package version for the Windows agent
dsc.exe                       Pinned DSC CLI plus its runtime files
pwsh/                         Pinned PowerShell 7 runtime
configs/<fragment>/<fragment>.dsc.yaml
modules/<resource-module>/<version>/...
modules/DscOrchestrator.Reboot/  Built-in Request-DscReboot module
AppModules/                   Agent helper modules and manifests
AppModules/Shared/Dsc.YamlLines.psm1
bootstrap.ps1
Install-VmApplicationPackage.ps1
Invoke-Enforcement.ps1
Run-Enforcement.ps1
remove.ps1
Resolve-PwshExe.ps1
Write-BootstrapJsonLine.ps1
```

`manifest.json` is authoritative for identity, runtime versions, module versions, fragment order, and dependencies. Required fields and hash semantics are specified in [the package manifest contract](../../src/core/contracts/package-manifest.md). `metadata.json` is an agent sidecar, not an alternate identity source. It carries the package configuration hash and any configured `group` and `role`; the agent includes these values in local JSONL results. `version.txt` mirrors `manifest.json.version` for the existing Windows runtime. The local JSONL run/resource records follow the separate [run-result contract](../../src/core/contracts/run-result.md).

The built-in installer `Install-VmApplicationPackage.ps1` isolates the VM Application ZIP assumption. The delivery adapter supplies `-PackageArchivePath` and the expected `-Version`; the installer extracts with Windows `tar.exe`, verifies the root manifest version, then invokes `bootstrap.ps1` on the extracted package directory. A local/file-share delivery adapter can invoke `bootstrap.ps1 -PackageRoot <extracted-directory>` directly; bootstrap enforces the same manifest-version check for that path.

The package targets Windows x64. DSC and PowerShell versions come from the pinned `tools-manifest.json`; the ZIP carries their upstream release files, including license/notice files. `powershell-yaml` is a build-time dependency used for dependency parsing and DSC schema validation; it is not bundled into the runtime package. The release pipeline and CI use `powershell-yaml` 0.4.12 from PSGallery.

Install `powershell-yaml` in the same PowerShell 7 environment before using the one-command package wrapper. The wrapper fails fast when the module is missing but does not enforce its version. The package ZIP does not include this build-time dependency.
