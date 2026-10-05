# NT PowerShell 8: real local Zsh shell using MSYS2 on Windows.
# This is not Kali Linux, WSL, a Linux distro, or a Linux tool bundle.
function Enter-NTKaliShell {
    [CmdletBinding()]
    param([string]$MSYS2Root = '')

    if ($env:OS -ne 'Windows_NT') {
        Write-Error 'This MSYS2-based integration is for Windows.'
        return
    }

    $roots = if ($MSYS2Root) {
        @($MSYS2Root)
    } else {
        @('A:\msys64', 'C:\msys64', "$env:USERPROFILE\msys64", 'A:\MSYS2', 'C:\MSYS2', 'D:\MSYS2', "$env:USERPROFILE\MSYS2")
    }

    $root = $null
    foreach ($candidate in $roots) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'msys2_shell.cmd') -PathType Leaf) {
            $root = $candidate
            break
        }
    }
    if (-not $root) {
        Write-Warning 'MSYS2 not found. Install from https://www.msys2.org/ and rerun nt-kali-shell.'
        Write-Host 'Example: nt-kali-shell -MSYS2Root A:\msys64'
        return
    }

    $zsh = Join-Path $root 'usr\bin\zsh.exe'
    if (-not (Test-Path -LiteralPath $zsh -PathType Leaf)) {
        Write-Warning 'Zsh is not installed. Open MSYS2 MSYS and run: pacman -S --needed zsh'
        return
    }

    Write-Host 'NT PS8: entering MSYS2 Zsh (not a full Kali Linux installation).' -ForegroundColor Magenta
    Write-Host 'Type exit to return to NT PowerShell 8.' -ForegroundColor DarkGray
    $launcher = Join-Path $root 'msys2_shell.cmd'
    & $launcher -defterm -no-start -msys -shell zsh
}

Set-Alias -Name nt-kali-shell -Value Enter-NTKaliShell
Export-ModuleMember -Function Enter-NTKaliShell -Alias nt-kali-shell
