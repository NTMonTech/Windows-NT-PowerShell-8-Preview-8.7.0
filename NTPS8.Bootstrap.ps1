# NT PowerShell 8 native Windows PowerShell bootstrap.
# This script is intended for Windows PowerShell 5.1 when pwsh.exe is unavailable.

param(
    [switch]$InstallPowerShell7,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

Write-Host '[PS8] Bootstrap dependency check (Windows PowerShell 5.1)' -ForegroundColor Cyan

$pwsh = Join-Path `
    $env:ProgramFiles `
    'PowerShell\7\pwsh.exe'

if ($Check) {
    if (Test-Path -LiteralPath $pwsh -PathType Leaf) {
        Write-Host '[PS8] PowerShell 7 is installed.' -ForegroundColor Green
        Write-Host ('[PS8] Path: ' + $pwsh)
        exit 0
    }

    Write-Host '[PS8] PowerShell 7 is not installed.' -ForegroundColor Yellow
    Write-Host '[PS8] Run NTPS8 Bootstrap with -InstallPowerShell7 to install it.'
    exit 1
}

if (-not $InstallPowerShell7) {
    Write-Host '[PS8] No installation requested.' -ForegroundColor Yellow
    Write-Host '[PS8] Use -Check to check PowerShell 7.'
    Write-Host '[PS8] Use -InstallPowerShell7 to request installation.'
    exit 0
}

Write-Host '[PS8] PowerShell 7 installation requested.' -ForegroundColor Yellow
Write-Host '[PS8] This action requires explicit administrator approval.' -ForegroundColor Yellow

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

if (-not $winget) {
    throw 'Windows Package Manager (winget) was not found.'
}

& $winget.Source `
    install `
    --id Microsoft.PowerShell `
    --exact `
    --source winget `
    --accept-source-agreements `
    --accept-package-agreements

if ($LASTEXITCODE -ne 0) {
    throw ('PowerShell 7 installation failed with exit code ' + $LASTEXITCODE)
}

Write-Host '[PS8] PowerShell 7 installation completed.' -ForegroundColor Green
Write-Host '[PS8] Restart NTPS8.'
