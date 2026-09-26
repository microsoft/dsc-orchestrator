#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:AdapterRoot = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp'
    $script:PublishScript = Join-Path $script:AdapterRoot 'Publish-DSCv3VMApp.ps1'
    $script:DeployScript = Join-Path $script:AdapterRoot 'Deploy-DSCv3VMApp.ps1'
    $script:PublishModuleManifest = Join-Path $script:AdapterRoot 'Modules\Dsc.Publish.psd1'
    $script:TestSubscriptionId = [guid]::NewGuid().ToString()
    $script:VersionResourceId = "/subscriptions/$script:TestSubscriptionId/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.4.0"
    $script:OriginalTfBuild = $env:TF_BUILD
    $script:PackageWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('orchestrator-package-fixture-' + [guid]::NewGuid().ToString('N'))
    $script:PackageFixtureRoot = Join-Path $script:PackageWorkspace 'source'
    $script:PackageFileName = 'dsc-orchestrator-sample-configuration-1.4.0.zip'
    $script:PackagePath = Join-Path $script:PackageWorkspace $script:PackageFileName
    New-Item -ItemType Directory -Path $script:PackageFixtureRoot -Force | Out-Null

    foreach ($entryName in @('Install-VmApplicationPackage.ps1', 'bootstrap.ps1', 'remove.ps1')) {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot (Join-Path 'src\agent\windows' $entryName)) `
            -Destination (Join-Path $script:PackageFixtureRoot $entryName) -Force
    }
    $manifest = [ordered]@{
        schemaVersion = '1.0'
        name = 'sample-configuration'
        version = '1.4.0'
        configurationHash = ('a' * 64)
        target = [ordered]@{ os = 'windows'; architecture = 'x64' }
        runtime = [ordered]@{ dscVersion = '3.2.0'; powerShellVersion = '7.6.2' }
        resourceModules = @()
        agentModules = @()
        fragments = @()
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText(
        (Join-Path $script:PackageFixtureRoot 'manifest.json'),
        $manifestJson,
        [System.Text.UTF8Encoding]::new($false)
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::CreateFromDirectory($script:PackageFixtureRoot, $script:PackagePath)
    Import-Module $script:PublishModuleManifest -Force -DisableNameChecking

    function New-TestContext {
        [pscustomobject]@{
            Subscription = [pscustomobject]@{ Id = 'test-sub' }
            Account = [pscustomobject]@{ Id = 'test-identity' }
        }
    }

    function Invoke-PublishSkip {
        $parameters = @{
            PackagePath = $script:PackagePath
            StorageAccountName = 'sampleacct'
            StorageAccountResourceGroup = 'storage-rg'
            ContainerName = 'packages'
            GalleryName = 'gallery'
            GalleryResourceGroup = 'gallery-rg'
            ApplicationName = 'Sample Agent'
            Version = '1.4.0'
            Location = 'eastus'
            IfExists = 'Skip'
        }

        @(& $script:PublishScript @parameters 6>&1)
    }
}

AfterAll {
    $env:TF_BUILD = $script:OriginalTfBuild
    Remove-Item -LiteralPath $script:PackageWorkspace -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Publish-DSCv3VMApp' {
    BeforeEach {
        $env:TF_BUILD = ''
        Mock Get-AzContext { New-TestContext }
        Mock Get-AzContext -ModuleName Dsc.Publish.GalleryRbac { New-TestContext }
        Mock Get-AzGallery -ModuleName Dsc.Publish.GalleryRbac {
            [pscustomobject]@{
                Identity = [pscustomobject]@{ PrincipalId = 'gallery-identity' }
            }
        }
        Mock Get-AzStorageAccount -ModuleName Dsc.Publish.GalleryRbac {
            [pscustomobject]@{
                Id = '/subscriptions/test-sub/resourceGroups/storage-rg/providers/Microsoft.Storage/storageAccounts/sampleacct'
            }
        }
        Mock Get-AzRoleAssignment -ModuleName Dsc.Publish.GalleryRbac {
            [pscustomobject]@{
                RoleDefinitionName = 'Storage Blob Data Reader'
                Scope = '/subscriptions/test-sub/resourceGroups/storage-rg/providers/Microsoft.Storage/storageAccounts/sampleacct/blobServices/default/containers/packages'
            }
        }
        Mock New-AzRoleAssignment -ModuleName Dsc.Publish.GalleryRbac { }
        Mock Get-AzGalleryApplicationVersion -ModuleName Dsc.Publish.GalleryApp {
            [pscustomobject]@{
                Name = $Name
                Id = '/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.4.0'
            }
        }
        Mock New-AzStorageContext -ModuleName Dsc.Publish.Blob { throw 'Upload must not run for an existing version.' }
    }

    It 'uses explicit package, version, and application inputs and returns a neutral skip object' {
        $env:TF_BUILD = 'True'
        $output = @(Invoke-PublishSkip)
        $successOutput = @(
            $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }
        )
        $result = $successOutput[0]
        $pipelineVariables = @(
            $output | ForEach-Object {
                if ($_ -is [string] -and $_ -like '##vso*') {
                    $_
                }
                elseif ($_ -is [System.Management.Automation.InformationRecord] -and
                    [string]$_.MessageData -like '##vso*') {
                    [string]$_.MessageData
                }
            }
        )

        $successOutput | Should -HaveCount 1
        $result.ApplicationName | Should -Be 'sample-agent'
        $result.Version | Should -Be '1.4.0'
        $result.VMAppVersionId | Should -Be '/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.4.0'
        $result.Action | Should -Be 'skipped'
        Should -Invoke Get-AzGalleryApplicationVersion -ModuleName Dsc.Publish.GalleryApp -Times 1 -Exactly -ParameterFilter {
            $GalleryApplicationName -eq 'sample-agent' -and $Name -eq '1.4.0'
        }
        Should -Invoke New-AzStorageContext -ModuleName Dsc.Publish.Blob -Times 0 -Exactly
        $pipelineVariables | Should -HaveCount 3
        $pipelineVariables | Should -Contain '##vso[task.setvariable variable=VMAppVersionId;isOutput=true]/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.4.0'
        $pipelineVariables | Should -Contain '##vso[task.setvariable variable=VMAppVersion;isOutput=true]1.4.0'
        $pipelineVariables | Should -Contain '##vso[task.setvariable variable=VMAppPublishAction;isOutput=true]skipped'
    }

    It 'returns one publish result without Azure DevOps variables when TF_BUILD is unset' {
        $env:TF_BUILD = ''
        $output = @(Invoke-PublishSkip)
        $successOutput = @(
            $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }
        )
        $variableLines = @(
            $output | ForEach-Object {
                if ($_ -is [string] -and $_ -like '##vso*') {
                    $_
                }
                elseif ($_ -is [System.Management.Automation.InformationRecord] -and
                    [string]$_.MessageData -like '##vso*') {
                    [string]$_.MessageData
                }
            }
        )

        $successOutput | Should -HaveCount 1
        $successOutput[0].Version | Should -Be '1.4.0'
        $successOutput[0].VMAppVersionId | Should -Be '/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.4.0'
        $variableLines | Should -HaveCount 0
    }

    It 'rejects a requested version that differs from the core package manifest before Azure access' {
        {
            & $script:PublishScript `
                -PackagePath $script:PackagePath `
                -StorageAccountName 'sampleacct' `
                -StorageAccountResourceGroup 'storage-rg' `
                -ContainerName 'packages' `
                -GalleryName 'gallery' `
                -GalleryResourceGroup 'gallery-rg' `
                -ApplicationName 'sample-agent' `
                -Version '1.4.1' `
                -Location 'eastus' `
                -IfExists Skip
        } | Should -Throw -ExpectedMessage '*does not match package manifest version*'

        Should -Invoke Get-AzContext -Times 0 -Exactly
        Should -Invoke Get-AzGalleryApplicationVersion -ModuleName Dsc.Publish.GalleryApp -Times 0 -Exactly
    }
}

Describe 'Deploy-DSCv3VMApp' {
    BeforeEach {
        Mock Get-AzContext { New-TestContext }
        Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = 'workload-rg' } }
        Mock Get-AzVM -ParameterFilter { -not $Name } { @() }
        Mock Get-AzGalleryApplicationVersion { throw 'Gallery lookup must not run with no targets.' }
    }

    It 'logs and returns successfully without gallery lookup when the target resource group is empty' {
        $result = & $script:DeployScript `
            -ResourceGroupName 'workload-rg' `
            -VMAppVersionResourceId $script:VersionResourceId `
            -Confirm:$false

        $result.Skipped | Should -BeTrue
        $result.VmCount | Should -Be 0
        $result.VMNames | Should -BeNullOrEmpty
        Should -Invoke Get-AzVM -Times 1 -Exactly -ParameterFilter { -not $Name }
        Should -Invoke Get-AzGalleryApplicationVersion -Times 0 -Exactly
    }

    It 'starts Update-AzVM jobs with a normal confirmation preference in a child scope' {
        $tokens = $null
        $parseErrors = $null
        $deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:DeployScript,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty

        $helperAst = $deployAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Start-VMUpdateJob'
        }, $true)
        $helperAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($helperAst.Extent.Text))

        $script:ObservedUpdateConfirmPreference = $null
        Mock Update-AzVM {
            $script:ObservedUpdateConfirmPreference = $ConfirmPreference
            [pscustomobject]@{ Name = 'mock-update-job' }
        }

        & {
            $ConfirmPreference = 'None'
            Start-VMUpdateJob -ResourceGroupName 'workload-rg' -VM ([pscustomobject]@{ Name = 'vm01' })
        } | Out-Null

        $script:ObservedUpdateConfirmPreference | Should -Be 'High'
        Should -Invoke Update-AzVM -Times 1 -Exactly -ParameterFilter { $AsJob }
    }

    It 'captures the scoped VM update helper for initial and retry updates' {
        $tokens = $null
        $parseErrors = $null
        $deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:DeployScript,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty

        $helperCalls = @($deployAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Start-VMUpdateJob'
        }, $true))
        $updateCalls = @($deployAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Update-AzVM'
        }, $true))

        $helperCalls | Should -HaveCount 1
        $deployAst.Extent.Text | Should -Match '\$startVMUpdateJob\s*=\s*\$\{function:Start-VMUpdateJob\}'
        $deployAst.Extent.Text | Should -Match '&\s*\$startVMUpdateJob\s+-ResourceGroupName'
        $updateCalls | Should -HaveCount 1
    }
}

Describe 'ConvertTo-AzureSafeGalleryApplicationName' {
    It 'normalizes explicit caller names and shortens long names with a hash suffix' {
        $converter = Join-Path $script:AdapterRoot 'ConvertTo-AzureSafeGalleryApplicationName.ps1'
        . $converter

        ConvertTo-AzureSafeGalleryApplicationName -Name 'Sample Agent / West' | Should -Be 'sample-agent-west'

        $longName = 'x' * 100
        $safeName = ConvertTo-AzureSafeGalleryApplicationName -Name $longName
        $safeName.Length | Should -BeLessOrEqual 80
        $safeName | Should -Match '^x+-[0-9a-f]{12}$'
    }
}

Describe 'Core VM Application package contract' {
    It 'builds install, update, and remove commands from entry points present in the core-shaped ZIP' {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($script:PackagePath)
        try {
            $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        }
        finally {
            $archive.Dispose()
        }

        foreach ($entryName in @('manifest.json', 'Install-VmApplicationPackage.ps1', 'bootstrap.ps1', 'remove.ps1')) {
            $entryNames | Should -Contain $entryName
        }

        $installPath = Join-Path $script:RepoRoot 'src\agent\windows\Install-VmApplicationPackage.ps1'
        $removePath = Join-Path $script:RepoRoot 'src\agent\windows\remove.ps1'
        $tokens = $null
        $parseErrors = $null
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $installParameters = @($installAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $installParameters | Should -Contain 'PackageArchivePath'
        $installParameters | Should -Contain 'Version'
        $installParameters | Should -Contain 'DscRoot'
        $installParameters | Should -Contain 'Update'

        $removeTokens = $null
        $removeParseErrors = $null
        $removeAst = [System.Management.Automation.Language.Parser]::ParseFile($removePath, [ref]$removeTokens, [ref]$removeParseErrors)
        $removeParseErrors | Should -BeNullOrEmpty
        $removeParameters = @($removeAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $removeParameters | Should -Contain 'DscRoot'

        $dscRoot = 'D:\Orchestrator Test Root'
        $installCommand = ConvertTo-VMApplicationPackageCommand `
            -Action Install -PackageFileName $script:PackageFileName -Version '1.4.0' -DscRoot $dscRoot
        $updateCommand = ConvertTo-VMApplicationPackageCommand `
            -Action Update -PackageFileName $script:PackageFileName -Version '1.4.0' -DscRoot $dscRoot
        $removeCommand = ConvertTo-VMApplicationRemoveCommand `
            -PackageFileName $script:PackageFileName -DscRoot $dscRoot

        $escapedPackageName = [regex]::Escape($script:PackageFileName)
        $escapedDscRoot = [regex]::Escape($dscRoot)
        $installCommand | Should -Match 'Install-VmApplicationPackage\.ps1'
        $installCommand | Should -Match '-PackageArchivePath'
        $installCommand | Should -Match '-Version'
        $installCommand | Should -Match '-DscRoot'
        $installCommand | Should -Match $escapedPackageName
        $installCommand | Should -Match $escapedDscRoot
        $installCommand | Should -Not -Match 'bootstrap\.ps1'
        $updateCommand | Should -Match '-Update'
        $removeCommand | Should -Match 'remove\.ps1'
        $removeCommand | Should -Match '-DscRoot'
        $removeCommand | Should -Match $escapedPackageName
        $removeCommand | Should -Match $escapedDscRoot
    }
}
