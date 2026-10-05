function Invoke-NTPS8ElevatedScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptSource,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $powershell = Join-Path `
        $env:WINDIR `
        'System32\WindowsPowerShell\v1.0\powershell.exe'

    $diagnosticLog = 'C:\Windows\Temp\NTPS8_RuntimeBridge_Diagnostic.log'

    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 is not available.'
    }

    # Encode the trusted helper source as UTF-8 Base64.
    $scriptBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($ScriptSource)
    )

    # Do not pass an array through ConvertFrom-Json.
    # Store the two supported arguments explicitly.
    $argumentsObject = [ordered]@{
        Arg0 = if ($Arguments.Count -ge 1) {
            [string]$Arguments[0]
        }
        else {
            ''
        }

        Arg1 = if ($Arguments.Count -ge 2) {
            [string]$Arguments[1]
        }
        else {
            ''
        }
    }

    $argumentsJson = ConvertTo-Json `
        -InputObject $argumentsObject `
        -Compress

    $argumentsBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($argumentsJson)
    )

    # This code runs inside elevated Windows PowerShell 5.1.
    $command = @'
$ErrorActionPreference = 'Stop'

$diagnosticLog = 'C:\Windows\Temp\NTPS8_RuntimeBridge_Diagnostic.log'

try {
    New-Item `
        -ItemType Directory `
        -Force `
        -Path 'C:\Windows\Temp' |
        Out-Null

    Set-Content `
        -LiteralPath $diagnosticLog `
        -Value 'NTPS8 Runtime Bridge: elevated process started.' `
        -Encoding UTF8

    # Decode trusted helper source.
    $scriptSource = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__NTPS8_SCRIPT__')
    )

    Add-Content `
        -LiteralPath $diagnosticLog `
        -Value ('Script decoded. Length: ' + $scriptSource.Length) `
        -Encoding UTF8

    # Decode arguments.
    $argumentsJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__NTPS8_ARGS__')
    )

    Add-Content `
        -LiteralPath $diagnosticLog `
        -Value ('Arguments JSON: ' + $argumentsJson) `
        -Encoding UTF8

    $arguments = $argumentsJson | ConvertFrom-Json

    $arg0 = [string]$arguments.Arg0
    $arg1 = [string]$arguments.Arg1

    Add-Content `
        -LiteralPath $diagnosticLog `
        -Value ('Arg0: ' + $arg0) `
        -Encoding UTF8

    Add-Content `
        -LiteralPath $diagnosticLog `
        -Value ('Arg1: ' + $arg1) `
        -Encoding UTF8

    # Create the trusted helper as an in-memory ScriptBlock.
    $scriptBlock = [scriptblock]::Create($scriptSource)

    Add-Content `
        -LiteralPath $diagnosticLog `
        -Value 'ScriptBlock created.' `
        -Encoding UTF8

    # Execute the helper with its two validated arguments.
    & $scriptBlock $arg0 $arg1

    $lastExitCode = $LASTEXITCODE

    Add-Content `
        -LiteralPath $diagnosticLog `
        -Value ('Helper finished. LASTEXITCODE=' + $lastExitCode) `
        -Encoding UTF8

    if ($null -ne $lastExitCode) {
        exit ([int]$lastExitCode)
    }

    exit 0
}
catch {
    try {
        Add-Content `
            -LiteralPath $diagnosticLog `
            -Value ('ERROR: ' + $_.Exception.ToString()) `
            -Encoding UTF8
    }
    catch {
    }

    exit 1
}
'@

    # Insert Base64 payloads.
    $command = $command.Replace(
        '__NTPS8_SCRIPT__',
        $scriptBase64
    )

    $command = $command.Replace(
        '__NTPS8_ARGS__',
        $argumentsBase64
    )

    # Windows PowerShell -EncodedCommand expects UTF-16LE.
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )

    Remove-Item `
        -LiteralPath $diagnosticLog `
        -Force `
        -ErrorAction SilentlyContinue

    try {
        Write-Host '[NTPS8 Runtime] Requesting administrator approval (UAC)...' `
            -ForegroundColor Yellow

        $process = Start-Process `
            -FilePath $powershell `
            -ArgumentList @(
                '-NoLogo'
                '-NoProfile'
                '-ExecutionPolicy'
                'Bypass'
                '-EncodedCommand'
                $encodedCommand
            ) `
            -Verb RunAs `
            -PassThru `
            -ErrorAction Stop

        $process.WaitForExit()

        return [int]$process.ExitCode
    }
    catch {
        throw (
            'UAC was declined or elevated process could not start: ' +
            $_.Exception.Message
        )
    }
}

Export-ModuleMember `
    -Function Invoke-NTPS8ElevatedScript