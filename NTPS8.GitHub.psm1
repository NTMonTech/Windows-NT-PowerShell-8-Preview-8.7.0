# NT PowerShell 8 0.7 - GitHub browsing and ZIP source snapshots.
# HTTPS GitHub API only. Never executes downloaded repository code.
Set-StrictMode -Version Latest

function Assert-NTGitHubRepository {
    param([Parameter(Mandatory)][string]$Repository)
    if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$' -or $Repository -match '/\.{1,2}$') {
        throw 'Repository must be OWNER/REPO, for example NTMonTech/NT-PowerShell-8.'
    }
    return $Repository
}

function Get-NTGitHubHeaders {
    param([switch]$UseGitHubCLI)
    $headers = @{ Accept='application/vnd.github+json'; 'User-Agent'='NT-PowerShell8/0.7'; 'X-GitHub-Api-Version'='2022-11-28' }
    if ($UseGitHubCLI) {
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $gh) { throw 'GitHub CLI not installed. Use nt-deps to install Git/GitHub CLI, or browse a public repo without -UseGitHubCLI.' }
        $token = (& $gh.Source auth token 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Log in first with: gh auth login. No token was logged or stored by NT PS8.' }
        $headers['Authorization'] = 'Bearer ' + $token
    }
    return $headers
}

function Invoke-NTGitHubGet {
    param([Parameter(Mandatory)][string]$ApiPath,[switch]$UseGitHubCLI)
    $headers = Get-NTGitHubHeaders -UseGitHubCLI:$UseGitHubCLI
    try { return Invoke-RestMethod -Uri ('https://api.github.com' + $ApiPath) -Headers $headers -TimeoutSec 30 -ErrorAction Stop }
    catch { throw 'GitHub API request failed. Check repository name, connectivity, authentication or rate limits. ' + $_.Exception.Message }
}

function Get-NTGitHubDestination {
    param([string]$Destination)
    if (-not $Destination) {
        if (Test-Path -LiteralPath 'C:\' -PathType Container) { $Destination = 'C:\PowerShell_8_Files\NT_GitHub_Downloads' }
        else { $Destination = Join-Path ([Environment]::GetFolderPath('Desktop')) 'NT_GitHub_Downloads' }
    }
    $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    if (Test-Path -LiteralPath $directory -PathType Leaf) { throw 'Download destination must be a folder.' }
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($directory))
    $drive = [IO.DriveInfo]::new($root)
    if ($drive.AvailableFreeSpace -lt 200MB) { throw ('Insufficient space on {0}; at least 200 MB required before starting. Large repositories may require more.' -f $root) }
    New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    return $directory
}

function github {
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Position=0)][ValidateSet('enter','download','list','browse','help')][string]$Action='help',
        [Parameter(Position=1)][string]$Repository,
        [switch]$DownloadZIP,
        [string]$Destination,
        [string]$Ref,
        [string]$Path='',
        [switch]$UseGitHubCLI
    )
    if ($Action -eq 'help') {
        @'
NT PowerShell 8 / GitHub
 github enter OWNER/REPO                            List remote root and show repository
 github enter OWNER/REPO -Path src                  Browse remote folder
 github list OWNER                                  Show public repositories of owner
 github download OWNER/REPO -DownloadZIP            Download source ZIP, not a Release asset
 github download OWNER/REPO -DownloadZIP -Destination "C:\Code"
 github download OWNER/REPO -DownloadZIP -Ref main   Pin branch/tag to its current commit SHA
 github enter OWNER/PRIVATE -UseGitHubCLI           Use gh auth (no token stored by NT PS8)
 github help
'@ | Write-Host
        return
    }
    if ($Action -eq 'list') {
        if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') { throw 'Use github list OWNER.' }
        $owner = [uri]::EscapeDataString($Repository)
        Write-Host "[GITHUB] Public repositories for $Repository" -ForegroundColor Magenta
        $items = @(Invoke-NTGitHubGet -ApiPath "/users/$owner/repos?per_page=100&type=owner&sort=updated" -UseGitHubCLI:$UseGitHubCLI)
        $items | Select-Object full_name,description,private,html_url | Format-Table -Wrap | Out-Host
        if ($items.Count -eq 100) { Write-Host '[GITHUB] Displaying first 100 results. Open GitHub for full pagination.' -ForegroundColor Yellow }
        return
    }
    $name = Assert-NTGitHubRepository -Repository $Repository
    $repoInfo = Invoke-NTGitHubGet -ApiPath "/repos/$name" -UseGitHubCLI:$UseGitHubCLI
    if ($Action -eq 'enter' -or $Action -eq 'browse') {
        if ($Path -and ($Path -match '(^|/)\.{1,2}(/|$)' -or $Path -match '[\\\r\n]')) { throw 'Invalid repository subdirectory path.' }
        $subpath = (($Path -split '/' | Where-Object { $_ }) | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $endpoint = "/repos/$name/contents"
        if ($subpath) { $endpoint += '/' + $subpath }
        $targetRef = if ($Ref) { $Ref } else { $repoInfo.default_branch }
        $endpoint += '?ref=' + [uri]::EscapeDataString($targetRef)
        $contents = @(Invoke-NTGitHubGet -ApiPath $endpoint -UseGitHubCLI:$UseGitHubCLI)
        $script:NTGitHubLastRepository = $name
        Write-Host ('[GITHUB] ' + $repoInfo.full_name + ' - ' + $repoInfo.html_url) -ForegroundColor Magenta
        Write-Host ('[GITHUB] Branch/ref: ' + $targetRef + ' | ' + $(if ($repoInfo.private) {'PRIVATE'} else {'PUBLIC'}))
        if ($repoInfo.description) { Write-Host ('[GITHUB] ' + $repoInfo.description) }
        $contents | Select-Object @{N='Type';E={$_.type}},name,path,size | Format-Table -AutoSize | Out-Host
        Write-Host ('[GITHUB] To download: github download ' + $name + ' -DownloadZIP') -ForegroundColor DarkMagenta
        return
    }
    if (-not $DownloadZIP) { throw 'Explicit -DownloadZIP is required. This downloads a source snapshot, not release assets.' }
    if ($Ref -and ($Ref -notmatch '^[A-Za-z0-9._/-]{1,180}$' -or $Ref -match '(^|/)\.{1,2}(/|$)')) { throw 'Invalid ref.' }
    $requestedRef = if ($Ref) { $Ref } else { [string]$repoInfo.default_branch }
    $commit = Invoke-NTGitHubGet -ApiPath ('/repos/' + $name + '/commits/' + [uri]::EscapeDataString($requestedRef)) -UseGitHubCLI:$UseGitHubCLI
    $sha = [string]$commit.sha
    if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'GitHub did not return a valid commit SHA.' }
    $folder = Get-NTGitHubDestination -Destination $Destination
    $short = $sha.Substring(0,12)
    $base = ('{0}_{1}_{2}' -f $repoInfo.owner.login,$repoInfo.name,$short)
    $output = Join-Path $folder ($base + '.zip')
    if (Test-Path -LiteralPath $output) { throw "ZIP already exists: $output (existing files never overwritten)." }
    $part = Join-Path $folder ($base + '.partial')
    Write-Host ('[GITHUB] Source: ' + $repoInfo.html_url) -ForegroundColor Magenta
    Write-Host ('[GITHUB] Exact commit: ' + $sha)
    Write-Host ('[GITHUB] Downloading ZIP to: ' + $output)
    $headers = Get-NTGitHubHeaders -UseGitHubCLI:$UseGitHubCLI
    try {
        Invoke-WebRequest -Uri ('https://api.github.com/repos/' + $name + '/zipball/' + $sha) -Headers $headers -MaximumRedirection 5 -OutFile $part -TimeoutSec 180 -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.ZipFile
        $archive = [IO.Compression.ZipFile]::OpenRead($part)
        try {
            if ($archive.Entries.Count -eq 0) { throw 'Downloaded ZIP contains no files.' }
            $files = $archive.Entries.Count
        } finally { $archive.Dispose() }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash
        Move-Item -LiteralPath $part -Destination $output -ErrorAction Stop
        Write-Host ('[GITHUB] Verified ZIP structure; entries: {0}' -f $files) -ForegroundColor Green
        Write-Host ('[GITHUB] Local SHA256: ' + $hash)
        Write-Host ('[GITHUB] Saved: ' + $output) -ForegroundColor Green
        Write-Host '[GITHUB] This hash identifies the downloaded file; it is not a separately published GitHub checksum.'
        return $output
    } catch {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        throw
    }
}

Export-ModuleMember -Function github
