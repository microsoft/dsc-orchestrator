#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:WindowsAgentRoot = Join-Path $script:RepoRoot 'src\agent\windows'
    $script:SecurityModulePath = Join-Path $script:WindowsAgentRoot 'Modules\Dsc.Security.psm1'
    Import-Module $script:SecurityModulePath -Force -DisableNameChecking
    $script:SecurityModule = Get-Module Dsc.Security

    function New-SyntheticDirectoryAcl {
        param(
            [Parameter(Mandatory = $true)]
            [string]$OwnerSid,

            [bool]$Protected = $true,

            [object[]]$AccessRules = @()
        )

        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($Protected, $false)
        $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new($OwnerSid))
        foreach ($accessRule in $AccessRules) {
            $acl.AddAccessRule($accessRule)
        }
        return $acl
    }

    function New-SyntheticAccessRule {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Sid,

            [Parameter(Mandatory = $true)]
            [System.Security.AccessControl.FileSystemRights]$Rights,

            [System.Security.AccessControl.AccessControlType]$Type =
                [System.Security.AccessControl.AccessControlType]::Allow,

            [System.Security.AccessControl.PropagationFlags]$PropagationFlags =
                [System.Security.AccessControl.PropagationFlags]::None
        )

        $identity = [System.Security.Principal.SecurityIdentifier]::new($Sid)
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
        if ($PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
        }
        return [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            $Rights,
            $inheritance,
            $PropagationFlags,
            $Type
        )
    }

    function Test-SyntheticRoot {
        param(
            [System.Security.AccessControl.DirectorySecurity]$Acl,
            [bool]$IsDirectory = $true,
            [bool]$IsReparsePoint = $false
        )

        & $script:SecurityModule {
            param($DirectoryAcl, $Directory, $ReparsePoint)
            Test-DscOrchestratorRootTrusted `
                -Acl $DirectoryAcl `
                -IsDirectory $Directory `
                -IsReparsePoint $ReparsePoint
        } $Acl $IsDirectory $IsReparsePoint
    }

    function Test-SyntheticParent {
        param([System.Security.AccessControl.DirectorySecurity]$Acl)

        & $script:SecurityModule {
            param($DirectoryAcl)
            Test-DscOrchestratorParentAcl -Acl $DirectoryAcl
        } $Acl
    }

    function Set-UntrustedTestDirectoryAcl {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            ))
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            ))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }

    function Get-TopLevelSensitiveCommands {
        param([Parameter(Mandatory = $true)]$Ast)

        $Ast.FindAll({
            param($node)

            if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
                return $false
            }

            $ancestor = $node.Parent
            while ($null -ne $ancestor) {
                if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    return $false
                }
                $ancestor = $ancestor.Parent
            }

            $commandName = [string]$node.GetCommandName()
            $commandName -in @(
                'New-Item',
                'Write-BootstrapJsonLine',
                'Start-Transcript',
                'Set-Content',
                'Add-Content',
                'tar.exe'
            )
        }, $true)
    }

    function Get-FunctionAst {
        param(
            [Parameter(Mandatory = $true)]$Ast,
            [Parameter(Mandatory = $true)][string]$Name
        )

        $Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        }, $true)
    }
}

$script:IsAdmin = [System.Security.Principal.WindowsPrincipal]::new(
    [System.Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

Describe 'Dsc.Orchestrator install-root security' {

    Context 'trusted-root evaluation' {
        It 'accepts a protected directory owned by Administrators with only SYSTEM and Administrators write ACEs' {
            $acl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -AccessRules @(
                (New-SyntheticAccessRule -Sid 'S-1-5-18' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-544' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-545' -Rights ReadAndExecute)
            )

            Test-SyntheticRoot -Acl $acl | Should -BeTrue
        }

        It 'rejects a directory with an untrusted owner' {
            $acl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-21-1-2-3-1001' -AccessRules @(
                (New-SyntheticAccessRule -Sid 'S-1-5-18' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-544' -Rights FullControl)
            )

            Test-SyntheticRoot -Acl $acl | Should -BeFalse
        }

        It 'rejects an additional Users write ACE' {
            $acl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -AccessRules @(
                (New-SyntheticAccessRule -Sid 'S-1-5-18' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-544' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-545' -Rights Write)
            )

            Test-SyntheticRoot -Acl $acl | Should -BeFalse
        }

        It 'rejects an inherited DACL' {
            $acl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -Protected $false -AccessRules @(
                (New-SyntheticAccessRule -Sid 'S-1-5-18' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-544' -Rights FullControl)
            )

            Test-SyntheticRoot -Acl $acl | Should -BeFalse
        }

        It 'rejects a non-directory and a reparse point' {
            $acl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -AccessRules @(
                (New-SyntheticAccessRule -Sid 'S-1-5-18' -Rights FullControl)
                (New-SyntheticAccessRule -Sid 'S-1-5-32-544' -Rights FullControl)
            )

            Test-SyntheticRoot -Acl $acl -IsDirectory $false | Should -BeFalse
            Test-SyntheticRoot -Acl $acl -IsReparsePoint $true | Should -BeFalse
        }
    }

    Context 'parent ACL evaluation' {
        It 'allows the real ProgramData ACL' {
            $programDataAcl = Get-Acl -LiteralPath 'C:\ProgramData' -ErrorAction Stop

            Test-SyntheticParent -Acl $programDataAcl | Should -BeTrue
        }

        It 'rejects non-trusted delete, delete-child, modify, change-permission, and take-ownership grants' {
            $rightsToReject = @(
                [System.Security.AccessControl.FileSystemRights]::Delete
                [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
                [System.Security.AccessControl.FileSystemRights]::Modify
                [System.Security.AccessControl.FileSystemRights]::ChangePermissions
                [System.Security.AccessControl.FileSystemRights]::TakeOwnership
                [System.Security.AccessControl.FileSystemRights]::FullControl
            )

            foreach ($rights in $rightsToReject) {
                $acl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -AccessRules @(
                    (New-SyntheticAccessRule -Sid 'S-1-5-32-545' -Rights $rights)
                )
                Test-SyntheticParent -Acl $acl | Should -BeFalse
            }
        }

        It 'ignores InheritOnly grants and permits the TrustedInstaller SID' {
            $inheritOnlyAcl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -AccessRules @(
                (New-SyntheticAccessRule `
                    -Sid 'S-1-5-32-545' `
                    -Rights FullControl `
                    -PropagationFlags InheritOnly)
            )
            $trustedInstallerAcl = New-SyntheticDirectoryAcl -OwnerSid 'S-1-5-32-544' -AccessRules @(
                (New-SyntheticAccessRule `
                    -Sid 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' `
                    -Rights Delete)
            )

            Test-SyntheticParent -Acl $inheritOnlyAcl | Should -BeTrue
            Test-SyntheticParent -Acl $trustedInstallerAcl | Should -BeTrue
        }
    }

    It 'keeps the in-memory installer copies of the security functions identical to the module AST' {
        $moduleTokens = $null
        $moduleErrors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:SecurityModulePath,
            [ref]$moduleTokens,
            [ref]$moduleErrors
        )
        $installPath = Join-Path $script:WindowsAgentRoot 'Install-VmApplicationPackage.ps1'
        $installTokens = $null
        $installErrors = $null
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installPath,
            [ref]$installTokens,
            [ref]$installErrors
        )
        $moduleErrors | Should -BeNullOrEmpty
        $installErrors | Should -BeNullOrEmpty

        foreach ($functionName in @(
                'Test-DscOrchestratorRootTrusted',
                'Test-DscOrchestratorParentAcl',
                'Get-DscOrchestratorPathItem',
                'New-DscOrchestratorSecureAcl',
                'Initialize-DscOrchestratorNative',
                'New-DscOrchestratorSecureDirectory',
                'New-DscOrchestratorRootDirectory',
                'Set-DscOrchestratorSecureAcl',
                'Remove-DscOrchestratorPathSafely',
                'Initialize-DscOrchestratorSubdirectory',
                'Write-DscOrchestratorRootResetEvent',
                'Initialize-DscOrchestratorRoot'
            )) {
            $moduleFunction = Get-FunctionAst -Ast $moduleAst -Name $functionName
            $installFunction = Get-FunctionAst -Ast $installAst -Name $functionName
            $moduleFunction | Should -Not -BeNullOrEmpty -Because $functionName
            $installFunction | Should -Not -BeNullOrEmpty -Because $functionName
            $installFunction.Extent.Text |
                Should -BeExactly $moduleFunction.Extent.Text -Because $functionName
        }
    }

    It 'uses Dsc.Security from the bootstrap child scope when installer functions exist in the parent scope' {
        $installPath = Join-Path $script:WindowsAgentRoot 'Install-VmApplicationPackage.ps1'
        $installTokens = $null
        $installErrors = $null
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $installPath,
            [ref]$installTokens,
            [ref]$installErrors
        )
        $installErrors | Should -BeNullOrEmpty

        $embeddedFunctionNames = @(
            'Test-DscOrchestratorRootTrusted',
            'Test-DscOrchestratorParentAcl',
            'Get-DscOrchestratorPathItem',
            'New-DscOrchestratorSecureAcl',
            'Initialize-DscOrchestratorNative',
            'New-DscOrchestratorSecureDirectory',
            'New-DscOrchestratorRootDirectory',
            'Set-DscOrchestratorSecureAcl',
            'Remove-DscOrchestratorPathSafely',
            'Initialize-DscOrchestratorSubdirectory',
            'Write-DscOrchestratorRootResetEvent',
            'Initialize-DscOrchestratorRoot'
        )
        $embeddedFunctionAsts = @(
            foreach ($functionName in $embeddedFunctionNames) {
                Get-FunctionAst -Ast $installAst -Name $functionName
            }
        )
        $embeddedFunctionAsts | Should -HaveCount $embeddedFunctionNames.Count

        $parentScopeLines = @(
            'param([string]$ModulePath, [string]$DscRoot)'
            'Set-StrictMode -Version Latest'
        )
        $parentScopeLines += @($embeddedFunctionAsts | ForEach-Object { $_.Extent.Text })
        $parentScopeLines += @(
            '& {'
            '    param([string]$ModulePath, [string]$DscRoot)'
            '    Set-StrictMode -Version Latest'
            '    Import-Module -Name $ModulePath -DisableNameChecking -ErrorAction Stop'
            "    if (-not (Get-Module -Name 'Dsc.Security')) { throw 'Dsc.Security was not imported.' }"
            '    Dsc.Security\Initialize-DscOrchestratorRoot -Path $DscRoot'
            "    `$logsRoot = Dsc.Security\Initialize-DscOrchestratorSubdirectory -RootPath `$DscRoot -Name 'logs'"
            "    `$stagingRoot = Dsc.Security\Initialize-DscOrchestratorSubdirectory -RootPath `$DscRoot -Name 'staging'"
            "    `$currentPath = Dsc.Security\Initialize-DscOrchestratorSubdirectory -RootPath `$DscRoot -Name 'current'"
            "    `$previousPath = Dsc.Security\Initialize-DscOrchestratorSubdirectory -RootPath `$DscRoot -Name 'current.previous'"
            "    `$stalePath = Join-Path `$stagingRoot 'stale.txt'"
            "    Set-Content -LiteralPath `$stalePath -Value 'stale' -ErrorAction Stop"
            '    Dsc.Security\Remove-DscOrchestratorPathSafely -Path $stalePath'
            '    if (Test-Path -LiteralPath $stalePath) { throw "The staging path was not removed: $stalePath" }'
            "    `$previousTarget = Join-Path (Split-Path -Parent `$DscRoot) 'dsc-security-previous-target'"
            '    New-Item -ItemType Directory -Path $previousTarget -Force -ErrorAction Stop | Out-Null'
            "    Set-Content -LiteralPath (Join-Path `$previousTarget 'sentinel.txt') -Value 'keep' -ErrorAction Stop"
            '    Dsc.Security\Remove-DscOrchestratorPathSafely -Path $previousPath'
            '    New-Item -ItemType Junction -Path $previousPath -Target $previousTarget -ErrorAction Stop | Out-Null'
            "    `$previousPath = Dsc.Security\Initialize-DscOrchestratorSubdirectory -RootPath `$DscRoot -Name 'current.previous'"
            "    if (-not (Test-Path -LiteralPath (Join-Path `$previousTarget 'sentinel.txt'))) { throw 'The current.previous junction target was removed.' }"
            '} $ModulePath $DscRoot'
        )
        $parentScopeScript = [scriptblock]::Create(
            $parentScopeLines -join [System.Environment]::NewLine
        )

        $root = Join-Path $TestDrive 'dsc-security-parent-scope-root'
        InModuleScope Dsc.Security {
            Mock Test-DscOrchestratorParentAcl { $true }
            Mock New-DscOrchestratorSecureDirectory {
                [System.IO.Directory]::CreateDirectory($Path) | Out-Null
            }
            Mock New-DscOrchestratorSecureAcl {
                $acl = [System.Security.AccessControl.DirectorySecurity]::new()
                $acl.SetAccessRuleProtection($true, $false)
                $ownerSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                $acl.SetOwner($ownerSid)
                $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                    $ownerSid,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
                $acl.AddAccessRule($rule)
                return $acl
            }
        }

        & $parentScopeScript $script:SecurityModulePath $root

        Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'logs') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'staging') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'current') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'current.previous') -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Split-Path -Parent $root) 'dsc-security-previous-target\sentinel.txt') |
            Should -BeTrue
    }

    It 'module-qualifies security helper calls in bootstrap, remove, and staging scripts' {
        $entryPaths = @(
            'bootstrap.ps1',
            'remove.ps1',
            'Modules\Dsc.Bootstrap.Staging.psm1'
        )
        $securityFunctionNames = @(
            'Initialize-DscOrchestratorRoot',
            'Initialize-DscOrchestratorSubdirectory',
            'Remove-DscOrchestratorPathSafely'
        )
        $securityFunctionPattern = '^(?:Dsc\.Security\\)?(?:' +
            ($securityFunctionNames -join '|') +
            ')$'

        foreach ($entryPath in $entryPaths) {
            $path = Join-Path $script:WindowsAgentRoot $entryPath
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty -Because $entryPath

            $securityCalls = @(
                $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) | Where-Object {
                    ([string]$_.GetCommandName()) -match $securityFunctionPattern
                }
            )
            $securityCalls | Should -Not -BeNullOrEmpty -Because $entryPath
            foreach ($call in $securityCalls) {
                $commandName = [string]$call.GetCommandName()
                $functionName = ($commandName -split '\\')[-1]
                $commandName | Should -BeExactly "Dsc.Security\$functionName" -Because $entryPath
            }
        }
    }

    It 'hardens the root before each entry point creates files, writes logs, or extracts an archive' {
        foreach ($entryPoint in @(
                'Install-VmApplicationPackage.ps1',
                'bootstrap.ps1',
                'remove.ps1'
            )) {
            $entryPath = Join-Path $script:WindowsAgentRoot $entryPoint
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $entryPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty -Because $entryPoint

            $rootCall = @(
                $ast.FindAll({
                    param($node)
                    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
                        [string]$node.GetCommandName() -notmatch '^(?:Dsc\.Security\\)?Initialize-DscOrchestratorRoot$') {
                        return $false
                    }
                    $ancestor = $node.Parent
                    while ($null -ne $ancestor) {
                        if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            return $false
                        }
                        $ancestor = $ancestor.Parent
                    }
                    return $true
                }, $true)
            )
            $sensitiveCommands = @(Get-TopLevelSensitiveCommands -Ast $ast)

            $rootCall | Should -HaveCount 1 -Because $entryPoint
            if ($sensitiveCommands.Count -gt 0) {
                ($rootCall[0].Extent.StartOffset) |
                    Should -BeLessThan $sensitiveCommands[0].Extent.StartOffset -Because $entryPoint
            }
        }
    }

    Context 'filesystem reset behavior' {
        It 'normalizes a trailing separator before checking the parent ACL and creating the root' {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $parent = Join-Path $testDriveRoot 'p'
            $root = Join-Path $parent 'Root'
            $rootWithSeparator = $root + [System.IO.Path]::DirectorySeparatorChar
            $expectedParent = [System.IO.Path]::GetFullPath($parent)
            $expectedRoot = [System.IO.Path]::GetFullPath($root)
            New-Item -ItemType Directory -Path $parent -Force | Out-Null

            InModuleScope Dsc.Security {
                Mock Get-Acl {
                    [System.Security.AccessControl.DirectorySecurity]::new()
                }
                Mock Test-DscOrchestratorParentAcl { $true }
                Mock New-DscOrchestratorRootDirectory {
                    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
                }
            }

            try {
                Initialize-DscOrchestratorRoot -Path $rootWithSeparator

                Should -Invoke -CommandName Get-Acl -ModuleName Dsc.Security -Times 1 -Exactly -ParameterFilter {
                    $LiteralPath -eq $expectedParent
                }
                Should -Invoke -CommandName New-DscOrchestratorRootDirectory `
                    -ModuleName Dsc.Security `
                    -Times 1 `
                    -Exactly `
                    -ParameterFilter { $Path -ceq $expectedRoot }
                Test-Path -LiteralPath $expectedRoot -PathType Container | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $root -PathType Container) {
                    [System.IO.Directory]::Delete($root, $true)
                }
            }
        }

        It 'rejects a drive root as the DscRoot path without requiring elevation' {
            {
                Initialize-DscOrchestratorRoot -Path 'C:\'
            } | Should -Throw -ExpectedMessage 'DscRoot must be a folder, not a drive or share root.'
        }

        It 'creates a new directory with its ACL already applied' {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $path = Join-Path $testDriveRoot 'dsc-security-atomic-create'
            $expectedOwner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

            InModuleScope Dsc.Security {
                Mock New-DscOrchestratorSecureAcl {
                    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
                    $acl.SetAccessRuleProtection($true, $false)
                    $ownerSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                    $acl.SetOwner($ownerSid)
                    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                        $ownerSid,
                        [System.Security.AccessControl.FileSystemRights]::FullControl,
                        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow
                    )
                    $acl.AddAccessRule($rule)
                    return $acl
                }
            }

            try {
                & $script:SecurityModule {
                    param($DirectoryPath)
                    New-DscOrchestratorSecureDirectory -Path $DirectoryPath
                } $path

                $acl = Get-Acl -LiteralPath $path
                $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value |
                    Should -Be $expectedOwner
                $acl.AreAccessRulesProtected | Should -BeTrue
                $rules = @($acl.GetAccessRules(
                    $true,
                    $true,
                    [System.Security.Principal.SecurityIdentifier]
                ))
                $rules | Should -HaveCount 1
                $rules[0].IdentityReference.Value | Should -Be $expectedOwner
            }
            finally {
                if (Test-Path -LiteralPath $path -PathType Container) {
                    [System.IO.Directory]::Delete($path, $true)
                }
            }
        }

        It 'quarantines an untrusted root and creates a secure empty root' -Skip:(-not $script:IsAdmin) {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $rootName = 'dsc-security-untrusted-reset'
            $root = Join-Path $testDriveRoot $rootName
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-UntrustedTestDirectoryAcl -Path $root
            Set-Content -LiteralPath (Join-Path $root 'planted.ps1') -Value 'untrusted' -NoNewline

            InModuleScope Dsc.Security {
                Mock Test-DscOrchestratorParentAcl { $true }
                Mock Remove-DscOrchestratorPathSafely {
                    throw 'Simulated quarantine cleanup failure.'
                }
            }

            $cleanupWarnings = @()
            Initialize-DscOrchestratorRoot -Path $root -WarningVariable cleanupWarnings

            $rootAcl = Get-Acl -LiteralPath $root
            $rootAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value |
                Should -Be 'S-1-5-32-544'
            $rootAcl.AreAccessRulesProtected | Should -BeTrue
            $trusted = & $script:SecurityModule {
                param($Acl)
                Test-DscOrchestratorRootTrusted -Acl $Acl -IsDirectory $true -IsReparsePoint $false
            } $rootAcl
            $trusted | Should -BeTrue
            (@(Get-ChildItem -LiteralPath $root -Force | ForEach-Object { $_.Name }) -join ',') |
                Should -BeExactly 'logs'

            $quarantines = @(
                Get-ChildItem -LiteralPath $testDriveRoot -Force |
                    Where-Object { $_.Name -like "$rootName.untrusted-*" }
            )
            $quarantines | Should -HaveCount 1
            $quarantines[0].Name | Should -Match (
                '^' + [regex]::Escape($rootName) + '\.untrusted-\d{14}-[0-9a-f]{8}$'
            )
            Get-Content -LiteralPath (Join-Path $quarantines[0].FullName 'planted.ps1') -Raw |
                Should -Be 'untrusted'
            ($cleanupWarnings -join '') | Should -Match 'left for an administrator'

            $resetRows = @(Get-Content -LiteralPath (Join-Path $root 'logs\bootstrap.jsonl') |
                ForEach-Object { $_ | ConvertFrom-Json })
            $resetRows | Should -HaveCount 1
            $resetRows[0].message | Should -Be 'DscRoot was untrusted and was reset.'
        }

        It 'removes a junction inside the quarantined tree without touching its target' -Skip:(-not $script:IsAdmin) {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $root = Join-Path $testDriveRoot 'dsc-security-untrusted-root'
            $target = Join-Path $testDriveRoot 'dsc-security-junction-target'
            $junction = Join-Path $root 'staging'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-UntrustedTestDirectoryAcl -Path $root
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'sentinel.txt') -Value 'keep'
            Set-Content -LiteralPath (Join-Path $root 'planted.ps1') -Value 'untrusted'
            New-Item -ItemType Junction -Path $junction -Target $target -ErrorAction Stop | Out-Null

            InModuleScope Dsc.Security {
                Mock Test-DscOrchestratorParentAcl { $true }
            }

            Initialize-DscOrchestratorRoot -Path $root

            Test-Path -LiteralPath (Join-Path $target 'sentinel.txt') | Should -BeTrue
            (@(Get-ChildItem -LiteralPath $root -Force | ForEach-Object { $_.Name }) -join ',') |
                Should -BeExactly 'logs'
            $quarantines = @(
                Get-ChildItem -LiteralPath $testDriveRoot -Force |
                    Where-Object { $_.Name -like 'dsc-security-untrusted-root.untrusted-*' }
            )
            foreach ($quarantine in $quarantines) {
                Test-Path -LiteralPath (Join-Path $quarantine.FullName 'staging') |
                    Should -BeFalse
            }
            $resetRows = @(Get-Content -LiteralPath (Join-Path $root 'logs\bootstrap.jsonl') |
                ForEach-Object { $_ | ConvertFrom-Json })
            $resetRows | Should -HaveCount 1
            $resetRows[0].message | Should -Be 'DscRoot was untrusted and was reset.'
        }

        It 'holds a directory handle without share-delete' {
            $directory = Join-Path $TestDrive 'dsc-security-pinned-directory'
            $renamedDirectory = Join-Path $TestDrive 'dsc-security-pinned-directory-renamed'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            & $script:SecurityModule { Initialize-DscOrchestratorNative }
            $handle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($directory)
            try {
                { Rename-Item -LiteralPath $directory -NewName 'dsc-security-pinned-directory-renamed' -ErrorAction Stop } |
                    Should -Throw
                Test-Path -LiteralPath $directory -PathType Container | Should -BeTrue
                Test-Path -LiteralPath $renamedDirectory | Should -BeFalse
            }
            finally {
                $handle.Dispose()
            }
        }

        It 'fails safely when a new root appears after quarantine' {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $rootName = 'dsc-security-concurrent-root'
            $root = Join-Path $testDriveRoot $rootName
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-UntrustedTestDirectoryAcl -Path $root
            Set-Content -LiteralPath (Join-Path $root 'old.txt') -Value 'quarantined' -NoNewline

            InModuleScope Dsc.Security {
                Mock Test-DscOrchestratorParentAcl { $true }
                Mock New-DscOrchestratorSecureDirectory {
                    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
                    throw [System.ComponentModel.Win32Exception]::new(183, 'The file exists.')
                }
            }

            {
                Initialize-DscOrchestratorRoot -Path $root
            } | Should -Throw -ExpectedMessage '*DscRoot was created concurrently; retry the installation.*'

            Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
            $quarantines = @(
                Get-ChildItem -LiteralPath $testDriveRoot -Force |
                    Where-Object { $_.Name -like "$rootName.untrusted-*" }
            )
            $quarantines | Should -HaveCount 1
            Get-Content -LiteralPath (Join-Path $quarantines[0].FullName 'old.txt') -Raw |
                Should -Be 'quarantined'
        }

        It 'leaves an untrusted root intact when a locked child prevents quarantine' {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $rootName = 'dsc-security-locked-root'
            $root = Join-Path $testDriveRoot $rootName
            $lockedPath = Join-Path $root 'locked.txt'
            $untouchedPath = Join-Path $root 'untouched.txt'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Set-UntrustedTestDirectoryAcl -Path $root
            Set-Content -LiteralPath $lockedPath -Value 'locked-content' -NoNewline
            Set-Content -LiteralPath $untouchedPath -Value 'untouched-content' -NoNewline
            $lockStream = [System.IO.File]::Open(
                $lockedPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )

            try {
                InModuleScope Dsc.Security {
                    Mock Test-DscOrchestratorParentAcl { $true }
                }

                {
                    Initialize-DscOrchestratorRoot -Path $root
                } | Should -Throw -ExpectedMessage '*Failed to quarantine a filesystem object by handle*'

                Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
                Test-Path -LiteralPath $lockedPath -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $untouchedPath -PathType Leaf | Should -BeTrue
                (@(Get-ChildItem -LiteralPath $root -Force | ForEach-Object { $_.Name } | Sort-Object) -join ',') |
                    Should -BeExactly 'locked.txt,untouched.txt'
                Test-Path -LiteralPath (Join-Path $root 'logs') | Should -BeFalse
                @(
                    Get-ChildItem -LiteralPath $testDriveRoot -Force |
                        Where-Object { $_.Name -like "$rootName.untrusted-*" }
                ) | Should -BeNullOrEmpty
            }
            finally {
                $lockStream.Dispose()
            }

            Get-Content -LiteralPath $lockedPath -Raw | Should -BeExactly 'locked-content'
            Get-Content -LiteralPath $untouchedPath -Raw | Should -BeExactly 'untouched-content'
        }

        It 'removes a root junction itself without deleting its target contents' -Skip:(-not $script:IsAdmin) {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $root = Join-Path $testDriveRoot 'dsc-security-root-junction'
            $target = Join-Path $testDriveRoot 'dsc-security-root-target'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'sentinel.txt') -Value 'keep'
            New-Item -ItemType Junction -Path $root -Target $target -ErrorAction Stop | Out-Null

            InModuleScope Dsc.Security {
                Mock Test-DscOrchestratorParentAcl { $true }
            }

            Initialize-DscOrchestratorRoot -Path $root

            (Get-Item -LiteralPath $root -Force).Attributes.HasFlag(
                [System.IO.FileAttributes]::ReparsePoint
            ) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $target 'sentinel.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'logs\bootstrap.jsonl') | Should -BeTrue
        }

        It 'preserves contents in a trusted root and applies the two-ACE protected ACL' -Skip:(-not $script:IsAdmin) {
            $testDriveRoot = (Get-Item -LiteralPath $TestDrive -Force -ErrorAction Stop).FullName
            $root = Join-Path $testDriveRoot 'dsc-security-trusted-root'

            InModuleScope Dsc.Security {
                Mock Test-DscOrchestratorParentAcl { $true }
            }

            Initialize-DscOrchestratorRoot -Path $root
            Set-Content -LiteralPath (Join-Path $root 'preserved.txt') -Value 'keep' -NoNewline
            Initialize-DscOrchestratorRoot -Path $root

            Get-Content -LiteralPath (Join-Path $root 'preserved.txt') -Raw | Should -Be 'keep'
            $acl = Get-Acl -LiteralPath $root
            $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value |
                Should -Be 'S-1-5-32-544'
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = @($acl.GetAccessRules(
                $true,
                $true,
                [System.Security.Principal.SecurityIdentifier]
            ))
            $rules | Should -HaveCount 2
            (@($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) -join ',') |
                Should -Be 'S-1-5-18,S-1-5-32-544'
            foreach ($rule in $rules) {
                $rule.AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow)
                $rule.FileSystemRights | Should -Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
                $rule.InheritanceFlags | Should -Be (
                    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                    [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
                )
                $rule.PropagationFlags | Should -Be ([System.Security.AccessControl.PropagationFlags]::None)
            }
        }
    }

    Context 'post-extraction validation' {
        It 'rejects a reparse point in the extracted install tree without following it' {
            $installRoot = Join-Path $TestDrive 'dsc-security-extracted-install'
            $target = Join-Path $TestDrive 'dsc-security-extracted-target'
            New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'sentinel.txt') -Value 'keep'
            New-Item -ItemType Junction `
                -Path (Join-Path $installRoot 'linked') `
                -Target $target `
                -ErrorAction Stop | Out-Null
            & $script:SecurityModule { Initialize-DscOrchestratorNative }

            $installerPath = Join-Path $script:WindowsAgentRoot 'Install-VmApplicationPackage.ps1'
            $tokens = $null
            $parseErrors = $null
            $installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $installerPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty
            $validationFunction = Get-FunctionAst `
                -Ast $installerAst `
                -Name 'Test-DscOrchestratorExtractedInstallTree'
            $validationFunction | Should -Not -BeNullOrEmpty
            $runner = [scriptblock]::Create(@(
                    'param([string]$InstallRoot)'
                    $validationFunction.Extent.Text
                    'Test-DscOrchestratorExtractedInstallTree -Path $InstallRoot'
                ) -join [System.Environment]::NewLine)

            { & $runner $installRoot } |
                Should -Throw -ExpectedMessage '*contains a reparse point*'
            Test-Path -LiteralPath (Join-Path $target 'sentinel.txt') | Should -BeTrue
        }
    }
}
