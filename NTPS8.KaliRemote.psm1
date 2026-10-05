# NT PowerShell 8 0.7: remote, pre-existing Linux/Kali host via Windows OpenSSH.
# No Linux distribution download, auto server discovery, credentials storage or key bypass.
Set-StrictMode -Version Latest
$script:NTKaliRemote = $null
$script:NTKaliRemotePort = 22

function Assert-NTKaliRemote {
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -notmatch '^[A-Za-z_][A-Za-z0-9_.-]{0,63}@[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' -or $Target -match '[\r\n]') {
        throw 'Use user@hostname or user@IPv4 for a Kali host you have access to. No commands or URLs allowed.'
    }
    return $Target
}

function Get-NTKaliRemoteConfigRoot {
    if (Test-Path -LiteralPath 'C:\' -PathType Container) { return 'C:\PowerShell_8_Files\NTPS8_Settings' }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'NTPS8') }
    return (Join-Path $HOME '.ntps8')
}

function nt-kali {
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [switch]$Check,
        [string]$Connect,
        [string]$Configure,
        [switch]$Save,
        [string]$Exec,
        [ValidateRange(1,65535)][int]$Port=22,
        [string]$IdentityFile,
        [switch]$Help
    )
    if ($Help) {
        @'
REMOTE KALI (no local Kali OS / WSL installation)
 nt-kali -Check                          Verify local SSH, show configured server
 nt-kali -Configure user@kali.example -Save
                                          Save only hostname, username and port
 nt-kali -Connect user@kali.example       Open REAL remote SSH Bash; exit returns
 nt-kali                                 Connect to saved/configured server
 nt-kali -Exec 'uname -a'                 Execute one command on saved host
 nt-kali -Connect user@192.168.1.3 -Port 2222 -IdentityFile 'C:\Keys\id_ed25519'
 nt-kali-wsl -Help                        Optional LEGACY local WSL mode (separate)
 nt-kali-shell                            The Kali Linux terminal shell itself.
Set up the Kali host and SSH server yourself. Credentials are handled by ssh.exe,
never by NT PS8. Verify SSH host fingerprints before accepting them.
'@ | Write-Host
        return
    }
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { $ssh = Get-Command ssh -ErrorAction SilentlyContinue }
    if (-not $ssh) { throw 'OpenSSH client missing. Install Windows OpenSSH Client optional feature; no Kali OS is needed.' }
    $configPath = Join-Path (Get-NTKaliRemoteConfigRoot) 'remote_kali.json'
    if ($Configure) { $script:NTKaliRemote = Assert-NTKaliRemote $Configure; $script:NTKaliRemotePort = $Port }
    elseif ($Connect) { $script:NTKaliRemote = Assert-NTKaliRemote $Connect; $script:NTKaliRemotePort = $Port }
    elseif (-not $script:NTKaliRemote -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $script:NTKaliRemote = Assert-NTKaliRemote $saved.Target
        if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = [int]$saved.Port }
        $script:NTKaliRemotePort = $Port
    }
    if (-not $PSBoundParameters.ContainsKey('Port') -and -not $Configure -and -not $Connect) { $Port = $script:NTKaliRemotePort }
    if ($IdentityFile) {
        if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { throw 'SSH identity file not found.' }
        $IdentityFile = (Resolve-Path -LiteralPath $IdentityFile).ProviderPath
    }
    if ($Save) {
        if (-not $script:NTKaliRemote) { throw 'Specify -Configure user@host or -Connect user@host with -Save.' }
        $parent = Split-Path -Parent $configPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        # Never store passwords or private key contents.
        @{Target=$script:NTKaliRemote; Port=$Port} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        Write-Host ('[KALI SSH] Server address saved to ' + $configPath) -ForegroundColor Magenta
    }
    if ($Check) {
        Write-Host '[KALI SSH] Windows OpenSSH client: available' -ForegroundColor Green
        Write-Host ('[KALI SSH] Configured target: ' + $(if ($script:NTKaliRemote) {$script:NTKaliRemote} else {'none'}))
        Write-Host '[KALI SSH] Remote system needs sshd running and network access; no local Kali installation is needed.'
        return
    }
    if (-not $script:NTKaliRemote) {
        Write-Host '[KALI SSH] No server configured. Use: nt-kali -Connect user@YOUR-KALI-IP' -ForegroundColor Yellow
        return
    }
    $sshArgs = @('-p', "$Port", '-o', 'StrictHostKeyChecking=ask', '-o', 'ConnectTimeout=15')
    if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile) }
    if ($Configure -and -not $Exec -and -not $Connect) {
        Write-Host '[KALI SSH] Configured; connect with: nt-kali' -ForegroundColor Magenta
        return
    }
    Write-Host ('[KALI SSH] Connecting to ' + $script:NTKaliRemote + ':' + $Port) -ForegroundColor Magenta
    Write-Host '[KALI SSH] Check the fingerprint on first connection. Your login stays inside ssh.exe.' -ForegroundColor Gray
    if ($PSBoundParameters.ContainsKey('Exec')) {
        # Transfer UTF-8 user command as base64: avoids nested shell quoting bugs.
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Exec))
        $remoteCmd = "printf '%s' '$encoded' | base64 -d | /bin/bash"
        & $ssh.Source @sshArgs $script:NTKaliRemote $remoteCmd
    }
    else {
        Write-Host '[KALI SSH] Remote terminal. Type exit to return to NT PS8.' -ForegroundColor Gray
        & $ssh.Source @sshArgs '-t' $script:NTKaliRemote '/bin/bash -l'
    }
    $global:LASTEXITCODE = [int]$LASTEXITCODE
    Write-Host ('[KALI SSH] Remote SSH session ended, exit code: ' + $global:LASTEXITCODE)
}

Export-ModuleMember -Function nt-kali
