# NT PowerShell 8 Recovery Engine 0.2 - independent extension, powered by PowerShell 7.
# No network binary substitution. No modifications without -Apply and typed consent.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NTStore {
    param([string]$Store)
    if ($Store) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Store) }
    if ($env:NTPS8_BACKUP_ROOT) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($env:NTPS8_BACKUP_ROOT)
    }
    if (Test-Path -LiteralPath 'Ñ:\' -PathType Container) { return 'C:\PowerShell_8_Files\NTPS8_Recovery' }
    return (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'NTPS8_Recovery')
}

function Get-NTAbsolute {
    param([Parameter(Mandatory)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-NTReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $entry = Get-Item -LiteralPath $current -Force
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse point / symlink path: $current"
            }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent -or $parent.FullName -eq $current) { break }
        $current = $parent.FullName
    }
}

function Assert-NTNormalTree {
    param([Parameter(Mandatory)][string]$Path)
    Test-NTReparsePath -Path $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        foreach ($entry in (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Directory includes a symlink/reparse point: $($entry.FullName)"
            }
        }
    }
}

function Assert-NTRelative {
    param([Parameter(Mandatory)][string]$Relative)
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or
        $Relative -match '[\x00-\x1f:]' -or $Relative -eq '.' -or $Relative -eq '') {
        throw "Unsafe relative path in manifest: $Relative"
    }
}

function Get-NTFileInventory {
    param([Parameter(Mandatory)][string]$Path)
    $root = Get-NTAbsolute $Path
    if (Test-Path -LiteralPath $root -PathType Leaf) {
        return [pscustomobject]@{ Source = $root; Relative = [IO.Path]::GetFileName($root) }
    }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Source = $_.FullName; Relative = [IO.Path]::GetRelativePath($root, $_.FullName) }
    })
    return $files
}

function Get-NTFreeSpace {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if (-not $driveRoot) { throw "Unable to determine drive: $Path" }
    return ([IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace
}

function Assert-NTSpace {
    param([string]$Path,[long]$Required)
    $available = Get-NTFreeSpace $Path
    $need = [math]::Max(4MB, [math]::Ceiling($Required * 1.10))
    if ($available -lt $need) {
        throw "Insufficient space on $([IO.Path]::GetPathRoot($Path)). Need about $need bytes; available $available bytes. Choose another disk via -Store or `$env:NTPS8_BACKUP_ROOT."
    }
}

function New-NTUniqueFolder {
    param([string]$Root,[string]$Prefix)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $dir = Join-Path $Root ('{0}_{1}_{2}' -f $Prefix, (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss'), [guid]::NewGuid().ToString('N').Substring(0,10))
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    return $dir
}

function nt-scan {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Path, [switch]$Deep)
    $target = Get-NTAbsolute $Path
    if (-not (Test-Path -LiteralPath $target)) { throw "Not found: $target" }
    Assert-NTNormalTree $target
    $kind = if (Test-Path -LiteralPath $target -PathType Leaf) { 'File' } else { 'Directory' }
    $files = @(Get-NTFileInventory $target)
    [long]$bytes = 0
    foreach ($file in $files) { $bytes += (Get-Item -LiteralPath $file.Source).Length }
    Write-Host "[NT SCAN] $target" -ForegroundColor Cyan
    Write-Host "Type: $kind; files: $($files.Count); total bytes: $bytes"
    if ($Deep -or $kind -eq 'File') {
        foreach ($file in $files) {
            $hash = (Get-FileHash -LiteralPath $file.Source -Algorithm SHA256).Hash
            Write-Host ("SHA256  {0}  {1}" -f $hash, $file.Relative)
        }
    }
    if ($kind -eq 'File' -and [IO.Path]::GetExtension($target) -in @('.exe','.dll','.msi','.ps1')) {
        if (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue) {
            $sign = Get-AuthenticodeSignature -LiteralPath $target
            Write-Host "Signature: $($sign.Status)"
            if ($sign.SignerCertificate) { Write-Host "Signer: $($sign.SignerCertificate.Subject)" }
        }
    }
    Write-Host 'Note: a SHA-256 hash alone cannot establish whether a file is healthy.' -ForegroundColor Yellow
    [pscustomobject]@{ Path=$target; Type=$kind; Files=$files.Count; Bytes=$bytes }
}

function nt-snapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Path,[string]$Store)
    $target = Get-NTAbsolute $Path
    if (-not (Test-Path -LiteralPath $target)) { throw "Not found: $target" }
    Assert-NTNormalTree $target
    $root = Get-NTStore $Store
    Test-NTReparsePath -Path $root
    $targetWithSeparator = $target.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($root.StartsWith($targetWithSeparator,[StringComparison]::OrdinalIgnoreCase) -or
        $root.Equals($target,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Snapshot store cannot be inside the target (recursive backup risk).'
    }
    $files = @(Get-NTFileInventory $target)
    [long]$bytes = 0
    foreach ($item in $files) { $bytes += (Get-Item -LiteralPath $item.Source).Length }
    Assert-NTSpace -Path $root -Required $bytes
    $snap = New-NTUniqueFolder -Root $root -Prefix 'snapshot'
    $data = Join-Path $snap 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $manifestFiles = @()
    foreach ($file in $files) {
        Assert-NTRelative $file.Relative
        $dest = Join-Path $data $file.Relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
        Copy-Item -LiteralPath $file.Source -Destination $dest -ErrorAction Stop
        $originalHash = (Get-FileHash -LiteralPath $file.Source -Algorithm SHA256).Hash
        $copiedHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($originalHash -ne $copiedHash) { throw "Copy verification failed: $($file.Relative)" }
        $manifestFiles += [pscustomobject]@{
            Relative=$file.Relative; SHA256=$copiedHash; Length=(Get-Item -LiteralPath $dest).Length
        }
    }
    $kind = if (Test-Path -LiteralPath $target -PathType Leaf) { 'File' } else { 'Directory' }
    $dirs = @()
    if ($kind -eq 'Directory') {
        foreach ($dir in (Get-ChildItem -LiteralPath $target -Directory -Recurse -Force)) {
            $rel = [IO.Path]::GetRelativePath($target,$dir.FullName)
            Assert-NTRelative $rel
            $dirs += $rel
            [IO.Directory]::CreateDirectory((Join-Path $data $rel)) | Out-Null
        }
    }
    $manifest = [ordered]@{
        FormatVersion=1; Type='NTPS8Snapshot'; Target=$target; Kind=$kind
        CreatedUtc=(Get-Date).ToUniversalTime().ToString('o'); Files=@($manifestFiles); Directories=@($dirs)
    }
    $json = $manifest | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $snap 'manifest.json'),$json,[Text.UTF8Encoding]::new($false))
    Write-Host "[NT SNAPSHOT] $snap" -ForegroundColor Green
    [pscustomobject]@{Snapshot=$snap;Target=$target;Files=$manifestFiles.Count;Bytes=$bytes}
}

function Get-NTManifest {
    param([Parameter(Mandatory)][string]$Snapshot)
    $folder = Get-NTAbsolute $Snapshot
    Assert-NTNormalTree $folder
    $manifestFile = Join-Path $folder 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { throw "Snapshot manifest missing: $manifestFile" }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $manifest -or
        $null -eq $manifest.PSObject.Properties['Files'] -or
        $null -eq $manifest.PSObject.Properties['Directories']) {
        throw 'Incomplete snapshot manifest.'
    }
    if ($manifest.FormatVersion -ne 1 -or $manifest.Type -ne 'NTPS8Snapshot' -or
        $manifest.Kind -notin @('File','Directory')) {
        throw 'Unsupported snapshot manifest.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest.Files) {
        Assert-NTRelative $entry.Relative
        if (-not $seen.Add([string]$entry.Relative)) { throw 'Duplicate filename in snapshot manifest.' }
        if ($entry.SHA256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Invalid SHA-256 in manifest.' }
    }
    foreach ($dir in $manifest.Directories) { Assert-NTRelative ([string]$dir) }
    return [pscustomobject]@{ Folder=$folder; Data=(Join-Path $folder 'data'); Manifest=$manifest }
}

function nt-verify {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Snapshot)
    $snap = Get-NTManifest $Snapshot
    $failed = @()
    $count = 0
    foreach ($entry in $snap.Manifest.Files) {
        $path = Join-Path $snap.Data $entry.Relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failed += $entry.Relative; continue }
        $file = Get-Item -LiteralPath $path -Force
        if ($file.Length -ne [long]$entry.Length -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) {
            $failed += $entry.Relative
        }
        $count++
    }
    $valid = $failed.Count -eq 0
    Write-Host "[NT VERIFY] $($snap.Folder): $valid" -ForegroundColor $(if ($valid) {'Green'} else {'Red'})
    if (-not $valid) { Write-Warning ("Failed files: " + ($failed -join ', ')) }
    [pscustomobject]@{ Valid=$valid; Snapshot=$snap.Folder; Verified=$count; Failed=@($failed) }
}

function Get-NTLatestSnapshots {
    param([string]$Target,[string]$Store)
    $root = Get-NTStore $Store
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $match = @()
    foreach ($folder in (Get-ChildItem -LiteralPath $root -Directory -Filter 'snapshot_*' -ErrorAction SilentlyContinue)) {
        try {
            $manifestPath = Join-Path $folder.FullName 'manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
            $meta = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($meta.Type -eq 'NTPS8Snapshot' -and $meta.Target -eq $Target) { $match += $folder.FullName }
        } catch { continue }
    }
    return @($match | Sort-Object -Descending | Select-Object -First 5)
}

function nt-compare {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Path,[Parameter(Mandatory)][string]$Snapshot)
    $target = Get-NTAbsolute $Path
    $snap = Get-NTManifest $Snapshot
    $verified = nt-verify $snap.Folder
    if (-not $verified.Valid) { throw 'Backup verification failed. No repair should use it.' }
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $snap.Manifest.Files) {
        $dest = if ($snap.Manifest.Kind -eq 'File') { $target } else { Join-Path $target $entry.Relative }
        [void]$found.Add([string]$entry.Relative)
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $status='MISSING' }
        elseif ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $entry.SHA256) { $status='MATCH' }
        else { $status='CHANGED' }
        [pscustomobject]@{ Status=$status; Relative=$entry.Relative; Target=$dest }
    }
    if ($snap.Manifest.Kind -eq 'Directory' -and (Test-Path -LiteralPath $target -PathType Container)) {
        Assert-NTNormalTree $target
        foreach ($item in (Get-NTFileInventory $target)) {
            if (-not $found.Contains([string]$item.Relative)) {
                [pscustomobject]@{ Status='EXTRA_NOT_DELETED';Relative=$item.Relative; Target=$item.Source }
            }
        }
    }
}

function nt-res {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,Position=0)][string]$Path,
        [switch]$Restore,
        [string]$From,
        [string]$ExpectedSHA256,
        [switch]$AllowAlternateTarget,
        [string]$Store,
        [switch]$Apply
    )
    $target = Get-NTAbsolute $Path
    $exists = Test-Path -LiteralPath $target
    if ($exists) { $null = nt-scan -Path $target }
    else { Write-Warning "File/directory missing: $target. Recovery requires a known-good source." }
    if (-not $Restore) {
        Write-Host 'Use: nt-res "path" -Restore [-From "snapshot-or-file"] [-Apply]'
        return
    }
    if (-not $From) {
        Write-Host '[NT RESTORE] No source specified. Recent matching snapshots:' -ForegroundColor Cyan
        $matches = @(Get-NTLatestSnapshots -Target $target -Store $Store)
        if ($matches.Count -eq 0) { Write-Host 'No known snapshots. Use a verified backup or official application repair.' }
        else { $matches | ForEach-Object { Write-Host "  $_" } }
        Write-Host 'Use nt-compare "path" -Snapshot "snapshot-folder" to inspect changes.'
        Write-Host 'Use nt-res "path" -Restore -From "snapshot-folder" to PREVIEW.'
        Write-Host 'Add -Apply ONLY after checking the source, destination and free disk space.'
        Write-Host 'For an EXE with no clean backup: nt-winget-repair -Id Exact.Package.Id'
        return
    }
    $source = Get-NTAbsolute $From
    $manifestPath = Join-Path $source 'manifest.json'
    $usingSnapshot = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $items = @()
    $kind = ''
    if ($usingSnapshot) {
        $snap = Get-NTManifest $source
        $check = nt-verify $snap.Folder
        if (-not $check.Valid) { throw 'Snapshot corrupted; restoration aborted.' }
        $kind = $snap.Manifest.Kind
        if ($snap.Manifest.Target -ne $target -and -not $AllowAlternateTarget) {
            throw "Snapshot belongs to '$($snap.Manifest.Target)', not '$target'. Add -AllowAlternateTarget only if deliberate."
        }
        foreach ($entry in $snap.Manifest.Files) {
            $src = Join-Path $snap.Data $entry.Relative
            $dest = if ($kind -eq 'File') { $target } else { Join-Path $target $entry.Relative }
            $items += [pscustomobject]@{Relative=$entry.Relative;Source=$src;Destination=$dest;SHA256=$entry.SHA256}
        }
    }
    elseif (Test-Path -LiteralPath $source -PathType Leaf) {
        if (-not $ExpectedSHA256 -or $ExpectedSHA256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'For a standalone source file, supply -ExpectedSHA256 using a trusted external reference.'
        }
        Assert-NTNormalTree $source
        $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSHA256.ToUpperInvariant()) { throw 'Source file SHA-256 differs from expected trusted hash.' }
        $kind = 'File'
        $items += [pscustomobject]@{Relative=[IO.Path]::GetFileName($target);Source=$source;Destination=$target;SHA256=$actual}
    }
    else { throw 'Directory source must be an NT snapshot, or use a single verified source file.' }
    if ($exists) {
        Assert-NTNormalTree $target
        if ($kind -eq 'File' -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Cannot restore a file onto a directory.' }
        if ($kind -eq 'Directory' -and -not (Test-Path -LiteralPath $target -PathType Container)) { throw 'Cannot restore a directory onto a file.' }
    }
    $changes = @()
    $missingDirs = @()
    if ($usingSnapshot -and $kind -eq 'Directory') {
        foreach ($dirName in $snap.Manifest.Directories) {
            $directory = Join-Path $target ([string]$dirName)
            Test-NTReparsePath $directory
            if (Test-Path -LiteralPath $directory -PathType Leaf) { throw "File blocks expected folder: $directory" }
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $missingDirs += $directory }
        }
    }
    foreach ($entry in $items) {
        Test-NTReparsePath $entry.Destination
        $has = Test-Path -LiteralPath $entry.Destination -PathType Leaf
        if ($has -and (Get-FileHash -LiteralPath $entry.Destination -Algorithm SHA256).Hash -eq $entry.SHA256) { continue }
        if (Test-Path -LiteralPath $entry.Destination -PathType Container) { throw "Directory would be overwritten by a file: $($entry.Destination)" }
        $changes += [pscustomobject]@{Relative=$entry.Relative;Source=$entry.Source;Destination=$entry.Destination;SHA256=$entry.SHA256;Existed=$has}
    }
    Write-Host ("[NT RESTORE] Source: {0}; files to restore: {1}; missing folders: {2}" -f $source,$changes.Count,$missingDirs.Count) -ForegroundColor Cyan
    foreach ($change in ($changes | Select-Object -First 50)) {
        Write-Host ("  {0}: {1}" -f $(if ($change.Existed) {'REPLACE'} else {'CREATE'}),$change.Destination)
    }
    if ($changes.Count -gt 50) { Write-Host "  ...and $($changes.Count - 50) more" }
    Write-Host 'Other files in the target folder will NOT be deleted.'
    if (-not $Apply) { Write-Host 'PREVIEW ONLY. Add -Apply to restore.' -ForegroundColor Yellow; return }
    if ($changes.Count -eq 0 -and $missingDirs.Count -eq 0) { Write-Host 'Target already matches supplied backup.'; return }
    $answer = Read-Host 'Type RESTORE to change the listed files'
    if ($answer -cne 'RESTORE') { Write-Host 'Cancelled; no changes made.'; return }
    # The old versions of files to replace are secured on a separate recovery store.
    $storeRoot = Get-NTStore $Store
    if ($kind -eq 'Directory' -and
        ($storeRoot.Equals($target,[StringComparison]::OrdinalIgnoreCase) -or
         $storeRoot.StartsWith(($target.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase))) {
        throw 'The rollback store must NOT be inside the directory being repaired.'
    }
    # Staging happens beside each destination. Check free space on destination disks.
    foreach ($change in $changes) {
        Assert-NTSpace -Path $change.Destination -Required (Get-Item -LiteralPath $change.Source).Length
    }
    $rollbackBytes = [long]0
    $writeBytes = [long]0
    foreach ($change in $changes) {
        $writeBytes += (Get-Item -LiteralPath $change.Source).Length
        if ($change.Existed) { $rollbackBytes += (Get-Item -LiteralPath $change.Destination).Length }
    }
    Assert-NTSpace -Path $storeRoot -Required $rollbackBytes
    $rollback = New-NTUniqueFolder -Root $storeRoot -Prefix 'restore'
    $originals = Join-Path $rollback 'original'
    [IO.Directory]::CreateDirectory($originals) | Out-Null
    $record = @()
    foreach ($change in $changes) {
        if ($change.Existed) {
            $oldDest = Join-Path $originals $change.Relative
            [IO.Directory]::CreateDirectory((Split-Path -Parent $oldDest)) | Out-Null
            Copy-Item -LiteralPath $change.Destination -Destination $oldDest -ErrorAction Stop
            $oldHash = (Get-FileHash -LiteralPath $change.Destination -Algorithm SHA256).Hash
            if ((Get-FileHash -LiteralPath $oldDest -Algorithm SHA256).Hash -ne $oldHash) { throw 'Pre-restore backup verification failed.' }
        } else { $oldHash = $null }
        $record += [pscustomobject]@{ Relative=$change.Relative; Destination=$change.Destination; Existed=$change.Existed; OldSHA256=$oldHash; InstalledSHA256=$change.SHA256 }
    }
    [IO.File]::WriteAllText((Join-Path $rollback 'operation.json'),(
        [ordered]@{FormatVersion=1;Type='NTPS8Restore';Target=$target;Kind=$kind;Entries=@($record);CreatedDirs=@($missingDirs)} | ConvertTo-Json -Depth 10
    ),[Text.UTF8Encoding]::new($false))
    Write-Host "[NT RESTORE] Rollback prepared: $rollback" -ForegroundColor Yellow
    $completed = @()
    try {
        foreach ($dir in $missingDirs) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
        foreach ($change in $changes) {
            $parent = Split-Path -Parent $change.Destination
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            $staged = Join-Path $parent ('.ntps8_' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Copy-Item -LiteralPath $change.Source -Destination $staged -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $change.SHA256) { throw 'Staged copy hash mismatch.' }
                # Move within the same filesystem. Existing destination was already backed up.
                $completed += $change
                Move-Item -LiteralPath $staged -Destination $change.Destination -Force -ErrorAction Stop
            } finally {
                if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force }
            }
            if ((Get-FileHash -LiteralPath $change.Destination -Algorithm SHA256).Hash -ne $change.SHA256) {
                throw "Post-restore hash mismatch: $($change.Destination)"
            }
        }
    }
    catch {
        $errorText = $_.Exception.Message
        # Best-effort immediate rollback for already completed replacements.
        foreach ($change in $completed) {
            try {
                if ($change.Existed) {
                    Copy-Item -LiteralPath (Join-Path $originals $change.Relative) -Destination $change.Destination -Force
                } else {
                    Remove-Item -LiteralPath $change.Destination -Force -ErrorAction SilentlyContinue
                }
            } catch { Write-Warning "Automatic rollback failed for $($change.Destination)" }
        }
        foreach ($dir in ($missingDirs | Sort-Object Length -Descending)) {
            try { if (Test-Path -LiteralPath $dir -PathType Container) { [IO.Directory]::Delete($dir,$false) } } catch { }
        }
        throw "Restore failed: $errorText. Rollback files are located at $rollback"
    }
    Write-Host "[NT RESTORE] SUCCESS. Saved rollback: $rollback" -ForegroundColor Green
    [pscustomobject]@{Repaired=$changes.Count;Rollback=$rollback;Target=$target}
}

function nt-rollback {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Operation,[switch]$Apply)
    $root = Get-NTAbsolute $Operation
    Assert-NTNormalTree $root
    $op = Join-Path $root 'operation.json'
    if (-not (Test-Path -LiteralPath $op -PathType Leaf)) { throw 'operation.json not found.' }
    $meta = Get-Content -LiteralPath $op -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $meta -or $null -eq $meta.PSObject.Properties['Entries'] -or
        $null -eq $meta.PSObject.Properties['CreatedDirs']) { throw 'Incomplete rollback operation.' }
    if ($meta.Type -ne 'NTPS8Restore' -or $meta.FormatVersion -ne 1) { throw 'Not a valid NT restore operation.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $meta.Entries) {
        Assert-NTRelative $item.Relative
        if (-not $seen.Add([string]$item.Relative)) { throw 'Duplicate entries in operation.' }
        $destination = if ($meta.Kind -eq 'File') {$meta.Target} else { Join-Path $meta.Target $item.Relative }
        if ($destination -ne $item.Destination) { throw 'Rollback destination validation failed.' }
        Test-NTReparsePath $destination
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $item.InstalledSHA256) {
            throw "Target changed since repair; refusing unsafe rollback: $destination"
        }
        if ($item.Existed) {
            $original = Join-Path (Join-Path $root 'original') $item.Relative
            if (-not (Test-Path -LiteralPath $original -PathType Leaf) -or
                (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ne $item.OldSHA256) {
                throw "Original backup missing or corrupted: $original"
            }
        }
    }
    $targetBoundary = $meta.Target.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($dir in $meta.CreatedDirs) {
        $absoluteDir = [IO.Path]::GetFullPath([string]$dir)
        if (-not $absoluteDir.StartsWith($targetBoundary,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Invalid rollback directory outside target: $absoluteDir"
        }
        Test-NTReparsePath $absoluteDir
    }
    Write-Host "[NT ROLLBACK] $($meta.Entries.Count) files would be reverted."
    if (-not $Apply) { Write-Host 'PREVIEW ONLY. Add -Apply to perform rollback.'; return }
    if ((Read-Host 'Type ROLLBACK to proceed') -cne 'ROLLBACK') { Write-Host 'Cancelled.'; return }
    foreach ($item in $meta.Entries) {
        if ($item.Existed) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $root 'original') $item.Relative) -Destination $item.Destination -Force -ErrorAction Stop
        } else { Remove-Item -LiteralPath $item.Destination -Force -ErrorAction Stop }
    }
    $targetBoundary = $meta.Target.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($dir in ($meta.CreatedDirs | Sort-Object Length -Descending)) {
        try {
            $absoluteDir = [IO.Path]::GetFullPath([string]$dir)
            if (-not $absoluteDir.StartsWith($targetBoundary,[StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing directory outside rollback target: $absoluteDir"
            }
            Test-NTReparsePath $absoluteDir
            if (Test-Path -LiteralPath $dir -PathType Container) {
                [IO.Directory]::Delete($dir,$false) # Never delete user files when rolling back.
            }
        } catch { Write-Warning "Directory not empty or unavailable, retained: $dir" }
    }
    Write-Host '[NT ROLLBACK] Completed. Operation data is retained.' -ForegroundColor Green
}

function nt-winget-repair {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][ValidatePattern('^[\w.\-]+$')][string]$Id,[switch]$Apply)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'WinGet not found.' }
    Write-Host "Check exact publisher and installed package: winget list --id $Id --exact"
    & winget list --id $Id --exact
    if (-not $Apply) {
        Write-Host "PREVIEW ONLY: winget repair --id $Id --exact" -ForegroundColor Yellow
        return
    }
    if ((Read-Host "Type REPAIR to run official repair for $Id") -cne 'REPAIR') { Write-Host 'Cancelled.';return }
    & winget repair --id $Id --exact
    Write-Host "WinGet exit code: $LASTEXITCODE"
}

function nt-windows-repair {
    [CmdletBinding()]
    param([ValidateSet('Check','Scan','Repair')][string]$Mode='Check',[switch]$Apply)
    if (-not $IsWindows) { throw 'DISM and SFC mode is available on Windows only.' }
    switch ($Mode) {
        'Check'  { $actions = @([pscustomobject]@{Exe='dism.exe';Args=@('/Online','/Cleanup-Image','/CheckHealth')}) }
        'Scan'   { $actions = @(
            [pscustomobject]@{Exe='dism.exe';Args=@('/Online','/Cleanup-Image','/ScanHealth')},
            [pscustomobject]@{Exe='sfc.exe';Args=@('/verifyonly')}
        ) }
        'Repair' { $actions = @(
            [pscustomobject]@{Exe='dism.exe';Args=@('/Online','/Cleanup-Image','/RestoreHealth')},
            [pscustomobject]@{Exe='sfc.exe';Args=@('/scannow')}
        ) }
    }
    foreach ($step in $actions) { Write-Host ("  $($step.Exe) $($step.Args -join ' ')") }
    if (-not $Apply) { Write-Host 'PREVIEW ONLY. Add -Apply to run.'; return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Start NT PowerShell using Run as administrator for DISM/SFC.'
    }
    if ($Mode -eq 'Repair') {
        $systemRoot = [IO.Path]::GetPathRoot($env:WINDIR)
        if ((Get-NTFreeSpace $systemRoot) -lt 2GB) {
            throw 'Less than 2 GB free on the Windows disk. Free space before running DISM RestoreHealth.'
        }
        if ((Read-Host 'Type SYSTEM to run DISM then SFC') -cne 'SYSTEM') { Write-Host 'Cancelled.'; return }
    }
    foreach ($step in $actions) {
        $exe = $step.Exe
        $args = $step.Args
        & $exe @args
        if ($LASTEXITCODE -ne 0) { Write-Warning "$exe returned exit code $LASTEXITCODE; stopping."; return }
    }
}


function nt-official-search {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Path)
    $target = Get-NTAbsolute $Path
    $name = [IO.Path]::GetFileNameWithoutExtension($target)
    if (-not $name) { throw 'Unable to identify an application name.' }
    Write-Host "[NT SEARCH] Looking for software named: $name" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ([IO.Path]::GetExtension($target) -in @('.exe','.msi','.dll')) {
            $signature = Get-AuthenticodeSignature -LiteralPath $target
            Write-Host "Signature: $($signature.Status)"
            if ($signature.SignerCertificate) { Write-Host "Signer: $($signature.SignerCertificate.Subject)" }
        }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget search --name $name
    } else { Write-Warning 'WinGet unavailable; use vendor official website.' }
    Write-Host 'Search results are not proof that the listed package matches your program.'
    Write-Host 'Verify the publisher, product, version and origin before using nt-winget-repair.'
    Write-Host 'No files have been downloaded or installed.'
}

function nt-disk-check {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][ValidatePattern('^[A-Za-z]$')][string]$Drive,[switch]$Apply)
    if (-not $IsWindows) { throw 'Windows-only check.' }
    $letter = $Drive.ToUpperInvariant() + ':'
    Write-Host "Read-only planned command: chkdsk $letter /scan"
    if (-not $Apply) { Write-Host 'PREVIEW ONLY; no disk operation started.'; return }
    if ((Read-Host "Type SCAN to run online disk check for $letter") -cne 'SCAN') { Write-Host 'Cancelled.'; return }
    & chkdsk.exe $letter /scan
    Write-Host "CHKDSK exit code: $LASTEXITCODE"
    Write-Host 'For a physically failing drive, copy important data before further repair attempts.'
}

Export-ModuleMember -Function nt-scan,nt-snapshot,nt-verify,nt-compare,nt-res,nt-rollback,nt-winget-repair,nt-windows-repair,nt-official-search,nt-disk-check
