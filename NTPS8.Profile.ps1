# NT PowerShell 8 memory-architecture startup profile.
$ErrorActionPreference = 'Continue'

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
}

# Modules are already loaded by NTPS8.exe from encrypted .bin files.
# Do not import physical .psm1 files here.

if (Get-Command Set-NTPS8PurpleTheme -ErrorAction SilentlyContinue) {
    try {
        Set-NTPS8PurpleTheme
    }
    catch {
    }
}

Write-Host ''
Write-Host '=================================================' -ForegroundColor DarkMagenta
Write-Host '   Windows PowerShell 8 - GitHub Downloader + Remote Kali Linux Terminal Shell | Preview 8.7.0' -ForegroundColor Magenta
Write-Host '   Developer: Net Tweaking Studio' -ForegroundColor Red
Write-Host '=================================================' -ForegroundColor DarkMagenta
Write-Host ('   Powered from PowerShell 7 engine: ' + $PSVersionTable.PSVersion.ToString())
Write-Host '   Independent NT project; Not Official Microsoft PowerShell 8.' -ForegroundColor DarkYellow
Write-Host '   Type NT-help for all NT commands, including github and remote Kali.' -ForegroundColor Cyan
Write-Host '   Startup is read-only: install/download only after explicit user request and consent.' -ForegroundColor Green

try {
    $status = @(Get-NTDependencyStatus | Where-Object { -not $_.Installed })

    if ($status.Count -gt 0) {
        Write-Host (
            '   Missing components: ' +
            (($status | ForEach-Object { $_.Component }) -join ', ')
        ) -ForegroundColor Yellow

        Write-Host '   Run nt-deps -Check; nothing is installed automatically.' -ForegroundColor DarkYellow
    }
}
catch {
    Write-Host '   Dependency status is currently unavailable.' -ForegroundColor Yellow
}

Write-Host ''

# NTPS8 startup directory
Set-Location -LiteralPath 'C:\Windows\System32'

# NTPS8 custom prompt
function global:prompt {
    $purple = $PSStyle.Foreground.FromRgb(155, 75, 210)
    $white  = $PSStyle.Foreground.White
    $reset  = $PSStyle.Reset
    $path   = (Get-Location).Path

    return "${purple}PS8 ${reset}${white}${path}${reset}${white}> ${reset}"
}
