# Tests

`build/Invoke-CI.ps1` is the repository CI entry point. Run it from the repository root with either supported PowerShell host:

```powershell
pwsh -NoProfile -File .\build\Invoke-CI.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Invoke-CI.ps1
```

The runner installs the pinned Pester 5.7.1, PSScriptAnalyzer 1.25.0, and `powershell-yaml` 0.4.12 modules for the current user if they are unavailable. It analyzes `src/`, discovers every `*.Tests.ps1` below `tests/`, and writes result/coverage files to a temporary directory. The YAML module validates pipeline syntax in `tests/unit/pipelines/` and is not bundled into the runtime package.

To run Pester directly, ensure `powershell-yaml` 0.4.12 is installed because the pipeline contract test parses Azure Pipelines YAML:

```powershell
pwsh -NoProfile -File .\tests\Invoke-PesterTests.ps1
```

The two `Invoke-*SmokeTest.ps1` scripts under `tests/integration/` are standalone checks and are not discovered by Pester. See the unit, integration, and fixture READMEs for coverage details.
