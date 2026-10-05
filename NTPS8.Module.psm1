# NT PowerShell 8 experimental extension module.
# Release includes full official Microsoft PowerShell 7.x runtime with all its own dependencies.
Set-StrictMode -Version Latest

function nt-version {
    [CmdletBinding()]
    param()
    Write-Host 'NT PowerShell 8 GitHub + Remote Kali Preview 8.7.0' -ForegroundColor Cyan
    Write-Host ('Underlying engine: PowerShell ' + $PSVersionTable.PSVersion.ToString())
    Write-Host 'Publisher of NT extension: Net Tweaking Studio'
    Write-Host 'Independent project, NOT an official Microsoft PowerShell 8 release.' -ForegroundColor Yellow
}

function nt-engine {
    [CmdletBinding()]
    param()
    Write-Host ('NT PS8 version: Preview 8.7.0') -ForegroundColor Magenta
    Write-Host ('Actual engine: PowerShell ' + $PSVersionTable.PSVersion.ToString())
    Write-Host ('Engine origin: ' + $env:NT_PS8_ENGINE_SOURCE)
    Write-Host ('Engine directory: ' + $PSHOME)
    Write-Host 'PowerShell engine: Microsoft and contributors (MIT). NT extension: independent project.'
}

function nt-help {
    [CmdletBinding()]
    param()
    # Single centralized help screen for all NT PS8 commands (including newly installed modules).
    @'
==============================================================
 Windows NT PowerShell 8 - CENTRAL COMMAND REFERENCE | PREVIEW 8.7.0
 Net Tweaking Studio (independent project with bundled Microsoft PS7 Runtime)
==============================================================

UNLOCK DOWNLOADED FILES / DIRECTORIES (DANGER)
 nt-unlock "A:\Games\MyGame" -Check              Check download blocks (no changes)
 nt-unlock "A:\Games\MyGame" -Apply              Preview + type UNBLOCK to remove MOTW
 nt-unlock "A:\Games\MyGame" -ClearReadOnly -Apply
                                                   Explicit ReadOnly removal too
 Note: no Defender, SmartScreen, ACL, owner, file-in-use or password bypass.

RECOVERY / VERIFICATION
 nt-scan "A:\Apps\App.exe" -Deep               Inspect a file (SHA256 and signature)
 nt-snapshot "A:\Apps\App"                 Save file/directory snapshot
 nt-verify "A:\NTPS8_Recovery\snapshot_..." Verify a saved snapshot
 nt-compare "A:\Apps\App" -Snapshot "..."   Compare folder against snapshot
 nt-res "A:\Apps\App" -Restore          Find available restoration options
 nt-res "A:\Apps\App" -Restore -From "..." -Apply
                                                   Restore with confirmation
 nt-rollback "A:\NTPS8_Recovery\restore_..." -Apply
                                                   Roll back restoration
 nt-run "C:\path\app.exe"                   Launch; display real exit code

OFFICIAL APPLICATION / WINDOWS REPAIR
 nt-official-search "A:\Apps\App.exe"         Search official WinGet sources
 nt-winget-repair -Id Publisher.App -Apply      Repair an installed app
 nt-reinstall "A:\Apps\App.exe" -Silent        Preview silent reinstall
 nt-reinstall "A:\Apps\App" -Id Publisher.App -Silent -Apply
 nt-reinstall "A:\Apps\App" -Id Publisher.App -Silent -ForceReinstall -ReplaceDirectory -Apply
 nt-windows-repair -Mode Check|Scan|Repair -Apply
 nt-disk-check -Drive A -Apply              Run CHKDSK online scan
 nt-check-disk                              List free space

COMPONENTS
 nt-deps -Check                             Report missing dependencies
 nt-deps -Install Git                       Preview allowed package
 nt-deps -Install Git -Apply                Explicit WinGet + UAC
 nt-deps -Install GitHubCLI -Apply          Optional private GitHub support
 nt-deps -Install Git -DownloadOnly -Apply  Download only to staging

 KALI LINUX AND KALI LINUX TERMINAL SHELL
 nt-kali -Check                             Check remote SSH availability
 nt-kali -Configure user@kali.example -Save  Save remote address only
 nt-kali -Connect user@000.000.0.0         SSH into EXISTING remote Kali
 nt-kali -Exec 'uname -a'                   Linux command on configured Kali
 nt-kali-wsl -Help                          Optional legacy local WSL mode
 nt-kali-shell                              Kali Linux terminal shell
 

GITHUB REMOTE REPOSITORIES
 github enter OWNER/REPO                   Show repository and remote files
 github enter OWNER/REPO -Path src         Browse remote folder
 github list OWNER                         List first 100 public repositories
 github download OWNER/REPO -DownloadZIP   Save source ZIP (never run code)
 github enter OWNER/PRIVATE -UseGitHubCLI  Authenticate via existing gh auth

WINDOWS FILE EXPLORER
 nt-explorer .                           Open current directory
 nt-explorer "A:\Games\Minecraft"          Open the specified folder
 nt-explorer "A:\Games\Minecraft\game.exe"  Show and select a specific file
 nt-explorer "A:\Games\Minecraft" -Select  Select directory in parent

PROJECT
 nt-version                              Show NT and actual PS engine versions
 nt-engine                               Show bundled runtime version/origin and path
 nt-releases owner/repository              Open GitHub releases
 NT-help                                 Display this complete reference

All native Microsoft PowerShell commands work normally.
'@ | Write-Host
    Write-Host 'Detected NT commands currently imported:' -ForegroundColor Cyan
    Get-Command -Name 'nt-*' -CommandType Function -ErrorAction SilentlyContinue |
        Sort-Object Name -Unique | Select-Object -ExpandProperty Name |
        Out-Host
}

function nt-explorer {
    <#
    .SYNOPSIS
        Opens an existing file system path in Windows File Explorer.
    .EXAMPLE
        nt-explorer "A:\Games\Minecraft"
    .EXAMPLE
        nt-explorer "A:\Games\Minecraft\game.exe"
    .EXAMPLE
        nt-explorer . -Select
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]$LiteralPath = '.',
        [switch]$Select
    )
    # No execution, permission changes, directory creation or path scanning.
    if ($env:OS -ne 'Windows_NT') {
        Write-Error 'nt-explorer requires Windows File Explorer.'
        return
    }
    $resolvedItem = $null
    try {
        $resolvedItem = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
        if ($resolvedItem.PSProvider.Name -ne 'FileSystem') {
            throw 'Only filesystem files and directories are supported.'
        }
        $resolved = $resolvedItem.FullName
        $selectItem = $Select.IsPresent -or (-not $resolvedItem.PSIsContainer)
        if ($selectItem) {
            $arguments = '/select,"{0}"' -f $resolved
        } else {
            $arguments = '"{0}"' -f $resolved
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $arguments -ErrorAction Stop
        Write-Host ('[NT EXPLORER] {0}: {1}' -f $(if ($selectItem) { 'Selected' } else { 'Opened' }), $resolved) -ForegroundColor Magenta
    }
    catch {
        Write-Error ('Explorer could not open this path: ' + $_.Exception.Message)
    }
}

function nt-check-disk {
    [CmdletBinding()]
    param()
    Get-PSDrive -PSProvider FileSystem | Select-Object Name,
        @{Name='FreeGB';Expression={[math]::Round($_.Free / 1GB, 2)}},
        @{Name='UsedGB';Expression={[math]::Round($_.Used / 1GB, 2)}} |
        Format-Table -AutoSize
}

function nt-run {
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$FilePath,
        [Parameter(Position=1, ValueFromRemainingArguments=$true)]
        [string[]]$ApplicationArguments
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-Error "Executable not found: $FilePath"; return
    }
    $resolved = (Resolve-Path -LiteralPath $FilePath).ProviderPath
    Write-Host "[NT RUN] $resolved" -ForegroundColor Cyan
    $started = Get-Date
    try {
        $options = @{
            FilePath = $resolved
            PassThru = $true
            Wait = $true
        }
        if ($null -ne $ApplicationArguments -and $ApplicationArguments.Count -gt 0) {
            $options['ArgumentList'] = $ApplicationArguments
        }
        $process = Start-Process @options
        # Preserve the native 32-bit exit status. PowerShell/.NET may show it as a signed int.
        $signedCode = [int]$process.ExitCode
        $unsignedCode = [BitConverter]::ToUInt32([BitConverter]::GetBytes($signedCode), 0)
        $hexCode = '0x{0:X8}' -f $unsignedCode
        $duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        Write-Host ('[NT RUN] PID: {0}; time: {1}s' -f $process.Id, $duration)
        Write-Host ('[NT RUN] Exit: {0} ({1})' -f $signedCode, $hexCode) -ForegroundColor $(if ($signedCode -eq 0) {'Green'} else {'Yellow'})
        if ($unsignedCode -eq 3221225477) {
            Write-Host '[NT RUN] STATUS_ACCESS_VIOLATION: invalid memory access.' -ForegroundColor Yellow
        }
        if ($signedCode -ne 0) {
            Write-Host '[NT RUN] Use nt-res "path-to-exe" -Restore for safe recovery choices.'
        }
        $global:NTPS8_LastRun = [pscustomobject]@{
            FilePath = $resolved; PID = $process.Id; ExitCode = $signedCode
            HexCode = $hexCode; Timestamp = Get-Date
        }
    }
    catch {
        Write-Error ('Failed to start process: ' + $_.Exception.Message)
    }
}


function nt-releases {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true,Position=0)][string]$Repository)
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Write-Error 'Use owner/repository (for example: NTMonTech/NT-PowerShell-8).'; return
    }
    $url = "https://github.com/$Repository/releases"
    Write-Host $url
    Start-Process $url
}

function prompt {
    $here = $executionContext.SessionState.Path.CurrentLocation.Path
    Write-Host 'NT PS8' -ForegroundColor Magenta -NoNewline
    Write-Host " $here" -ForegroundColor Gray -NoNewline
    return '> '
}

Export-ModuleMember -Function nt-version,nt-engine,nt-help,nt-explorer,nt-check-disk,nt-run,nt-releases,prompt
