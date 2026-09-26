# Integration smoke tests

These standalone scripts are not Pester suites:

- `Invoke-BootstrapJsonlSmokeTest.ps1` verifies BOM-less, single-line JSON output and required bootstrap fields.
- `Invoke-ModuleStagingCollisionSmokeTest.ps1` verifies that agent helper modules are staged separately from resource modules and that the shared YAML implementation is included.

Run them from the repository root with PowerShell 7:

```powershell
pwsh -NoProfile -File .\tests\integration\Invoke-BootstrapJsonlSmokeTest.ps1
pwsh -NoProfile -File .\tests\integration\Invoke-ModuleStagingCollisionSmokeTest.ps1
```

Both scripts use a temporary test directory and return a nonzero exit code when an assertion fails.
