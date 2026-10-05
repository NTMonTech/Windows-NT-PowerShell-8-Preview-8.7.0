# Internal elevated helper. Executed only AFTER the user types INSTALL and accepts Windows UAC.
# This script intentionally accepts NO arbitrary URL, path to executable, package ID, or command.
param(
    [Parameter(Mandatory=$true)][ValidateSet('PowerShell7','Git','GitHubCLI','Python310')][string]$Component,
    [Parameter(Mandatory=$true)][string]$LogFile
)
$ErrorActionPreference = 'Stop'
$allowlist = @{
    'PowerShell7' = 'Microsoft.PowerShell'
    'Git' = 'Git.Git'
    'GitHubCLI' = 'GitHub.cli'
    'Python310' = 'Python.Python.3.10'
}
$id = $allowlist[$Component]
if (-not $id) { throw 'Unknown dependency; refusing installation.' }
$exit = 1
$transcribing = $false
try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $LogFile -Parent) | Out-Null
    Start-Transcript -Path $LogFile -Force -ErrorAction Stop | Out-Null
    $transcribing = $true
    Write-Host ("[NT DEPS ADMIN] Approved exact package: {0}" -f $id)
    $winget = Get-Command winget.exe -ErrorAction Stop
    Write-Host '[NT DEPS ADMIN] Checking official WinGet package before installation...'
    & $winget.Source show --id $id --exact --source winget --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw 'WinGet show failed; installation blocked.' }
    Write-Host '[NT DEPS ADMIN] WinGet installation started; hash validation remains enabled.'
    & $winget.Source install --id $id --exact --source winget --accept-source-agreements --accept-package-agreements
    $exit = [int]$LASTEXITCODE
    Write-Host ("[NT DEPS ADMIN] WinGet exit code: {0}" -f $exit)
} catch {
    Write-Host ('[NT DEPS ADMIN ERROR] ' + $_.Exception.Message)
    $exit = 1
} finally {
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch {} }
}
exit $exit
