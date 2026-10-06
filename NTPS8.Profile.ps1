$ErrorActionPreference = 'Continue'


try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
}
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Module.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Recovery.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Reinstall.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Deps.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Kali.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.KaliRemote.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.GitHub.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Theme.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
Set-NTPS8PurpleTheme
Import-Module (Join-Path $PSScriptRoot 'NTPS8.Unlock.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop

Write-Host ''

Write-Host '=================================================' `
    -ForegroundColor DarkMagenta

Write-Host '   Windows PowerShell 8 - GitHub Downloader + Remote Kali Linux Terminal Shell | Preview 8.7.0' `
    -ForegroundColor Magenta

Write-Host '   Developer: Net Tweaking Studio' `
    -ForegroundColor Red

Write-Host '=================================================' `
    -ForegroundColor DarkMagenta

$PowerShellVersion = $PSVersionTable.PSVersion.ToString()

Write-Host (
    '   Powered from PowerShell 7 engine: ' +
    $PowerShellVersion
)

Write-Host '   Independent NT project; Not Official Microsoft PowerShell 8.' `
    -ForegroundColor DarkYellow

Write-Host '   Type NT-help for all NT commands, including github and remote Kali.' `
    -ForegroundColor Cyan

Write-Host '   Startup is read-only: install/download only after explicit user request and consent.' `
    -ForegroundColor Green


try {

    if (Get-Command Get-NTDependencyStatus -ErrorAction SilentlyContinue) {

        $status = @(
            Get-NTDependencyStatus |
                Where-Object {
                    -not $_.Installed
                }
        )


        if ($status.Count -gt 0) {

            $MissingComponents = @(
                $status |
                    ForEach-Object {
                        $_.Component
                    }
            )


            Write-Host (
                '   Missing components: ' +
                ($MissingComponents -join ', ')
            ) -ForegroundColor Yellow


            Write-Host '   Run nt-deps -Check; nothing is installed automatically.' `
                -ForegroundColor DarkYellow
        }
    }
    else {

        Write-Host '   Dependency status is currently unavailable.' `
            -ForegroundColor Yellow
    }
}
catch {

    Write-Host '   Dependency status is currently unavailable.' `
        -ForegroundColor Yellow
}


Write-Host ''


# Windows PowerShell 8 startup directory

Set-Location -LiteralPath 'C:\Windows\System32'


# Windows PowerShell 8 custom prompt

function global:prompt {

    $purple = $PSStyle.Foreground.FromRgb(155, 75, 210)
    $white = $PSStyle.Foreground.White
    $reset = $PSStyle.Reset
    $path = (Get-Location).Path


    return (
        "${purple}PS8 " +
        "${reset}${white}${path}" +
        "${reset}${white}> " +
        "${reset}"
    )
}