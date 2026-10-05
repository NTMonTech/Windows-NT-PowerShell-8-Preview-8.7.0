# NT PowerShell 8 Preview 0.4 - Dependency Recovery
# Real engine: separately installed Microsoft PowerShell 7.
# Strict package allowlist. No arbitrary URL execution or unattended privilege elevation.
Set-StrictMode -Version Latest

function Get-NTDepsCatalog {
    return [ordered]@{
        PowerShell7 = [pscustomobject]@{ Id='Microsoft.PowerShell'; Title='Microsoft PowerShell 7'; DiskGB=2; Required=$true }
        Git         = [pscustomobject]@{ Id='Git.Git'; Title='Git for Windows'; DiskGB=2; Required=$false }
        GitHubCLI   = [pscustomobject]@{ Id='GitHub.cli'; Title='GitHub CLI (gh)'; DiskGB=2; Required=$false }
        Python310   = [pscustomobject]@{ Id='Python.Python.3.10'; Title='Python 3.10'; DiskGB=2; Required=$false }
    }
}

function Test-NTDependency {
    param([Parameter(Mandatory=$true)][ValidateSet('PowerShell7','Git','GitHubCLI','Python310','WinGet')][string]$Name)
    switch ($Name) {
        'WinGet' { return ($null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)) }
        'Git' { return ($null -ne (Get-Command git.exe -ErrorAction SilentlyContinue)) }
        'GitHubCLI' { return ($null -ne (Get-Command gh.exe -ErrorAction SilentlyContinue)) }
        'Python310' {
            $py = Get-Command py.exe -ErrorAction SilentlyContinue
            if ($null -ne $py) {
                & $py.Source -3.10 --version 1>$null 2>$null
                if ($LASTEXITCODE -eq 0) { return $true }
            }
            $python = Get-Command python.exe -ErrorAction SilentlyContinue
            if ($null -ne $python -and $python.Source -notlike '*\WindowsApps\*') {
                $version = (& $python.Source --version 2>&1 | Out-String)
                if ($version -match 'Python 3\.10\.') { return $true }
            }
            return $false
        }
        'PowerShell7' {
            if ($PSVersionTable.PSVersion.Major -ge 7 -and (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -PathType Leaf)) { return $true }
            $paths = [System.Collections.Generic.List[string]]::new()
            if ($env:NT_PWSH_EXE) { $paths.Add($env:NT_PWSH_EXE.Trim('"')) }
            $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if ($cmd) { $paths.Add($cmd.Source) }
            foreach ($base in @($env:ProgramFiles, ${env:ProgramW6432})) {
                if ($base) { $paths.Add((Join-Path $base 'PowerShell\7\pwsh.exe')) }
            }
            foreach ($drivePath in @('C:\PowerShell\7\pwsh.exe','C:\PowerShell7\pwsh.exe')) { $paths.Add($drivePath) }
            foreach ($path in $paths) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $true } }
            return $false
        }
    }
}

function Get-NTDepStorage {
    $base = $null
    if (Test-Path -LiteralPath 'C:\' -PathType Container) {
        $base = 'C:\PowerShell_8_Files\NTPS8_Recovery\dependency_logs'
    } elseif ($env:LOCALAPPDATA) {
        $base = Join-Path $env:LOCALAPPDATA 'NTPS8\dependency_logs'
    } else {
        $base = Join-Path $env:TEMP 'NTPS8\dependency_logs'
    }
    New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop | Out-Null
    return $base
}

function Assert-NTDepDiskSpace {
    param([string]$DriveLetter='C', [int]$RequiredGB=2)
    $drive = Get-PSDrive -Name $DriveLetter -PSProvider FileSystem -ErrorAction Stop
    $free = [math]::Round($drive.Free/1GB, 2)
    Write-Host ("[NT DEPS] Drive {0}: {1} GB free; threshold: {2} GB." -f $DriveLetter, $free, $RequiredGB)
    if ($drive.Free -lt ($RequiredGB * 1GB)) {
        throw ("Not enough free space on drive {0}: ({1} GB). Installers may still use C: even when targeting C:. Free space before continuing." -f $DriveLetter, $free)
    }
}

function Get-NTDependencyStatus {
    [CmdletBinding()]
    param()
    $catalog = Get-NTDepsCatalog
    foreach ($key in @('PowerShell7','Git','GitHubCLI','Python310','WinGet')) {
        $present = Test-NTDependency $key
        $isRequired = ($key -eq 'PowerShell7')
        [pscustomobject]@{
            Component=$key
            Installed=$present
            Required=$isRequired
            Source=$(if ($key -eq 'WinGet') { 'Windows App Installer' } else { $catalog[$key].Id })
        }
    }
}

function Invoke-NTDepsWingetShow {
    param([Parameter(Mandatory=$true)][string]$PackageId)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'WinGet is missing. Install Microsoft App Installer manually: https://aka.ms/getwinget (never download executables from a random mirror).'
    }
    Write-Host ("[NT DEPS] Verifying exact package with WinGet: {0}" -f $PackageId) -ForegroundColor Cyan
    & $winget.Source show --id $PackageId --exact --source winget --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw ("WinGet could not verify package {0}; cancelled." -f $PackageId) }
    return $winget.Source
}

function Invoke-NTDepElevatedInstall {
    param(
        [ValidateSet('PowerShell7','Git','GitHubCLI','Python310')]
        [string]$Component,

        [string]$LogDirectory
    )

    if (-not (Get-Command Invoke-NTPS8ElevatedScript -ErrorAction SilentlyContinue)) {
        throw 'NTPS8 Runtime Bridge is not available.'
    }

    if (-not $global:NTPS8_AdminScripts) {
        throw 'NTPS8 administrative helper storage is not available.'
    }

    $helperSource = $global:NTPS8_AdminScripts.DepsAdmin

    if ([string]::IsNullOrWhiteSpace($helperSource)) {
        throw 'NTPS8.DepsAdmin helper source is unavailable.'
    }

    $log = Join-Path `
        $LogDirectory `
        ('install_' + $Component + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

    Write-Host '[NT DEPS] Requesting administrator approval (Windows UAC)...' `
        -ForegroundColor Yellow

    $exitCode = Invoke-NTPS8ElevatedScript `
        -ScriptSource $helperSource `
        -Arguments @(
            $Component
            $log
        )

    Write-Host (
        '[NT DEPS] Installer exited with code {0}. Log: {1}' -f
        $exitCode,
        $log
    )

    if ($exitCode -ne 0) {
        throw (
            'Installation failed with exit code ' +
            $exitCode
        )
    }
}

function nt-deps {
    [CmdletBinding()]
    param(
        [switch]$Check,
        [ValidateSet('PowerShell7','Git','GitHubCLI','Python310')][string]$Install,
        [switch]$DownloadOnly,
        [switch]$Apply
    )
    if (-not $Install) {
        $status = @(Get-NTDependencyStatus)
        $status | Format-Table -AutoSize | Out-Host
        if (-not (Test-NTDependency WinGet)) {
            Write-Host '[NT DEPS] WinGet missing. Install Microsoft App Installer: https://aka.ms/getwinget' -ForegroundColor Yellow
        }
        Write-Host 'Use: nt-deps -Install Git -Apply   (or PowerShell7 / GitHubCLI / Python310)' -ForegroundColor Gray
        return
    }
    $catalog = Get-NTDepsCatalog
    $package = $catalog[$Install]
    if (Test-NTDependency $Install) {
        Write-Host ("[NT DEPS] {0} already installed. No action." -f $package.Title) -ForegroundColor Green
        return
    }
    if (-not $Apply) {
        Write-Host ("[PREVIEW] Missing: {0}; WinGet ID: {1}" -f $package.Title, $package.Id) -ForegroundColor Cyan
        Write-Host ('[PREVIEW] Official package search, explicit user confirmation, Windows UAC for install; no automatic EXE execution.')
        Write-Host ("[PREVIEW] To proceed: nt-deps -Install {0} -Apply" -f $Install)
        return
    }
    # Normal MSI installations still write to C:, even if the user prefers C:.
    if (-not $DownloadOnly) {
        Assert-NTDepDiskSpace -DriveLetter 'C' -RequiredGB ([int]$package.DiskGB)
    }
    $winget = Invoke-NTDepsWingetShow -PackageId $package.Id
    $logs = Get-NTDepStorage
    if ($DownloadOnly) {
        $volume = [System.IO.Path]::GetPathRoot($logs).Substring(0,1)
        Assert-NTDepDiskSpace -DriveLetter $volume -RequiredGB 1
        Write-Host '[NT DEPS] WinGet may also use its own Windows cache on C: while downloading.' -ForegroundColor Yellow
        $folder = Join-Path $logs ('staging_' + $Install + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $answer = Read-Host ("Download verified package {0} to {1} without installing? Type DOWNLOAD" -f $package.Id, $folder)
        if ($answer -cne 'DOWNLOAD') { Write-Host '[NT DEPS] Cancelled.'; return }
        & $winget download --id $package.Id --exact --source winget --download-directory $folder --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw ('Download failed. Exit code ' + $LASTEXITCODE) }
        Write-Host ("[NT DEPS] Download completed. Files: {0}" -f $folder) -ForegroundColor Green
        return
    }
    $answer = Read-Host ("Install {0} ({1})? This will request Windows administrator approval. Type INSTALL" -f $package.Title, $package.Id)
    if ($answer -cne 'INSTALL') { Write-Host '[NT DEPS] Cancelled; no changes.'; return }
    Invoke-NTDepElevatedInstall -Component $Install -LogDirectory $logs
    Write-Host '[NT DEPS] WinGet returned success; checking installation...' -ForegroundColor Cyan
    # Current process may have stale PATH: WinGet status alone is not proof that the current shell refreshed.
    if (Test-NTDependency $Install) {
        Write-Host ('[NT DEPS] ' + $package.Title + ' is available.') -ForegroundColor Green
    } else {
        Write-Host '[NT DEPS] Installation finished, but this terminal cannot yet see the tool. Restart NT PowerShell 8 and run nt-deps -Check.' -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function nt-deps,Get-NTDependencyStatus
