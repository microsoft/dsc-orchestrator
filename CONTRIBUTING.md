# Contributing

## Run checks locally

Run the CI checks from the repository root in both supported PowerShell shells:

```powershell
pwsh -NoProfile -File .\build\Invoke-CI.ps1
powershell.exe -NoProfile -File .\build\Invoke-CI.ps1
```

The script runs PSScriptAnalyzer and the Pester test suite. It installs the pinned test and analysis modules from PSGallery when they are not available.

## Pull requests

- Add or update tests for behavior changes.
- Include a `CHANGELOG.md` entry under `[Unreleased]`.
- Use Semantic Versioning: breaking changes increment MAJOR, backward-compatible features MINOR, and fixes PATCH.
- Keep changes focused and update relevant documentation.

This project welcomes contributions and suggestions. Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

This project has adopted the [Microsoft Open Source Code of Conduct](CODE_OF_CONDUCT.md). For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.
