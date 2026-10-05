# NT PowerShell 8 Preview 0.5 - Genuine Kali Linux shell via official WSL.
# Only explicitly requested installation; user confirmation + Windows UAC.
# No emulated Kali toolchain; Linux processes run in the user's WSL distro.
Set-StrictMode -Version Latest

function Get-NTKaliWslExecutable {
    $candidate = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $candidate) { return $candidate.Source }
    if ($env:WINDIR) {
        $system = Join-Path $env:WINDIR 'System32\wsl.exe'
        if (Test-Path -LiteralPath $system -PathType Leaf) { return $system }
    }
    return $null
}

function Get-NTKaliStatus {
    [CmdletBinding()]
    param()
    $wsl = Get-NTKaliWslExecutable
    $installed = $false
    $detail = 'WSL executable is not available on this Windows installation.'
    if ($wsl) {
        # WSL stdout has returned embedded NULs on some Windows/PowerShell combinations.
        $output = (& $wsl --list --quiet 2>&1 | Out-String) -replace "`0", ''
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $names = @($output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $installed = @($names | Where-Object { $_ -ieq 'kali-linux' }).Count -gt 0
            $detail = if ($installed) { 'kali-linux is registered in WSL.' } else { 'WSL available; kali-linux is not registered.' }
        } else {
            $detail = 'WSL could not list distributions; installation or a Windows reboot may be required.'
        }
    }
    [pscustomobject]@{
        WSLFound = [bool]$wsl
        KaliInstalled = [bool]$installed
        Status = $detail
        Executable = $wsl
    }
}

function Get-NTKaliStorage {
    if (Test-Path -LiteralPath 'C:\' -PathType Container) {
        $folder = 'C:\PowerShell_8_Files\NTPS8_Recovery\kali_logs'
    } elseif ($env:LOCALAPPDATA) {
        $folder = Join-Path $env:LOCALAPPDATA 'NTPS8\kali_logs'
    } else {
        $folder = Join-Path $env:TEMP 'NTPS8\kali_logs'
    }
    New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    return $folder
}

function Assert-NTKaliLocation {
    param([Parameter(Mandatory=$true)][string]$Location)
    if ($Location -notmatch '^[A-Za-z]:\\[^\\].+' -or $Location -match '["\r\n]') {
        throw 'Choose an absolute local directory, such as C:\PowerShell_8_Files\WSL\KaliLinux. Network paths and drive roots are not permitted.'
    }
    $full = [System.IO.Path]::GetFullPath($Location).TrimEnd('\')
    $drive = $full.Substring(0,1)
    if ($full -eq ($drive + ':') -or $full -match '^[A-Za-z]:\\(Windows|Program Files|Users)(\\|$)') {
        throw 'Refusing to install over a system or user profile directory.'
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) { throw 'Install target is a file.' }
    if (Test-Path -LiteralPath $full -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop).Count -gt 0) {
            throw 'Install target exists and is not empty. Choose a new directory; no files will be overwritten.'
        }
    }
    return $full
}

function Assert-NTKaliSpace {
    param([Parameter(Mandatory=$true)][string]$Location)
    $windows = Get-PSDrive -Name C -PSProvider FileSystem -ErrorAction Stop
    $target = Get-PSDrive -Name $Location.Substring(0,1) -PSProvider FileSystem -ErrorAction Stop
    $freeC = [math]::Round($windows.Free / 1GB, 2)
    $freeTarget = [math]::Round($target.Free / 1GB, 2)
    Write-Host ("[NT KALI] Free: C: {0} GB; target: {1} GB" -f $freeC, $freeTarget)
    # Windows WSL features, distribution staging, and logs can still write to C:.
    if ($windows.Free -lt 2GB) { throw 'C: needs at least 2 GB free for WSL setup. Installation cancelled.' }
    if ($target.Free -lt 4GB) { throw 'Target drive needs at least 4 GB free for Kali. Installation cancelled.' }
}

function Invoke-NTKaliElevatedInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    if (-not (Get-Command Invoke-NTPS8ElevatedScript -ErrorAction SilentlyContinue)) {
        throw 'NTPS8 Runtime Bridge is not available.'
    }

    if (-not $global:NTPS8_AdminScripts) {
        throw 'NTPS8 administrative helper storage is not available.'
    }

    $helperSource = $global:NTPS8_AdminScripts.KaliAdmin

    if ([string]::IsNullOrWhiteSpace($helperSource)) {
        throw 'NTPS8.KaliAdmin helper source is unavailable.'
    }

    $logs = Get-NTKaliStorage

    $log = Join-Path `
        $logs `
        ('kali_install_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

    Write-Host `
        '[NT KALI] Requesting Windows administrator approval (UAC)...' `
        -ForegroundColor Yellow

    $exitCode = Invoke-NTPS8ElevatedScript `
        -ScriptSource $helperSource `
        -Arguments @(
            $Location
            $log
        )

    Write-Host (
        '[NT KALI] Installer exit code: ' +
        $exitCode
    )

    Write-Host (
        '[NT KALI] Saved journal: ' +
        $log
    )

    if ($exitCode -ne 0) {
        throw `
            'Official WSL installation did not complete. Check the journal; existing files have not been deliberately deleted.'
    }
}

function nt-kali-wsl {
    [CmdletBinding(DefaultParameterSetName='Shell')]
    param(
        [Parameter(ParameterSetName='Check')][switch]$Check,
        [Parameter(ParameterSetName='Install')][switch]$Install,
        [Parameter(ParameterSetName='Install')][string]$Location,
        [Parameter(ParameterSetName='Install')][switch]$Apply,
        [Parameter(ParameterSetName='Exec',Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Exec,
        [Parameter(ParameterSetName='Shell')][switch]$Help
    )
    if ($Help) {
        @'
NT PowerShell 8 -> genuine Kali Linux terminal (WSL)
  nt-kali-wsl -Check                                  Check WSL + Kali status
  nt-kali-wsl -Install -Location "A:\WSL\KaliLinux"    Preview installation
  nt-kali-wsl -Install -Location "A:\WSL\KaliLinux" -Apply
                                                   Confirm INSTALL then Windows UAC
  nt-kali-wsl                                         Enter interactive Kali Bash (exit to return)
  nt-kali-wsl -Exec 'uname -a'                         Run one real Linux command and return
Linux user setup may be requested on first launch. Linux sudo prompts are separate
from Windows UAC; this tool never sets Linux root or grants sudo automatically.
'@ | Write-Host
        return
    }
    $status = Get-NTKaliStatus
    if ($Check) {
        $status | Format-List | Out-Host
        if (-not $status.KaliInstalled) {
            Write-Host '[NT KALI] No Kali distribution installed. Use nt-kali-wsl -Install -Location "C:\PowerShell_8_Files\WSL\KaliLinux" to preview.'
        }
        return
    }
    if ($Install) {
        if ($status.KaliInstalled) {
            Write-Host '[NT KALI] Kali is already registered; no installation performed.' -ForegroundColor Green
            return
        }
        if (-not $Location) {
            if (Test-Path -LiteralPath 'C:\' -PathType Container) {
                $Location = 'C:\PowerShell_8_Files\WSL\KaliLinux'
            } else {
                throw 'Specify -Location on a drive with sufficient free space. No automatic install to C:.'
            }
        }
        $resolved = Assert-NTKaliLocation -Location $Location
        Write-Host '[NT KALI] Proposed provider: official Windows WSL, distro kali-linux.' -ForegroundColor Cyan
        Write-Host ('[NT KALI] Target: ' + $resolved)
        Write-Host '[NT KALI] Windows features/cache may still use C:. Reboot may be needed.' -ForegroundColor Yellow
        if (-not $Apply) {
            Write-Host ('[PREVIEW] To install: nt-kali-wsl -Install -Location "{0}" -Apply' -f $resolved)
            return
        }
        if (-not $status.WSLFound) {
            throw 'wsl.exe is not present. Enable/install official WSL before continuing: https://learn.microsoft.com/windows/wsl/install'
        }
        Assert-NTKaliSpace -Location $resolved
        $answer = Read-Host ('Install official Kali Linux in ' + $resolved + '? Type INSTALL')
        if ($answer -cne 'INSTALL') { Write-Host '[NT KALI] Cancelled; nothing downloaded.'; return }
        Invoke-NTKaliElevatedInstall -Location $resolved
        return
    }
    if (-not $status.WSLFound) { throw 'WSL is unavailable. Run nt-kali-wsl -Check for details.' }
    if (-not $status.KaliInstalled) { throw 'kali-linux is not installed or not initialized. Run nt-kali-wsl -Check.' }
    Write-Host '[NT KALI] Starting the genuine Kali Linux WSL distribution.' -ForegroundColor Cyan
    if ($PSCmdlet.ParameterSetName -eq 'Exec') {
        # Run precisely one user-specified Linux command in genuine Bash.
        & $status.Executable --distribution kali-linux --exec /bin/bash -lc $Exec
    } else {
        Write-Host '[NT KALI] Use exit to return to NT PowerShell 8.' -ForegroundColor Gray
        & $status.Executable --distribution kali-linux
    }
    $code = [int]$LASTEXITCODE
    Write-Host ('[NT KALI] Linux exit code: ' + $code) -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
    $global:LASTEXITCODE = $code
}

Export-ModuleMember -Function nt-kali-wsl,Get-NTKaliStatus
