Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-DscOrchestratorRootTrusted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.AccessControl.DirectorySecurity]$Acl,

        [Parameter(Mandatory = $true)]
        [bool]$IsDirectory,

        [Parameter(Mandatory = $true)]
        [bool]$IsReparsePoint
    )

    if (-not $IsDirectory -or $IsReparsePoint -or -not $Acl.AreAccessRulesProtected) {
        return $false
    }

    $systemSid = 'S-1-5-18'
    $administratorsSid = 'S-1-5-32-544'
    $trustedSids = @($systemSid, $administratorsSid)
    $rootWriteRights = [int](
        [System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    ) -bor 0x40000000 -bor 0x10000000
    $ownerSid = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($trustedSids -notcontains $ownerSid) {
        return $false
    }

    foreach ($rule in $Acl.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        $rights = [int]$rule.FileSystemRights
        if (($rights -band $rootWriteRights) -ne 0 -and
            $trustedSids -notcontains $rule.IdentityReference.Value) {
            return $false
        }
    }

    return $true
}

function Test-DscOrchestratorParentAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.AccessControl.DirectorySecurity]$Acl
    )

    $systemSid = 'S-1-5-18'
    $administratorsSid = 'S-1-5-32-544'
    $trustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $trustedSids = @($systemSid, $administratorsSid, $trustedInstallerSid)
    $parentDeleteRights = [int](
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    ) -bor 0x10000000

    foreach ($rule in $Acl.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne
            [System.Security.AccessControl.PropagationFlags]::None) {
            continue
        }
        if ($trustedSids -contains $rule.IdentityReference.Value) {
            continue
        }

        $rights = [int]$rule.FileSystemRights
        if (($rights -band $parentDeleteRights) -ne 0) {
            return $false
        }
    }

    return $true
}

function Get-DscOrchestratorPathItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
    catch [System.IO.FileNotFoundException] {
        return $null
    }
    catch [System.IO.DirectoryNotFoundException] {
        return $null
    }
}

function New-DscOrchestratorSecureAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Creates an in-memory ACL descriptor; filesystem changes occur in the secure-directory helpers.'
    )]
    [CmdletBinding()]
    param()

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)

    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $systemSid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $administratorsRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $administratorsSid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    $acl.SetOwner($administratorsSid)
    $acl.AddAccessRule($systemRule)
    $acl.AddAccessRule($administratorsRule)
    return $acl
}

function New-DscOrchestratorSecureDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'A secure root must be created atomically with its protected ACL.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not ('DscOrchestrator.NativeDirectoryAcl' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DscOrchestrator
{
    public static class NativeDirectoryAcl
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateDirectoryW")]
        private static extern bool CreateDirectoryNative(string path, ref SecurityAttributes attributes);

        public static void CreateSecureDirectory(string path, byte[] securityDescriptor)
        {
            IntPtr descriptorPointer = IntPtr.Zero;
            try
            {
                descriptorPointer = Marshal.AllocHGlobal(securityDescriptor.Length);
                Marshal.Copy(securityDescriptor, 0, descriptorPointer, securityDescriptor.Length);
                var attributes = new SecurityAttributes
                {
                    Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                    SecurityDescriptor = descriptorPointer,
                    InheritHandle = false
                };
                if (!CreateDirectoryNative(path, ref attributes))
                {
                    int errorCode = Marshal.GetLastWin32Error();
                    throw new Win32Exception(errorCode, "Failed to atomically create secure directory '" + path + "'.");
                }
            }
            finally
            {
                if (descriptorPointer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(descriptorPointer);
                }
            }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop | Out-Null
    }

    $acl = New-DscOrchestratorSecureAcl
    [DscOrchestrator.NativeDirectoryAcl]::CreateSecureDirectory(
        $Path,
        $acl.GetSecurityDescriptorBinaryForm()
    )
}

function Set-DscOrchestratorSecureAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'The security boundary must not expose a WhatIf bypass.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $secureAcl = New-DscOrchestratorSecureAcl
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in $acl.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier])) {
        $acl.RemoveAccessRuleSpecific($rule)
    }

    $acl.SetOwner($secureAcl.GetOwner([System.Security.Principal.SecurityIdentifier]))
    foreach ($rule in $secureAcl.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier])) {
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop | Out-Null
}

function Remove-DscOrchestratorPathSafely {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'The security boundary must not expose a WhatIf bypass.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $item = Get-DscOrchestratorPathItem -Path $Path
    if ($null -eq $item) {
        return
    }

    $attributes = [System.IO.FileAttributes]$item.Attributes
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            [System.IO.Directory]::Delete($Path)
        }
        else {
            [System.IO.File]::Delete($Path)
        }
        return
    }

    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        foreach ($childPath in [System.IO.Directory]::GetFileSystemEntries($Path)) {
            Remove-DscOrchestratorPathSafely -Path $childPath
        }
        [System.IO.Directory]::Delete($Path, $false)
    }
    else {
        [System.IO.File]::Delete($Path)
    }
}

function Initialize-DscOrchestratorSubdirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('logs', 'install', 'staging', 'current')]
        [string]$Name
    )

    $directoryPath = Join-Path ([System.IO.Path]::GetFullPath($RootPath)) $Name
    $item = Get-DscOrchestratorPathItem -Path $directoryPath
    if ($null -ne $item -and
        (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($item.Attributes -band [System.IO.FileAttributes]::Directory) -eq 0)) {
        Remove-DscOrchestratorPathSafely -Path $directoryPath
        $item = $null
    }

    if ($null -eq $item) {
        New-Item -ItemType Directory -Path $directoryPath -ErrorAction Stop | Out-Null
    }

    Set-DscOrchestratorSecureAcl -Path $directoryPath
    return $directoryPath
}

function Write-DscOrchestratorRootResetEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $record = [ordered]@{
        TimeGenerated  = (Get-Date).ToUniversalTime().ToString('o')
        Computer       = $env:COMPUTERNAME
        config_version = ''
        stage          = 'preflight'
        status         = 'ok'
        message        = 'DscRoot was untrusted and was reset.'
        pwsh_source    = ''
        pwsh_path      = ''
        pwsh_version   = ''
        error_type     = ''
        error_message  = ''
    } | ConvertTo-Json -Compress -Depth 5

    [System.IO.File]::AppendAllText(
        $Path,
        $record + [System.Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Initialize-DscOrchestratorRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $rootPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Directory]::GetParent($rootPath)
    if ($null -eq $parentPath) {
        throw "DscRoot '$rootPath' must have an existing parent directory."
    }

    $parentItem = Get-DscOrchestratorPathItem -Path $parentPath.FullName
    if ($null -eq $parentItem -or
        ($parentItem.Attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
        throw "DscRoot parent '$($parentPath.FullName)' does not exist as a directory."
    }

    $parentAcl = Get-Acl -LiteralPath $parentPath.FullName -ErrorAction Stop
    if (-not (Test-DscOrchestratorParentAcl -Acl $parentAcl)) {
        throw "DscRoot parent '$($parentPath.FullName)' grants delete or security-changing rights to a non-trusted SID. Use a parent where only SYSTEM, Administrators, or TrustedInstaller can delete or rename entries."
    }

    $rootItem = Get-DscOrchestratorPathItem -Path $rootPath
    $rootWasReset = $false
    if ($null -eq $rootItem) {
        New-DscOrchestratorSecureDirectory -Path $rootPath
        Set-DscOrchestratorSecureAcl -Path $rootPath
    }
    elseif (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-DscOrchestratorPathSafely -Path $rootPath
        New-DscOrchestratorSecureDirectory -Path $rootPath
        Set-DscOrchestratorSecureAcl -Path $rootPath
        $rootWasReset = $true
    }
    elseif (($rootItem.Attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
        Remove-DscOrchestratorPathSafely -Path $rootPath
        New-DscOrchestratorSecureDirectory -Path $rootPath
        Set-DscOrchestratorSecureAcl -Path $rootPath
        $rootWasReset = $true
    }
    else {
        $rootAcl = Get-Acl -LiteralPath $rootPath -ErrorAction Stop
        $isTrusted = Test-DscOrchestratorRootTrusted `
            -Acl $rootAcl `
            -IsDirectory $true `
            -IsReparsePoint $false
        if ($isTrusted) {
            Set-DscOrchestratorSecureAcl -Path $rootPath
        }
        else {
            Set-DscOrchestratorSecureAcl -Path $rootPath
            foreach ($childPath in [System.IO.Directory]::GetFileSystemEntries($rootPath)) {
                Remove-DscOrchestratorPathSafely -Path $childPath
            }
            $rootWasReset = $true
        }
    }

    if ($rootWasReset) {
        $logsPath = Initialize-DscOrchestratorSubdirectory -RootPath $rootPath -Name 'logs'
        Write-DscOrchestratorRootResetEvent -Path (Join-Path $logsPath 'bootstrap.jsonl')
    }
}

Export-ModuleMember -Function Initialize-DscOrchestratorRoot, Initialize-DscOrchestratorSubdirectory, Remove-DscOrchestratorPathSafely
