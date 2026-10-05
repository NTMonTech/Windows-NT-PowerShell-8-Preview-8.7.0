# Internal Windows elevated helper; called only after typing INSTALL and accepting UAC.
# Uses the official installed wsl.exe and the fixed kali-linux distribution identifier.
param(
    [Parameter(Mandatory=$true)][string]$Location,
    [Parameter(Mandatory=$true)][string]$LogFile
)
$ErrorActionPreference = 'Stop'
$exitCode = 1
try {
    if ($Location -notmatch '^[A-Za-z]:\\[^\\].+' -or $Location -match '["\r\n]') {
        throw 'Invalid target directory; refusing unsafe location.'
    }
    $wsl = Join-Path $env:WINDIR 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl -PathType Leaf)) { throw 'Official Windows wsl.exe not available.' }
    $parent = Split-Path -Path $LogFile -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    function Write-NTKaliLog([string]$Line) {
        Write-Host $Line
        Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
    }
    Write-NTKaliLog ('[NT KALI] ' + (Get-Date -Format 'o') + ' Official WSL setup started')
    Write-NTKaliLog '[NT KALI] Distribution: kali-linux'
    Write-NTKaliLog ('[NT KALI] Location: ' + $Location)
    # --no-launch prevents automatic first-time user setup in the elevated window.
    # Never silently retry WITHOUT --location; that could install on an almost-full C:.
    & $wsl --install --distribution kali-linux --location $Location --no-launch 2>&1 |
        ForEach-Object { Write-NTKaliLog ([string]$_) }
    $exitCode = [int]$LASTEXITCODE
    Write-NTKaliLog ('[NT KALI] wsl.exe exit code: ' + $exitCode)
    if ($exitCode -ne 0) {
        Write-NTKaliLog '[NT KALI] Check WSL version/support for --location. Nothing will be reinstalled on C: automatically.'
    }
} catch {
    $message = '[NT KALI ERROR] ' + $_.Exception.Message
    Write-Host $message -ForegroundColor Red
    try { Add-Content -LiteralPath $LogFile -Value $message -Encoding UTF8 } catch { }
    $exitCode = 1
}
exit $exitCode
