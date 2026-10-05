# NT PowerShell 8 - Silent Reinstall 0.3
# Non-destructive preview by default. Installation uses WinGet package identity.
# This module deliberately DOES NOT delete an application directory manually.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NTRFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)).TrimEnd('\','/')
}

function Assert-NTRSafeTarget {
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Directory does not exist: $Folder" }
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\','/')
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\','/')
    $blocked = @($root, $env:WINDIR, $env:USERPROFILE, $env:ProgramFiles,
        ${env:ProgramFiles(x86)}, $env:APPDATA, $env:LOCALAPPDATA,
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))
    foreach ($entry in $blocked) {
        if ($entry -and $full.Equals($entry.TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)) {
            throw "Protected directory cannot be reinstalled: $full"
        }
    }
    if ($full -match '(?i)[\\/]\.minecraft([\\/]|$)' -or
        $full -match '(?i)[\\/](?:Windows|WindowsApps|System32|WinSxS)([\\/]|$)' -or
        $full -match '(?i)[\\/]NTPS8_Recovery([\\/]|$)') {
        throw 'Refusing a shared/system/user-data directory. Use nt-res with a trusted snapshot for files.'
    }
    $walk = $full
    while ($walk) {
        if (Test-Path -LiteralPath $walk) {
            $item = Get-Item -LiteralPath $walk -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point or symlink is not supported: $walk"
            }
        }
        $parent = [IO.Directory]::GetParent($walk)
        if ($null -eq $parent -or $parent.FullName -eq $walk) { break }
        $walk = $parent.FullName
    }
    foreach ($entry in (Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Folder contains a reparse point: $($entry.FullName)"
        }
    }
    return $full
}

function Get-NTRInstallRegistryMatch {
    param([Parameter(Mandatory)][string]$RequestedPath)
    $locations = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $requested = Get-NTRFullPath $RequestedPath
    $requestedIsFile = Test-Path -LiteralPath $requested -PathType Leaf
    $found = @()
    foreach ($pattern in $locations) {
        foreach ($reg in @(Get-ItemProperty -Path $pattern -ErrorAction SilentlyContinue)) {
            if (-not $reg -or $null -eq $reg.PSObject.Properties['DisplayName'] -or
                $null -eq $reg.PSObject.Properties['InstallLocation']) { continue }
            if (-not $reg.DisplayName -or -not $reg.InstallLocation) { continue }
            $publisherText = if ($reg.PSObject.Properties['Publisher']) { [string]$reg.Publisher } else { '' }
            $versionText = if ($reg.PSObject.Properties['DisplayVersion']) { [string]$reg.DisplayVersion } else { '' }
            $install = [string]$reg.InstallLocation
            if (-not $install -or -not [IO.Path]::IsPathRooted($install) -or
                -not (Test-Path -LiteralPath $install -PathType Container)) { continue }
            try { $install = Get-NTRFullPath $install } catch { continue }
            $match = $install.Equals($requested,[StringComparison]::OrdinalIgnoreCase)
            if ($requestedIsFile) {
                $boundary = $install.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                $match = $requested.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)
            }
            if ($match) {
                $found += [pscustomobject]@{
                    DisplayName=[string]$reg.DisplayName; Publisher=$publisherText
                    Directory=$install; RegistryKey=[string]$reg.PSPath
                    DisplayVersion=$versionText
                }
            }
        }
    }
    $unique = @($found | Sort-Object Directory,DisplayName,Publisher -Unique)
    if ($unique.Count -eq 0) { throw 'No exact installation-directory match in Windows installed-app registry. Refusing to guess the app.' }
    if ($unique.Count -gt 1) {
        Write-Host 'Multiple registered apps match this directory:' -ForegroundColor Yellow
        $unique | Select-Object DisplayName,Publisher,Directory | Format-Table | Out-Host
        throw 'Shared or ambiguous directory. No automated replacement is safe.'
    }
    return $unique[0]
}

function Find-NTRWingetId {
    param([Parameter(Mandatory)][string]$Name)
    # WinGet has human-readable, localized tables; accept ONLY a unique exact-name row.
    # Any table-format ambiguity requires the user to supply -Id explicitly.
    $output = @(& winget list --name $Name --exact --accept-source-agreements 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'WinGet could not resolve the installed app. Try nt-official-search, then supply -Id.'
        return $null
    }
    $matched = @()
    foreach ($line in $output) {
        $regex = '^\s*' + [regex]::Escape($Name) + '\s{2,}(?<id>[A-Za-z][\w+\-]*(?:\.[A-Za-z0-9_+\-]+)+)\s{2,}'
        if ($line -match $regex) { $matched += $Matches['id'] }
    }
    $matched = @($matched | Sort-Object -Unique)
    if ($matched.Count -eq 1) { return $matched[0] }
    Write-Warning 'A unique WinGet package was not established. Supply the exact package ID with -Id.'
    & winget search --name $Name --exact --source winget
    return $null
}

function Invoke-NTRWinget {
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Step)
    Write-Host ('[NT REINSTALL] ' + $Step) -ForegroundColor Cyan
    Write-Host ('  winget ' + ($Arguments -join ' ')) -ForegroundColor DarkGray
    & winget @Arguments
    $code = [int64]$LASTEXITCODE
    Write-Host ('[NT REINSTALL] WinGet exit code: ' + $code)
    return $code
}

function Get-NTRFreeBytes {
    param([string]$Folder)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Folder)))
    return [long]$drive.AvailableFreeSpace
}

function nt-reinstall {
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory,Position=0)][string]$Path,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_+\-]*(\.[A-Za-z0-9_+\-]+)+$')][string]$Id,
        [string]$Store,
        [string]$StagingRoot,
        [string]$LogRoot,
        [switch]$Silent,
        [switch]$ForceReinstall,
        [switch]$ReplaceDirectory,
        [switch]$Apply
    )
    if (-not $IsWindows) { throw 'nt-reinstall is available only in Windows PowerShell 7+.' }
    if ($ReplaceDirectory -and -not $ForceReinstall) {
        throw '-ReplaceDirectory requires -ForceReinstall and explicit consent.'
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'WinGet was not found.' }
    $requested = Get-NTRFullPath $Path
    if (-not (Test-Path -LiteralPath $requested)) { throw "Target not found: $requested" }
    if ((Test-Path -LiteralPath $requested -PathType Leaf) -and
        ([IO.Path]::GetExtension($requested) -notin @('.exe','.msi'))) {
        throw 'Use an installed application EXE or its registered installation directory.'
    }
    $registration = Get-NTRInstallRegistryMatch -RequestedPath $requested
    $folder = Assert-NTRSafeTarget $registration.Directory
    if ($requested -ne $folder -and (Test-Path -LiteralPath $requested -PathType Container)) {
        throw 'Provide the exact registered application directory, not a shared parent or subfolder.'
    }
    $knownId = $Id
    if (-not $knownId) { $knownId = Find-NTRWingetId -Name $registration.DisplayName }
    if (-not $knownId) {
        Write-Host ('[NT REINSTALL] Identified: ' + $registration.DisplayName + ' (' + $registration.Publisher + ')')
        Write-Host 'Run: nt-reinstall "your path" -Id Publisher.Package -Silent (then add -Apply).'
        return
    }
    $showCode = Invoke-NTRWinget -Step 'Verifying EXACT package in WinGet catalog' -Arguments @('show','--id',$knownId,'--exact','--source','winget','--accept-source-agreements')
    if ($showCode -ne 0) { throw 'The exact package ID was not found in WinGet. Nothing changed.' }
    $installedCode = Invoke-NTRWinget -Step 'Checking installed package identity' -Arguments @('list','--id',$knownId,'--exact','--accept-source-agreements')
    if ($installedCode -ne 0) { throw 'WinGet did not find the requested installed package. Nothing changed.' }
    $backupRoot = if ($Store) { Get-NTRFullPath $Store } elseif ($env:NTPS8_BACKUP_ROOT) { Get-NTRFullPath $env:NTPS8_BACKUP_ROOT } elseif (Test-Path -LiteralPath 'C:\') { 'C:\PowerShell_8_Files\NTPS8_Recovery' } else { Join-Path $env:USERPROFILE 'NTPS8_Recovery' }
    $stageBase = if ($StagingRoot) { Get-NTRFullPath $StagingRoot } elseif (Test-Path -LiteralPath 'C:\') { 'C:\PowerShell_8_Files\NTPS8_Staging' } else { Join-Path $env:TEMP 'NTPS8_Staging' }
    $logsBase = if ($LogRoot) { Get-NTRFullPath $LogRoot } elseif (Test-Path -LiteralPath 'C:\') { 'C:\PowerShell_8_Files\NTPS8_Logs' } else { Join-Path $env:USERPROFILE 'NTPS8_Logs' }
    $full = @($folder,$backupRoot,$stageBase,$logsBase)
    foreach ($value in $full) {
        if ($value -match '(?i)[\\/]\.minecraft([\\/]|$)' -or $value -match '(?i)[\\/](Windows|WindowsApps|WinSxS)([\\/]|$)') {
            throw 'Unsafe application or storage path.'
        }
    }
    foreach ($storeDir in @($backupRoot,$stageBase,$logsBase)) {
        if ($storeDir.Equals($folder,[StringComparison]::OrdinalIgnoreCase) -or
            $storeDir.StartsWith($folder.TrimEnd('\','/') + '\',[StringComparison]::OrdinalIgnoreCase)) {
            throw "Temporary/backup storage must not be inside the application: $storeDir"
        }
    }
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '[NT PS8] SILENT REINSTALL / MANUAL CONTROL' -ForegroundColor Cyan
    Write-Host ('App:       ' + $registration.DisplayName)
    Write-Host ('Publisher: ' + $registration.Publisher)
    Write-Host ('WinGet ID: ' + $knownId)
    Write-Host ('Directory: ' + $folder)
    Write-Host ('Mode:      ' + $(if ($ReplaceDirectory) { 'UNINSTALL + QUARANTINE OLD DIRECTORY + REINSTALL' } elseif ($ForceReinstall) { 'UNINSTALL + REINSTALL (app settings may be lost)' } else { 'WinGet repair' }))
    Write-Host ('Silent:    ' + [bool]$Silent + ' (hides installer dialogs, NOT the NT PS8 log)')
    Write-Host ('Backup:    ' + $backupRoot)
    Write-Host ('Download:  ' + $stageBase)
    Write-Host ('Logs:      ' + $logsBase)
    if (-not $Apply) {
        Write-Host '[NT REINSTALL] PREVIEW ONLY. No download, backup or installation has started.' -ForegroundColor Yellow
        Write-Host 'Add -Apply to proceed. A typed confirmation will still be required.'
        return
    }
    $confirmText = if ($ReplaceDirectory) { 'REPLACE DIRECTORY' } elseif ($ForceReinstall) { 'REINSTALL' } else { 'REPAIR' }
    if ((Read-Host "Type $confirmText to continue for $knownId") -cne $confirmText) {
        Write-Host '[NT REINSTALL] Cancelled. No changes made.'; return
    }
    $windowsDrive = [IO.Path]::GetPathRoot($env:WINDIR)
    if ((Get-NTRFreeBytes $windowsDrive) -lt 2GB) {
        throw 'Windows drive has less than 2 GB free. Even an C: installation needs Windows Installer space. Free disk C: first.'
    }
    [long]$appBytes = 0
    foreach ($file in (Get-ChildItem -LiteralPath $folder -File -Recurse -Force)) { $appBytes += $file.Length }
    if ((Get-NTRFreeBytes $backupRoot) -lt ([math]::Max(200MB,[math]::Ceiling($appBytes * 1.15)))) {
        throw 'Backup disk does not have sufficient free space. Stopped before any change.'
    }
    if ((Get-NTRFreeBytes $stageBase) -lt 1GB) {
        throw 'Staging disk needs at least 1 GB free. Stopped before any change.'
    }
    $active = @()
    try {
        $active = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($folder.TrimEnd('\','/') + '\',[StringComparison]::OrdinalIgnoreCase)
        })
    } catch {
        Write-Warning 'Unable to check active applications. Close the target app before proceeding.'
        throw 'Process check unavailable; aborting to avoid locked files.'
    }
    if ($active.Count -gt 0) {
        $active | Select-Object ProcessId,Name,ExecutablePath | Format-Table | Out-Host
        throw 'Close every process running from the target folder and retry.'
    }
    foreach ($destination in @($backupRoot,$stageBase,$logsBase)) {
        # Recheck storage paths before creating them.
        $walk = $destination
        while ($walk) {
            if (Test-Path -LiteralPath $walk) {
                $entry = Get-Item -LiteralPath $walk -Force
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unsafe storage reparse point: $walk" }
            }
            $parent = [IO.Directory]::GetParent($walk)
            if ($null -eq $parent -or $parent.FullName -eq $walk) { break }
            $walk = $parent.FullName
        }
        [IO.Directory]::CreateDirectory($destination) | Out-Null
    }
    $stage = Join-Path $stageBase ('reinstall_' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $journal = Join-Path $logsBase ('NT_Reinstall_' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
    $transcript = $false
    $success = $false
    $snapshotPath = $null
    $quarantinePath = $null
    try {
        Start-Transcript -LiteralPath $journal -ErrorAction Stop | Out-Null
        $transcript = $true
        Write-Host ('[NT REINSTALL] Log: ' + $journal) -ForegroundColor Cyan
        Write-Host '[1/5] Saving complete app directory snapshot ...' -ForegroundColor Cyan
        # nt-snapshot is exported by NTPS8.Recovery.psm1 and hashes every copied file.
        $saved = nt-snapshot $folder -Store $backupRoot
        $snapshotPath = $saved.Snapshot
        $checked = nt-verify $snapshotPath
        if (-not $checked.Valid) { throw 'Snapshot verification failed; no installer will run.' }
        Write-Host ('[NT REINSTALL] Verified backup: ' + $snapshotPath)
        Write-Host '[2/5] Downloading EXACT WinGet package to isolated stage ...' -ForegroundColor Cyan
        $dlCode = Invoke-NTRWinget -Step 'Download package (WinGet checks manifest digest; no hash bypass)' -Arguments @('download','--id',$knownId,'--exact','--source','winget','--download-directory',$stage,'--accept-source-agreements','--accept-package-agreements')
        if ($dlCode -ne 0) { throw "Installer download failed: $dlCode. Backup and stage retained." }
        $installers = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { $_.Extension -in @('.msi','.exe','.msix','.msixbundle') })
        if ($installers.Count -eq 0) { throw 'No supported installer file was staged; stopping safely.' }
        foreach ($installer in $installers) {
            Write-Host ('  Staged: ' + $installer.FullName)
            Write-Host ('  SHA256: ' + (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash)
        }
        Write-Host '[3/5] Executing supported recovery ...' -ForegroundColor Cyan
        $switches = @('repair','--id',$knownId,'--exact','--source','winget','--accept-source-agreements','--accept-package-agreements')
        if ($Silent) { $switches += '--silent' }
        if (-not $ForceReinstall) {
            $repairCode = Invoke-NTRWinget -Step 'Repair with the official installer configuration' -Arguments $switches
            if ($repairCode -ne 0) {
                throw "WinGet repair failed ($repairCode). Stage/backup saved. Use -ForceReinstall only after assessing data loss."
            }
        } else {
            $removeArgs = @('uninstall','--id',$knownId,'--exact','--accept-source-agreements')
            if ($Silent) { $removeArgs += '--silent' }
            $removeCode = Invoke-NTRWinget -Step 'Removing EXACT registered app (no manual folder deletion)' -Arguments $removeArgs
            if ($removeCode -ne 0) { throw "Uninstall failed ($removeCode); no reinstall attempted. Backup and stage retained." }
            if ($ReplaceDirectory -and (Test-Path -LiteralPath $folder -PathType Container)) {
                # An *exactly registered*, isolated installation folder is quarantined, NEVER deleted.
                # Rename inside the SAME parent/volume for an atomic move where supported.
                $parentFolder = [IO.Directory]::GetParent($folder).FullName
                $quarantineName = '.NTPS8_quarantine_' + [IO.Path]::GetFileName($folder) + '_' + [guid]::NewGuid().ToString('N').Substring(0,12)
                $quarantinePath = Join-Path $parentFolder $quarantineName
                Write-Host ('[NT REINSTALL] Quarantining leftover app files: ' + $quarantinePath) -ForegroundColor Yellow
                Move-Item -LiteralPath $folder -Destination $quarantinePath -ErrorAction Stop
            }
            # Use the file from the isolated stage only when a single signed MSI is present.
            # For arbitrary EXE/MSIX packages, WinGet supplies vendor-specific installer flags and
            # downloads its own verified copy; do not guess executable silent flags.
            $stagedMsi = @($installers | Where-Object { $_.Extension -ieq '.msi' })
            $usedStagedInstaller = $false
            if ($installers.Count -eq 1 -and $stagedMsi.Count -eq 1) {
                $msi = $stagedMsi[0]
                $signature = Get-AuthenticodeSignature -LiteralPath $msi.FullName
                Write-Host ('[NT REINSTALL] Staged MSI signature: ' + $signature.Status)
                if ($signature.Status -eq 'Valid') {
                    $msiLog = Join-Path $logsBase ('MSI_' + [guid]::NewGuid().ToString('N') + '.log')
                    Write-Host ('[NT REINSTALL] Installing verified staged MSI: ' + $msi.FullName) -ForegroundColor Cyan
                    Write-Host ('[NT REINSTALL] MSI verbose log: ' + $msiLog)
                    $msiUi = if ($Silent) { '/qn ' } else { '' }
                    $msiArguments = '/i "' + $msi.FullName + '" ' + $msiUi + '/norestart /L*v "' + $msiLog + '"'
                    $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -Wait -PassThru
                    if ($msiProcess.ExitCode -eq 3010) {
                        throw 'Windows Installer needs a reboot (3010). Temporary installer and backup retained; verify after restarting.'
                    }
                    if ($msiProcess.ExitCode -ne 0) {
                        throw ('Staged MSI installation failed with code ' + $msiProcess.ExitCode + '. Check ' + $msiLog)
                    }
                    $usedStagedInstaller = $true
                } else {
                    Write-Warning 'Staged MSI is not Authenticode-valid. Using WinGet verified installation instead.'
                }
            }
            if (-not $usedStagedInstaller) {
                Write-Host '[NT REINSTALL] No uniquely verified MSI for direct staging. WinGet may download another verified copy.'
                $installArgs = @('install','--id',$knownId,'--exact','--source','winget','--accept-source-agreements','--accept-package-agreements')
                if ($Silent) { $installArgs += '--silent' }
                $installCode = Invoke-NTRWinget -Step 'Fresh installation by exact package ID' -Arguments $installArgs
                if ($installCode -ne 0) { throw "Fresh install failed ($installCode). Backup and stage retained for manual recovery." }
            }
        }
        Write-Host '[4/5] Checking resulting program files ...' -ForegroundColor Cyan
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            throw 'Installer finished but original directory was not restored (perhaps the install path changed). Do not claim repair succeeded.'
        }
        $after = @(Get-ChildItem -LiteralPath $folder -File -Recurse -Force -ErrorAction Stop)
        if ($after.Count -eq 0) { throw 'Program directory is still empty. Keeping staged installer and backup.' }
        if ((Test-Path -LiteralPath $requested -PathType Leaf) -eq $false -and
            ([IO.Path]::GetExtension($requested) -in @('.exe','.msi'))) {
            throw 'Original requested executable is still missing. Staged installer and backup are retained.'
        }
        Write-Host ('[NT REINSTALL] Directory exists; files present: ' + $after.Count) -ForegroundColor Green
        Write-Host '[NT REINSTALL] A launch test is still required; directory presence alone cannot prove health.' -ForegroundColor Yellow
        $success = $true
    } catch {
        Write-Host ('[NT REINSTALL] FAILED: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('[NT REINSTALL] Kept backup: ' + $snapshotPath) -ForegroundColor Yellow
        Write-Host ('[NT REINSTALL] Kept stage:  ' + $stage) -ForegroundColor Yellow
        throw
    } finally {
        if ($transcript) { Stop-Transcript | Out-Null }
        if ($success) {
            Write-Host '[5/5] Deleting temporary staged installer after successful verification ...' -ForegroundColor Cyan
            try {
                foreach ($entry in (Get-ChildItem -LiteralPath $stage -Recurse -Force)) {
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw ('Refusing to clean staging tree containing a reparse point: ' + $entry.FullName)
                    }
                }
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
                Write-Host '[NT REINSTALL] Temporary installer deleted.' -ForegroundColor Green
            } catch { Write-Warning ('Could not clean temporary stage: ' + $_.Exception.Message) }
        }
        Write-Host ('[NT REINSTALL] Journal: ' + $journal)
        if ($snapshotPath) { Write-Host ('[NT REINSTALL] Preserved original backup: ' + $snapshotPath) }
    }
}

Export-ModuleMember -Function nt-reinstall
