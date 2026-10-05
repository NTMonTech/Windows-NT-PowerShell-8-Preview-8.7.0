# NT PowerShell 8 Preview 0.6 - Directory Unlocker.
# Changes ONLY Windows Zone.Identifier (download Mark-of-the-Web) and, if explicitly
# requested, the ReadOnly FILE attribute. Never changes ACLs, owners, AV or SmartScreen.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NTUnlockTarget {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { throw 'nt-unlock requires Windows PowerShell 7+ and an NTFS-compatible location.' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Path does not exist: $Path" }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $full = [IO.Path]::GetFullPath($resolved).TrimEnd('\','/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\','/')
    $blocked = @($root, $env:WINDIR, "$($env:WINDIR)\System32", "$($env:WINDIR)\WinSxS",
        $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA,
        $env:ProgramFiles, ${env:ProgramFiles(x86)},
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))
    foreach ($restricted in $blocked) {
        if ($restricted -and $full.Equals($restricted.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing broad/system root: $full. Select an individual downloaded application folder instead."
        }
    }
    $systemRoot = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($systemRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing files under the Windows system directory.'
    }
    if ($full -match '(?i)[\\/]WindowsApps([\\/]|$)') {
        throw 'Refusing WindowsApps managed packages.'
    }
    # Ancestor junctions/symlinks can redirect a harmless-looking path outside the chosen tree.
    $walk = $full
    while ($walk) {
        if (Test-Path -LiteralPath $walk) {
            $node = Get-Item -LiteralPath $walk -Force -ErrorAction Stop
            if (($node.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point/symlink not supported: $walk"
            }
        }
        $parent = [IO.Directory]::GetParent($walk)
        if ($null -eq $parent -or $parent.FullName -eq $walk) { break }
        $walk = $parent.FullName
    }
    return $full
}

function Get-NTUnlockInventory {
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,100000)][int]$MaxFiles)
    $target = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $files = [Collections.Generic.List[object]]::new()
    if ($target.PSIsContainer) {
        foreach ($entry in (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A symlink or junction was found. No files changed: $($entry.FullName)"
            }
            if (-not $entry.PSIsContainer) {
                $files.Add($entry)
                if ($files.Count -gt $MaxFiles) {
                    throw "Directory contains over $MaxFiles files; narrow the target or explicitly raise -MaxFiles."
                }
            }
        }
    }
    else { $files.Add($target) }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        # This is the same ADS that Windows Explorer's file Properties / Unblock uses.
        $zone = @(Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
        $readonly = (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
        $result.Add([pscustomobject]@{
            File = $file.FullName
            Blocked = ($zone.Count -gt 0)
            ReadOnly = $readonly
        })
    }
    return $result.ToArray()
}

function Get-NTUnlockLogRoot {
    param([string]$LogRoot)
    if ($LogRoot) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogRoot) }
    if (Test-Path -LiteralPath 'C:\' -PathType Container) { return 'C:\PowerShell_8_Files\NTPS8_UnlockLogs' }
    return (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'NTPS8_UnlockLogs')
}

function nt-unlock {
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory,Position=0)][ValidateNotNullOrEmpty()][string]$Path,
        [switch]$Check,
        [switch]$Apply,
        [switch]$ClearReadOnly,
        [string]$LogRoot,
        [ValidateRange(1,100000)][int]$MaxFiles = 50000
    )
    if ($Check -and $Apply) { throw 'Use -Check OR -Apply, not both.' }
    if ($ClearReadOnly -and -not $Apply) {
        Write-Host '[NT UNLOCK] ReadOnly would be cleared only with -ClearReadOnly -Apply.' -ForegroundColor Yellow
    }
    $full = Assert-NTUnlockTarget -Path $Path
    $entries = @(Get-NTUnlockInventory -Path $full -MaxFiles $MaxFiles)
    $blocked = @($entries | Where-Object Blocked)
    $readOnlyCount = @($entries | Where-Object ReadOnly).Count
    Write-Host ('[NT UNLOCK] Target: ' + $full) -ForegroundColor Cyan
    Write-Host ('[NT UNLOCK] Total files: {0}; with Zone.Identifier: {1}; ReadOnly: {2}' -f
        $entries.Count, $blocked.Count, $readOnlyCount)
    foreach ($item in $blocked) { Write-Host ('  [BLOCKED] ' + $item.File) }
    if ($ClearReadOnly) {
        foreach ($item in ($entries | Where-Object ReadOnly)) { Write-Host ('  [READONLY] ' + $item.File) }
    }
    if (-not $Apply -or $Check) {
        Write-Host '[PREVIEW] No files changed. Verify the source first, then rerun with -Apply.' -ForegroundColor Yellow
        return
    }
    if ($blocked.Count -eq 0 -and ((-not $ClearReadOnly) -or $readOnlyCount -eq 0)) {
        Write-Host '[NT UNLOCK] No relevant properties need changing.' -ForegroundColor Green
        return
    }
    Write-Host '[WARNING] Removing Mark-of-the-Web may allow untrusted downloaded files to execute.' -ForegroundColor Yellow
    $answer = Read-Host 'If you trust EVERY file in this folder, type UNBLOCK'
    if ($answer -cne 'UNBLOCK') { Write-Host '[NT UNLOCK] Cancelled. No changes made.'; return }
    if ($ClearReadOnly) {
        $extra = Read-Host 'Also remove the ReadOnly attribute? Type READONLY'
        if ($extra -cne 'READONLY') { Write-Host '[NT UNLOCK] Cancelled. No changes made.'; return }
    }
    # Create an audit log BEFORE any file is modified. No automatic elevation.
    $destination = Get-NTUnlockLogRoot -LogRoot $LogRoot
    $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($destination))
    if ([IO.DriveInfo]::new($driveRoot).AvailableFreeSpace -lt 10MB) {
        throw "Insufficient space for audit log on $driveRoot. Specify -LogRoot on a drive with at least 10 MB free."
    }
    New-Item -ItemType Directory -Force -Path $destination -ErrorAction Stop | Out-Null
    $log = Join-Path $destination ('NTUnlock_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fffffff') + '.log')
    $heading = @(
        'NT PowerShell 8 Directory Unlocker - Audit',
        ('UTC: ' + [DateTime]::UtcNow.ToString('o')),
        ('Target: ' + $full),
        ('Files: ' + $entries.Count),
        ('Blocked: ' + $blocked.Count),
        ('ClearReadOnly: ' + [bool]$ClearReadOnly),
        'Only Zone.Identifier and optionally ReadOnly file attribute may change.'
    )
    [IO.File]::WriteAllLines($log, [string[]]$heading, [Text.UTF8Encoding]::new($false))
    $fixed = 0; $unlocked = 0; $failed = 0
    foreach ($item in $entries) {
        if (-not $item.Blocked -and -not ($ClearReadOnly -and $item.ReadOnly)) { continue }
        try {
            if ($ClearReadOnly -and $item.ReadOnly) {
                $oldAttr = [IO.File]::GetAttributes($item.File)
                [IO.File]::SetAttributes($item.File, [IO.FileAttributes]([int]$oldAttr -band (-bnot [int][IO.FileAttributes]::ReadOnly)))
                Add-Content -LiteralPath $log -Value ('READONLY_CLEARED ' + $item.File) -Encoding UTF8
                Write-Host ('[READONLY CLEARED] ' + $item.File) -ForegroundColor DarkCyan
            }
            if ($item.Blocked) {
                Unblock-File -LiteralPath $item.File -ErrorAction Stop
                $remaining = @(Get-Item -LiteralPath $item.File -Stream Zone.Identifier -ErrorAction SilentlyContinue)
                if ($remaining.Count -gt 0) { throw 'Zone.Identifier still exists after Unblock-File.' }
                $unlocked++
                Add-Content -LiteralPath $log -Value ('UNBLOCKED ' + $item.File) -Encoding UTF8
                Write-Host ('[UNBLOCKED] ' + $item.File) -ForegroundColor Green
            }
            $fixed++
        }
        catch {
            $failed++
            $reason = $_.Exception.Message
            Add-Content -LiteralPath $log -Value ('FAILED ' + $item.File + ' | ' + $reason) -Encoding UTF8
            Write-Warning ('[FAILED] ' + $item.File + ' | ' + $reason)
        }
    }
    Write-Host ('[NT UNLOCK] Successful: {0}; unblocked: {1}; errors: {2}' -f $fixed,$unlocked,$failed) -ForegroundColor Cyan
    Write-Host ('[NT UNLOCK] Audit: ' + $log)
    if ($failed -gt 0) {
        Write-Warning 'Some files failed. Check the audit; if access was denied, inspect permissions or rerun the trusted operation as admin.'
    }
    Write-Host 'This does not remove antivirus quarantines, file locks, NTFS access controls or repair corrupted files.' -ForegroundColor DarkYellow
}

Export-ModuleMember -Function nt-unlock
