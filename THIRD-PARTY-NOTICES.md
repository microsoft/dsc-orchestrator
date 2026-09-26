# Third-party notices

The repository itself contains no third-party code. At package build time, the builder downloads and bundles the tools listed below. The pinned versions and download URLs are recorded in [tools-manifest.json](src/core/package/tools-manifest.json).

| Component | Version | License | Source |
| --- | --- | --- | --- |
| PowerShell DSC CLI (`dsc`) | 3.2.0 | MIT | [Download](https://github.com/PowerShell/DSC/releases/download/v3.2.0/DSC-3.2.0-x86_64-pc-windows-msvc.zip) |
| PowerShell 7 | 7.6.2 | MIT | [Download](https://github.com/PowerShell/PowerShell/releases/download/v7.6.2/PowerShell-7.6.2-win-x64.zip) |
| `powershell-yaml` (build-time dependency) | 0.4.12 | Apache-2.0 | [PowerShell Gallery](https://www.powershellgallery.com/packages/powershell-yaml/0.4.12); [upstream license](https://github.com/cloudbase/powershell-yaml/blob/master/LICENSE) |

The builder also downloads and bundles any PowerShell resource modules declared by the user. Those modules remain under their own licenses; the user is responsible for confirming that redistribution is permitted and for providing the applicable notices.

`powershell-yaml` is installed from PowerShell Gallery for build-time parsing and is not bundled in the package. CI also installs Pester 5.7.1 and PSScriptAnalyzer 1.25.0 from PowerShell Gallery; these test and analysis dependencies are not bundled in the package.
