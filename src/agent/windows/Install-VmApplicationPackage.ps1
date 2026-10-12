# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$PackageArchivePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'DscOrchestrator-Enforcement',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AllUsersModulesPath = 'C:\Program Files\WindowsPowerShell\Modules',

    [Parameter()]
    [switch]$Update,

    [Parameter()]
    [switch]$AuditOnly
)

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

function Initialize-DscOrchestratorNative {
    [CmdletBinding()]
    param()

    if (-not ('DscOrchestrator.NativeFileSystem' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DscOrchestrator
{
    public static class NativeFileSystem
    {
        private const uint ReadControl = 0x00020000;
        private const uint WriteDac = 0x00040000;
        private const uint WriteOwner = 0x00080000;
        private const uint Delete = 0x00010000;
        private const uint FileReadAttributes = 0x00000080;
        private const uint FileListDirectory = 0x00000001;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint TokenAdjustPrivileges = 0x00000020;
        private const uint TokenQuery = 0x00000008;
        private const uint SePrivilegeEnabled = 0x00000002;
        private const int ErrorNotAllAssigned = 1300;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public NativeFileTime CreationTime;
            public NativeFileTime LastAccessTime;
            public NativeFileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Luid
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenPrivileges
        {
            public uint PrivilegeCount;
            public Luid Luid;
            public uint Attributes;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateDirectoryW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryNative(string path, ref SecurityAttributes attributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFileNative(
            string path,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle file,
            int fileInformationClass,
            IntPtr information,
            uint bufferSize);

        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityInfo(
            SafeFileHandle handle,
            int objectType,
            uint securityInformation,
            IntPtr owner,
            IntPtr group,
            IntPtr dacl,
            IntPtr sacl,
            out IntPtr securityDescriptor);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern uint GetSecurityDescriptorLength(IntPtr securityDescriptor);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorOwner(
            IntPtr securityDescriptor,
            out IntPtr owner,
            [MarshalAs(UnmanagedType.Bool)] out bool ownerDefaulted);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSecurityDescriptorDacl(
            IntPtr securityDescriptor,
            [MarshalAs(UnmanagedType.Bool)] out bool daclPresent,
            out IntPtr dacl,
            [MarshalAs(UnmanagedType.Bool)] out bool daclDefaulted);

        [DllImport("advapi32.dll")]
        private static extern uint SetSecurityInfo(
            SafeFileHandle handle,
            int objectType,
            uint securityInformation,
            IntPtr owner,
            IntPtr group,
            IntPtr dacl,
            IntPtr sacl);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(
            IntPtr process,
            uint desiredAccess,
            out IntPtr token);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "LookupPrivilegeValueW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LookupPrivilegeValueNative(
            string systemName,
            string name,
            out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AdjustTokenPrivileges(
            IntPtr token,
            [MarshalAs(UnmanagedType.Bool)] bool disableAllPrivileges,
            ref TokenPrivileges newState,
            uint bufferLength,
            IntPtr previousState,
            IntPtr returnLength);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

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

        public static SafeFileHandle OpenNoFollow(string path)
        {
            var handle = CreateFileNative(
                path,
                ReadControl | WriteDac | WriteOwner | Delete | FileReadAttributes | FileListDirectory,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int errorCode = Marshal.GetLastWin32Error();
                if (handle != null)
                {
                    handle.Dispose();
                }
                if (errorCode == 2 || errorCode == 3)
                {
                    return null;
                }
                throw new Win32Exception(errorCode, "Failed to open filesystem path without following reparse points '" + path + "'.");
            }
            return handle;
        }

        public static FileAttributes GetAttributes(SafeFileHandle handle)
        {
            ValidateHandle(handle);
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                int errorCode = Marshal.GetLastWin32Error();
                throw new Win32Exception(errorCode, "Failed to read attributes from a pinned filesystem handle.");
            }
            return (FileAttributes)information.FileAttributes;
        }

        public static byte[] GetOwnerAndDacl(SafeFileHandle handle)
        {
            ValidateHandle(handle);
            IntPtr descriptor = IntPtr.Zero;
            uint errorCode = GetSecurityInfo(handle, 1, 0x00000001 | 0x00000004,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out descriptor);
            if (errorCode != 0)
            {
                throw new Win32Exception((int)errorCode, "Failed to read owner and DACL from a pinned filesystem handle.");
            }
            try
            {
                uint descriptorLength = GetSecurityDescriptorLength(descriptor);
                if (descriptorLength == 0 || descriptorLength > int.MaxValue)
                {
                    throw new InvalidOperationException("The pinned filesystem handle returned an invalid security descriptor.");
                }
                var result = new byte[(int)descriptorLength];
                Marshal.Copy(descriptor, result, 0, result.Length);
                return result;
            }
            finally
            {
                if (descriptor != IntPtr.Zero)
                {
                    LocalFree(descriptor);
                }
            }
        }

        public static void SetSecurity(SafeFileHandle handle, byte[] securityDescriptor)
        {
            ValidateHandle(handle);
            if (securityDescriptor == null || securityDescriptor.Length == 0)
            {
                throw new ArgumentException("A security descriptor is required.", "securityDescriptor");
            }
            IntPtr descriptor = IntPtr.Zero;
            try
            {
                descriptor = Marshal.AllocHGlobal(securityDescriptor.Length);
                Marshal.Copy(securityDescriptor, 0, descriptor, securityDescriptor.Length);
                IntPtr owner;
                bool ownerDefaulted;
                if (!GetSecurityDescriptorOwner(descriptor, out owner, out ownerDefaulted))
                {
                    int errorCode = Marshal.GetLastWin32Error();
                    throw new Win32Exception(errorCode, "Failed to read the owner from the secure directory descriptor.");
                }
                bool daclPresent;
                IntPtr dacl;
                bool daclDefaulted;
                if (!GetSecurityDescriptorDacl(descriptor, out daclPresent, out dacl, out daclDefaulted))
                {
                    int errorCode = Marshal.GetLastWin32Error();
                    throw new Win32Exception(errorCode, "Failed to read the DACL from the secure directory descriptor.");
                }
                if (owner == IntPtr.Zero || !daclPresent || dacl == IntPtr.Zero)
                {
                    throw new ArgumentException("The security descriptor must contain an owner and DACL.", "securityDescriptor");
                }
                uint securityInformation = 0x00000001 | 0x00000004 | 0x80000000;
                uint statusCode = SetSecurityInfo(handle, 1, securityInformation,
                    owner, IntPtr.Zero, dacl, IntPtr.Zero);
                if (statusCode != 0)
                {
                    throw new Win32Exception((int)statusCode, "Failed to apply the secure owner and protected DACL to a pinned filesystem handle.");
                }
            }
            finally
            {
                if (descriptor != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(descriptor);
                }
            }
        }

        public static void RenameByHandle(SafeFileHandle handle, string newFullPath)
        {
            ValidateHandle(handle);
            if (String.IsNullOrEmpty(newFullPath))
            {
                throw new ArgumentException("A destination path is required.", "newFullPath");
            }
            string requestedPath = newFullPath;
            string normalizedPath = Path.GetFullPath(newFullPath);
            if (!normalizedPath.StartsWith(@"\??\", StringComparison.Ordinal) &&
                !normalizedPath.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                if (normalizedPath.StartsWith(@"\\", StringComparison.Ordinal))
                {
                    normalizedPath = @"\??\UNC\" + normalizedPath.Substring(2);
                }
                else
                {
                    normalizedPath = @"\??\" + normalizedPath;
                }
            }
            byte[] fileName = Encoding.Unicode.GetBytes(normalizedPath);
            int rootDirectoryOffset = IntPtr.Size == 8 ? 8 : 4;
            int fileNameLengthOffset = rootDirectoryOffset + IntPtr.Size;
            int fileNameOffset = fileNameLengthOffset + 4;
            var renameInformation = new byte[fileNameOffset + fileName.Length + 4];
            renameInformation[0] = 0;
            Buffer.BlockCopy(BitConverter.GetBytes((uint)fileName.Length), 0,
                renameInformation, fileNameLengthOffset, 4);
            Buffer.BlockCopy(fileName, 0, renameInformation, fileNameOffset, fileName.Length);
            IntPtr information = IntPtr.Zero;
            try
            {
                information = Marshal.AllocHGlobal(renameInformation.Length);
                Marshal.Copy(renameInformation, 0, information, renameInformation.Length);
                if (!SetFileInformationByHandle(handle, 3, information, (uint)renameInformation.Length))
                {
                    int errorCode = Marshal.GetLastWin32Error();
                    throw new Win32Exception(errorCode, "Failed to quarantine a filesystem object by handle as '" + requestedPath + "' (native path '" + normalizedPath + "', Windows error " + errorCode + ").");
                }
            }
            finally
            {
                if (information != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(information);
                }
            }
        }

        public static void DeleteByHandle(SafeFileHandle handle)
        {
            ValidateHandle(handle);
            IntPtr information = IntPtr.Zero;
            try
            {
                information = Marshal.AllocHGlobal(1);
                Marshal.WriteByte(information, 0, 1);
                if (!SetFileInformationByHandle(handle, 4, information, 1))
                {
                    int errorCode = Marshal.GetLastWin32Error();
                    throw new Win32Exception(errorCode, "Failed to delete a filesystem object by pinned handle.");
                }
            }
            finally
            {
                if (information != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(information);
                }
            }
        }

        public static bool EnablePrivilege(string name)
        {
            IntPtr token = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(),
                        TokenAdjustPrivileges | TokenQuery, out token))
                {
                    return false;
                }
                Luid luid;
                if (!LookupPrivilegeValueNative(null, name, out luid))
                {
                    return false;
                }
                var privileges = new TokenPrivileges
                {
                    PrivilegeCount = 1,
                    Luid = luid,
                    Attributes = SePrivilegeEnabled
                };
                if (!AdjustTokenPrivileges(token, false, ref privileges, 0,
                        IntPtr.Zero, IntPtr.Zero))
                {
                    return false;
                }
                return Marshal.GetLastWin32Error() != ErrorNotAllAssigned;
            }
            finally
            {
                if (token != IntPtr.Zero)
                {
                    CloseHandle(token);
                }
            }
        }

        private static void ValidateHandle(SafeFileHandle handle)
        {
            if (handle == null || handle.IsInvalid || handle.IsClosed)
            {
                throw new ArgumentException("A valid pinned filesystem handle is required.", "handle");
            }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop | Out-Null
    }
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

    Initialize-DscOrchestratorNative
    $acl = New-DscOrchestratorSecureAcl
    [DscOrchestrator.NativeFileSystem]::CreateSecureDirectory(
        $Path,
        $acl.GetSecurityDescriptorBinaryForm()
    )
}

function New-DscOrchestratorRootDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'A DscRoot must be created atomically with its secure descriptor.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        New-DscOrchestratorSecureDirectory -Path $Path
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.ComponentModel.Win32Exception] -and
                $exception.NativeErrorCode -in @(80, 183)) {
                throw 'DscRoot was created concurrently; retry the installation.'
            }
            $exception = $exception.InnerException
        }
        throw
    }
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

    Initialize-DscOrchestratorNative
    $handle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($Path)
    if ($null -eq $handle) {
        throw "Directory '$Path' disappeared before its security could be applied."
    }

    try {
        $attributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($handle)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
            throw "Path '$Path' is not a non-reparse directory."
        }
        $secureAcl = New-DscOrchestratorSecureAcl
        [DscOrchestrator.NativeFileSystem]::SetSecurity(
            $handle,
            $secureAcl.GetSecurityDescriptorBinaryForm()
        )
    }
    finally {
        $handle.Dispose()
    }
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

    Initialize-DscOrchestratorNative
    $handle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($Path)
    if ($null -eq $handle) {
        return
    }

    try {
        $attributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($handle)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
            [DscOrchestrator.NativeFileSystem]::DeleteByHandle($handle)
            return
        }

        $secureAcl = New-DscOrchestratorSecureAcl
        [DscOrchestrator.NativeFileSystem]::SetSecurity(
            $handle,
            $secureAcl.GetSecurityDescriptorBinaryForm()
        )
        foreach ($childPath in [System.IO.Directory]::GetFileSystemEntries($Path)) {
            Remove-DscOrchestratorPathSafely -Path $childPath
        }
        [DscOrchestrator.NativeFileSystem]::DeleteByHandle($handle)
    }
    finally {
        $handle.Dispose()
    }
}

function Initialize-DscOrchestratorSubdirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,

        [Parameter(Mandatory = $true)]
        [ValidateSet('logs', 'install', 'staging', 'current', 'current.previous')]
        [string]$Name
    )

    Initialize-DscOrchestratorNative
    $directoryPath = Join-Path ([System.IO.Path]::GetFullPath($RootPath)) $Name
    $handle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($directoryPath)
    if ($null -eq $handle) {
        New-Item -ItemType Directory -Path $directoryPath -ErrorAction Stop | Out-Null
        $handle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($directoryPath)
        if ($null -eq $handle) {
            throw "Directory '$directoryPath' disappeared during initialization."
        }
    }

    try {
        $attributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($handle)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
            [DscOrchestrator.NativeFileSystem]::DeleteByHandle($handle)
            $handle.Dispose()
            $handle = $null
            New-Item -ItemType Directory -Path $directoryPath -ErrorAction Stop | Out-Null
            $handle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($directoryPath)
            if ($null -eq $handle) {
                throw "Directory '$directoryPath' disappeared during initialization."
            }
            $attributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($handle)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
                throw "Path '$directoryPath' is not a non-reparse directory."
            }
        }

        $secureAcl = New-DscOrchestratorSecureAcl
        [DscOrchestrator.NativeFileSystem]::SetSecurity(
            $handle,
            $secureAcl.GetSecurityDescriptorBinaryForm()
        )
    }
    finally {
        if ($null -ne $handle) {
            $handle.Dispose()
        }
    }
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

    $rootPath = ([System.IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@('\', '/'))
    $pathRoot = [System.IO.Path]::GetPathRoot($rootPath)
    $isDriveRoot = $rootPath -match '^[A-Za-z]:$'
    $isUncShareRoot = $rootPath.StartsWith('\\', [System.StringComparison]::Ordinal) -and
        -not [string]::IsNullOrEmpty($pathRoot) -and
        [string]::Equals(
            $rootPath,
            $pathRoot.TrimEnd([char[]]@('\', '/')),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    if ($isDriveRoot -or $isUncShareRoot) {
        throw 'DscRoot must be a folder, not a drive or share root.'
    }

    Initialize-DscOrchestratorNative
    [void][DscOrchestrator.NativeFileSystem]::EnablePrivilege('SeTakeOwnershipPrivilege')
    [void][DscOrchestrator.NativeFileSystem]::EnablePrivilege('SeRestorePrivilege')
    [void][DscOrchestrator.NativeFileSystem]::EnablePrivilege('SeBackupPrivilege')

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

    $rootWasReset = $false
    $quarantinedRootPath = $null
    $rootHandle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($rootPath)
    if ($null -eq $rootHandle) {
        New-DscOrchestratorRootDirectory -Path $rootPath
    }
    else {
        try {
            $attributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($rootHandle)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
                [DscOrchestrator.NativeFileSystem]::DeleteByHandle($rootHandle)
                $rootWasReset = $true
            }
            else {
                $rootSecurityDescriptor = [DscOrchestrator.NativeFileSystem]::GetOwnerAndDacl($rootHandle)
                $rootAcl = [System.Security.AccessControl.DirectorySecurity]::new()
                $rootAcl.SetSecurityDescriptorBinaryForm($rootSecurityDescriptor)
                $isTrusted = Test-DscOrchestratorRootTrusted `
                    -Acl $rootAcl `
                    -IsDirectory $true `
                    -IsReparsePoint $false
                if ($isTrusted) {
                    $secureAcl = New-DscOrchestratorSecureAcl
                    [DscOrchestrator.NativeFileSystem]::SetSecurity(
                        $rootHandle,
                        $secureAcl.GetSecurityDescriptorBinaryForm()
                    )
                }
                else {
                    $rootName = [System.IO.Path]::GetFileName(
                        $rootPath.TrimEnd([char[]]@('\', '/'))
                    )
                    $timestamp = (Get-Date).ToString(
                        'yyyyMMddHHmmss',
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                    $identifier = [guid]::NewGuid().ToString('N').Substring(0, 8)
                    $quarantinedRootPath = Join-Path $parentPath.FullName (
                        "$rootName.untrusted-$timestamp-$identifier"
                    )
                    [DscOrchestrator.NativeFileSystem]::RenameByHandle(
                        $rootHandle,
                        $quarantinedRootPath
                    )
                    $rootWasReset = $true
                }
            }
        }
        finally {
            $rootHandle.Dispose()
        }

        if ($rootWasReset) {
            New-DscOrchestratorRootDirectory -Path $rootPath
            if ($null -ne $quarantinedRootPath) {
                try {
                    Remove-DscOrchestratorPathSafely -Path $quarantinedRootPath
                }
                catch {
                    Write-Warning -Message (
                        "Failed to clean quarantined DscRoot '$quarantinedRootPath': " +
                        "$($_.Exception.Message) The quarantine folder was left for an administrator to remove."
                    ) -WarningAction Continue
                }
            }
        }
    }

    if ($rootWasReset) {
        $logsPath = Initialize-DscOrchestratorSubdirectory -RootPath $rootPath -Name 'logs'
        Write-DscOrchestratorRootResetEvent -Path (Join-Path $logsPath 'bootstrap.jsonl')
    }
}

function Test-DscOrchestratorExtractedInstallTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $installRoot = [System.IO.Path]::GetFullPath($Path)
    $installRootPrefix = $installRoot.TrimEnd([char[]]@('\', '/')) +
        [System.IO.Path]::DirectorySeparatorChar
    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($installRoot)

    while ($pendingDirectories.Count -gt 0) {
        $directoryPath = $pendingDirectories.Pop()
        $directoryHandle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($directoryPath)
        if ($null -eq $directoryHandle) {
            throw "Extracted install directory '$directoryPath' disappeared during validation."
        }

        try {
            $directoryAttributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($directoryHandle)
            if (($directoryAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Extracted install tree contains a reparse point: $directoryPath"
            }
            if (($directoryAttributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
                throw "Extracted install tree contains a non-directory in its directory walk: $directoryPath"
            }

            foreach ($entryPath in [System.IO.Directory]::GetFileSystemEntries($directoryPath)) {
                $resolvedFullPath = [System.IO.Path]::GetFullPath($entryPath)
                if (-not $resolvedFullPath.StartsWith(
                        $installRootPrefix,
                        [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Extracted install path '$resolvedFullPath' is outside '$installRoot'."
                }

                $entryHandle = [DscOrchestrator.NativeFileSystem]::OpenNoFollow($resolvedFullPath)
                if ($null -eq $entryHandle) {
                    throw "Extracted install entry '$resolvedFullPath' disappeared during validation."
                }
                try {
                    $entryAttributes = [DscOrchestrator.NativeFileSystem]::GetAttributes($entryHandle)
                    if (($entryAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Extracted install tree contains a reparse point: $resolvedFullPath"
                    }
                    if (($entryAttributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                        $pendingDirectories.Push($resolvedFullPath)
                    }
                }
                finally {
                    $entryHandle.Dispose()
                }
            }
        }
        finally {
            $directoryHandle.Dispose()
        }
    }
}

$PackageArchivePath = [System.IO.Path]::GetFullPath($PackageArchivePath)
$DscRoot = [System.IO.Path]::GetFullPath($DscRoot)
Initialize-DscOrchestratorRoot -Path $DscRoot
$logsRoot = Initialize-DscOrchestratorSubdirectory -RootPath $DscRoot -Name 'logs'
$installRoot = Join-Path $DscRoot 'install'
$bootstrapLog = Join-Path $logsRoot 'bootstrap.jsonl'
$bootstrapStarted = $false

Remove-DscOrchestratorPathSafely -Path $installRoot
$installRoot = Initialize-DscOrchestratorSubdirectory -RootPath $DscRoot -Name 'install'

$logWriterPath = Join-Path $installRoot 'Write-BootstrapJsonLine.ps1'
try {
    & tar.exe -x -f $PackageArchivePath -C $installRoot
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe extraction failed (exit $LASTEXITCODE)."
    }
    Test-DscOrchestratorExtractedInstallTree -Path $installRoot

    $manifestPath = Join-Path $installRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package archive '$PackageArchivePath' does not contain manifest.json."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.version -ne $Version) {
        throw "Package version '$($manifest.version)' does not match requested version '$Version'."
    }

    if (-not (Test-Path -LiteralPath $logWriterPath -PathType Leaf)) {
        throw "Package archive is missing '$logWriterPath'."
    }
    . $logWriterPath
    Write-BootstrapJsonLine -Path $bootstrapLog -Stage 'extract' -Status 'ok' `
        -Message "Extracted package to $installRoot" -ConfigVersion $Version

    $bootstrapPath = Join-Path $installRoot 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
        throw "Package archive is missing bootstrap.ps1 at '$bootstrapPath'."
    }

    $bootstrapStarted = $true
    & $bootstrapPath `
        -Version $Version `
        -PackageRoot $installRoot `
        -DscRoot $DscRoot `
        -TaskName $TaskName `
        -RegistryRoot $RegistryRoot `
        -AllUsersModulesPath $AllUsersModulesPath `
        -Update:$Update `
        -AuditOnly:$AuditOnly

    Remove-DscOrchestratorPathSafely -Path $installRoot
}
catch {
    $failure = $_
    if ($bootstrapStarted) {
        throw
    }
    if (Test-Path -LiteralPath $logWriterPath -PathType Leaf) {
        . $logWriterPath
        Write-BootstrapJsonLine -Path $bootstrapLog -Stage 'fatal' -Status 'error' `
            -Message "VM Application package installation failed for version $Version" `
            -ConfigVersion $Version `
            -ErrorType $failure.Exception.GetType().Name `
            -ErrorMessage $failure.Exception.Message
    }
    else {
        $record = [ordered]@{
            TimeGenerated  = (Get-Date).ToUniversalTime().ToString('o')
            Computer       = $env:COMPUTERNAME
            config_version = $Version
            stage          = 'extract'
            status         = 'error'
            message        = 'VM Application package extraction failed'
            error_type     = $failure.Exception.GetType().Name
            error_message  = $failure.Exception.Message
        } | ConvertTo-Json -Compress -Depth 5
        [System.IO.File]::AppendAllText(
            $bootstrapLog,
            $record + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    throw
}
