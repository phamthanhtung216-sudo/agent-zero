[CmdletBinding()]
param(
    [string]$TargetPath,
    [switch]$CheckOnly,
    [switch]$Apply,
    [switch]$PrepareOnly,
    [switch]$Recover,
    [string]$FinalizeTransaction,
    [switch]$ApproveSemanticMigration,
    [switch]$NonInteractive,
    [switch]$LauncherOwnsFailurePause,
    [switch]$NoClipboard,
    [string]$LocalKitPath,
    [string]$ReleaseMetadataPath,
    [string]$ReleaseAssetPath,
    [string]$Repository = "phamthanhtung216-sudo/agent-zero",
    [string]$ApiBaseUrl = "https://api.github.com"
)

$ErrorActionPreference = "Stop"
$script:InteractiveMode = -not $NonInteractive
$script:TemporaryRoots = [System.Collections.Generic.List[string]]::new()
$script:UpdateLockStream = $null
$script:UpdateLockProjectRoot = $null
$script:CurrentEnginePath = $PSCommandPath
$script:ModeRanks = @{
    CORE_ONLY = 1
    LOSSLESS_SCRIPTED = 2
    SEMANTIC_REVIEW = 3
    UNSUPPORTED = 4
}

function Wait-UpdateClose {
    if ($script:InteractiveMode -and -not $LauncherOwnsFailurePause) {
        [void](Read-Host "Nhan Enter de dong cua so")
    }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backupPath = "$Path.replace-backup"
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
        [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
    else {
        [System.IO.File]::Move($temporaryPath, $Path)
    }
}

function Get-RequiredProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$ErrorCode = "AZ-UPDATE-MANIFEST",
        [switch]$AllowNull
    )

    if ($null -eq $Object) {
        throw "$($ErrorCode): missing object while reading $Name."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or (-not $AllowNull -and $null -eq $property.Value)) {
        throw "$($ErrorCode): required field is missing: $Name."
    }
    return $property.Value
}

function Test-SemVer {
    param([string]$Version)
    return -not [string]::IsNullOrWhiteSpace($Version) -and $Version -match '^\d+\.\d+\.\d+$'
}

function Compare-SemVer {
    param([string]$Left, [string]$Right)

    if (-not (Test-SemVer $Left) -or -not (Test-SemVer $Right)) {
        throw "AZ-UPDATE-VERSION: versions must use MAJOR.MINOR.PATCH: $Left / $Right."
    }
    return ([version]$Left).CompareTo([version]$Right)
}

function Assert-SafeRelativePath {
    param([string]$RelativePath, [string]$ErrorCode = "AZ-UPDATE-PATH")

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains(':') -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$($ErrorCode): unsafe relative path: $RelativePath"
    }
}

function Assert-SimpleFileName {
    param([string]$Name)

    Assert-SafeRelativePath -RelativePath $Name -ErrorCode "AZ-UPDATE-MANIFEST"
    if ([System.IO.Path]::GetFileName($Name) -ne $Name) {
        throw "AZ-UPDATE-MANIFEST: asset must be a simple file name: $Name"
    }
}

function Assert-NoReparseTree {
    param([string]$Root, [string]$ErrorCode = "AZ-UPDATE-PATH")

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }
    $rootItem = Get-Item -Force -LiteralPath $Root
    if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$($ErrorCode): links and reparse points are not allowed: $Root"
    }
    if ($rootItem.PSIsContainer) {
        $pending = [System.Collections.Generic.Queue[string]]::new()
        $pending.Enqueue($rootItem.FullName)
        while ($pending.Count -gt 0) {
            $directory = $pending.Dequeue()
            foreach ($item in Get-ChildItem -Force -LiteralPath $directory) {
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw "$($ErrorCode): links and reparse points are not allowed: $($item.FullName)"
                }
                if ($item.PSIsContainer) {
                    $pending.Enqueue($item.FullName)
                }
            }
        }
    }
}

function Resolve-ProjectRoot {
    param([string]$RequestedPath)

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        $scriptDirectory = Split-Path -Parent $MyInvocation.ScriptName
        if ((Split-Path -Leaf $scriptDirectory) -ieq "scripts" -and
            (Split-Path -Leaf (Split-Path -Parent $scriptDirectory)) -ieq ".agent-zero") {
            $RequestedPath = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
        }
        else {
            $RequestedPath = Split-Path -Parent $scriptDirectory
        }
    }

    $fullPath = [System.IO.Path]::GetFullPath($RequestedPath).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "AZ-UPDATE-TARGET: project does not exist: $fullPath"
    }
    $driveRoot = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/')
    if ($fullPath -eq $driveRoot) {
        throw "AZ-UPDATE-TARGET: refusing to use a drive root."
    }
    $rootItem = Get-Item -Force -LiteralPath $fullPath
    if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "AZ-UPDATE-TARGET: project root must not be a link or reparse point."
    }
    return $fullPath
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-TextSha256 {
    param([string[]]$Lines)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($Lines -join [Environment]::NewLine))
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "")
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-PathFingerprint {
    param([string]$ProjectRoot, [string[]]$RelativePaths)

    $projectBoundary = $ProjectRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $records = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePathValue in @($RelativePaths | Sort-Object -Unique)) {
        $relativePath = [string]$relativePathValue
        if ($relativePath.EndsWith("/**") -or $relativePath.EndsWith("\**")) {
            $relativePath = $relativePath.Substring(0, $relativePath.Length - 3)
        }
        Assert-SafeRelativePath -RelativePath $relativePath
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $relativePath))
        if (-not $fullPath.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "AZ-UPDATE-PATH: fingerprint path escapes project: $relativePath"
        }
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $records.Add("$($relativePath.Replace('\','/'))|MISSING")
            continue
        }
        Assert-NoReparseTree -Root $fullPath
        $item = Get-Item -Force -LiteralPath $fullPath
        if (-not $item.PSIsContainer) {
            $records.Add("$($relativePath.Replace('\','/'))|FILE|$(Get-Sha256 $fullPath)")
            continue
        }
        $records.Add("$($relativePath.Replace('\','/'))|DIRECTORY")
        foreach ($child in @(Get-ChildItem -Force -File -Recurse -LiteralPath $fullPath | Sort-Object FullName)) {
            $childRelative = $child.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/')
            $records.Add("$childRelative|FILE|$(Get-Sha256 $child.FullName)")
        }
    }
    return Get-TextSha256 -Lines @($records)
}

function Get-BoundaryFingerprint {
    param(
        [string]$Root,
        [string[]]$ExcludedRelativePaths = @()
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "AZ-UPDATE-MIGRATION-BOUNDARY: fingerprint root is missing: $Root"
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    Assert-NoReparseTree -Root $rootPath -ErrorCode "AZ-UPDATE-MIGRATION-BOUNDARY"
    $exclusions = @($ExcludedRelativePaths | ForEach-Object {
        ([string]$_).Trim('\', '/').Replace('\', '/').ToLowerInvariant()
    })
    $records = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-ChildItem -Force -Recurse -LiteralPath $rootPath | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($rootPath.Length).TrimStart('\', '/').Replace('\', '/')
        $relativeLower = $relative.ToLowerInvariant()
        $excluded = $false
        foreach ($prefix in $exclusions) {
            if ($relativeLower -eq $prefix -or $relativeLower.StartsWith($prefix + "/", [System.StringComparison]::Ordinal)) {
                $excluded = $true
                break
            }
        }
        if ($excluded) {
            continue
        }
        if ($item.PSIsContainer) {
            $records.Add("$relative|DIRECTORY")
        }
        else {
            $records.Add("$relative|FILE|$(Get-Sha256 $item.FullName)")
        }
    }
    return Get-TextSha256 -Lines @($records)
}

function Copy-DirectoryContents {
    param([string]$Source, [string]$Destination)

    Assert-NoReparseTree -Root $Source
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -Force -LiteralPath $Source) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Read-UpdateManifest {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AZ-UPDATE-MANIFEST: manifest is missing: $Path"
    }
    $raw = Get-Content -Raw -LiteralPath $Path
    try {
        $manifest = $raw | ConvertFrom-Json
    }
    catch {
        throw "AZ-UPDATE-MANIFEST: invalid JSON. $($_.Exception.Message)"
    }

    if ((Get-RequiredProperty $manifest "schema") -ne 1) {
        throw "AZ-UPDATE-MANIFEST: unsupported schema."
    }
    if ((Get-RequiredProperty $manifest "product") -ne "agent-zero") {
        throw "AZ-UPDATE-MANIFEST: unexpected product."
    }
    if ((Get-RequiredProperty $manifest "repository") -ne $Repository) {
        throw "AZ-UPDATE-MANIFEST: repository mismatch."
    }
    if ((Get-RequiredProperty $manifest "channel") -ne "stable") {
        throw "AZ-UPDATE-MANIFEST: only the stable channel is accepted."
    }
    $version = [string](Get-RequiredProperty $manifest "version")
    if (-not (Test-SemVer $version) -or (Get-RequiredProperty $manifest "tag") -ne "v$version") {
        throw "AZ-UPDATE-MANIFEST: version and tag do not agree."
    }
    $targetCoreSha = [string](Get-RequiredProperty $manifest "targetCoreSha256")
    if ($targetCoreSha -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "AZ-UPDATE-MANIFEST: targetCoreSha256 is invalid."
    }
    $declaredMode = [string](Get-RequiredProperty $manifest "declaredMode")
    if ($declaredMode -notin @("CORE_ONLY", "LOSSLESS_SCRIPTED", "SEMANTIC_REVIEW")) {
        throw "AZ-UPDATE-MANIFEST: declaredMode is invalid: $declaredMode"
    }

    $assets = Get-RequiredProperty $manifest "assets"
    foreach ($assetField in @("kit", "manifest", "checksums")) {
        Assert-SimpleFileName -Name ([string](Get-RequiredProperty $assets $assetField))
    }
    if ((Get-RequiredProperty $assets "manifest") -ne "UPDATE_MANIFEST.json") {
        throw "AZ-UPDATE-MANIFEST: the manifest asset must be UPDATE_MANIFEST.json."
    }

    $coreCandidates = @((Get-RequiredProperty $manifest "coreCandidates"))
    if ($coreCandidates.Count -ne 2 -or
        "AGENTS.md" -notin $coreCandidates -or
        "AGENT_ZERO_CANDIDATE.md" -notin $coreCandidates) {
        throw "AZ-UPDATE-MANIFEST: coreCandidates must contain the two supported core locations."
    }
    foreach ($candidate in $coreCandidates) {
        Assert-SafeRelativePath -RelativePath ([string]$candidate) -ErrorCode "AZ-UPDATE-MANIFEST"
    }

    $protectedPaths = @((Get-RequiredProperty $manifest "protectedPaths"))
    foreach ($requiredProtected in @(".agent/**", ".agents/**", ".codex/**")) {
        if ($requiredProtected -notin $protectedPaths) {
            throw "AZ-UPDATE-MANIFEST: protected path is missing: $requiredProtected"
        }
    }
    foreach ($protectedPath in $protectedPaths) {
        $checkPath = ([string]$protectedPath) -replace '[\\/]\*\*$', ''
        Assert-SafeRelativePath -RelativePath $checkPath -ErrorCode "AZ-UPDATE-MANIFEST"
    }

    $managedPaths = @((Get-RequiredProperty $manifest "managedPaths"))
    if ($managedPaths.Count -ne 1 -or $managedPaths[0] -ne ".agent-zero/**") {
        throw "AZ-UPDATE-MANIFEST: this updater only manages .agent-zero/** plus the recognized core."
    }

    $transitions = @((Get-RequiredProperty $manifest "transitions"))
    if ($transitions.Count -eq 0) {
        throw "AZ-UPDATE-MANIFEST: at least one exact transition is required."
    }
    $seenVersions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($transition in $transitions) {
        $fromVersion = [string](Get-RequiredProperty $transition "from")
        if (-not (Test-SemVer $fromVersion) -or -not $seenVersions.Add($fromVersion)) {
            throw "AZ-UPDATE-MANIFEST: transition source is invalid or duplicated: $fromVersion"
        }
        $minimumMode = [string](Get-RequiredProperty $transition "minimumMode")
        if ($minimumMode -notin @("CORE_ONLY", "LOSSLESS_SCRIPTED", "SEMANTIC_REVIEW")) {
            throw "AZ-UPDATE-MANIFEST: transition minimumMode is invalid: $minimumMode"
        }
        $recognizedHashes = @((Get-RequiredProperty $transition "recognizedCoreSha256"))
        if ($recognizedHashes.Count -eq 0) {
            throw "AZ-UPDATE-MANIFEST: transition $fromVersion has no recognized core hash."
        }
        foreach ($recognizedHash in $recognizedHashes) {
            if ([string]$recognizedHash -notmatch '^[A-Fa-f0-9]{64}$') {
                throw "AZ-UPDATE-MANIFEST: transition $fromVersion contains an invalid core hash."
            }
        }
        $migrator = Get-RequiredProperty $transition "migrator" -AllowNull
        if ($null -ne $migrator) {
            Assert-SafeRelativePath -RelativePath ([string]$migrator) -ErrorCode "AZ-UPDATE-MANIFEST"
            if (-not ([string]$migrator).StartsWith("payload/migrations/", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "AZ-UPDATE-MANIFEST: migrator must stay under payload/migrations/."
            }
        }
        if (($minimumMode -eq "LOSSLESS_SCRIPTED" -or $declaredMode -eq "LOSSLESS_SCRIPTED") -and $null -eq $migrator) {
            throw "AZ-UPDATE-MANIFEST: LOSSLESS_SCRIPTED transition requires a migrator."
        }
    }

    [pscustomobject]@{
        Model = $manifest
        Raw = $raw
        Path = [System.IO.Path]::GetFullPath($Path)
        Sha256 = Get-Sha256 $Path
    }
}

function Get-ChecksumMap {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AZ-UPDATE-HASH: checksum asset is missing."
    }
    $result = @{}
    foreach ($lineValue in Get-Content -LiteralPath $Path) {
        $line = [string]$lineValue
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $match = [regex]::Match($line, '^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>[^\r\n]+)$')
        if (-not $match.Success) {
            throw "AZ-UPDATE-HASH: invalid checksum line."
        }
        $name = $match.Groups["name"].Value.Trim()
        Assert-SimpleFileName -Name $name
        if ($result.ContainsKey($name)) {
            throw "AZ-UPDATE-HASH: duplicate checksum entry: $name"
        }
        $result[$name] = $match.Groups["hash"].Value.ToUpperInvariant()
    }
    return $result
}

function Assert-FileChecksum {
    param([string]$Path, [hashtable]$Checksums)

    $name = Split-Path -Leaf $Path
    if (-not $Checksums.ContainsKey($name)) {
        throw "AZ-UPDATE-HASH: no checksum was published for $name."
    }
    $actual = Get-Sha256 $Path
    if ($actual -ne $Checksums[$name]) {
        throw "AZ-UPDATE-HASH: SHA-256 mismatch for $name."
    }
}

function New-TemporaryRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-zero-update-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:TemporaryRoots.Add($root)
    return $root
}

function Get-ReleaseAssetObject {
    param([object]$Release, [string]$Name)

    $matches = @((Get-RequiredProperty $Release "assets" "AZ-UPDATE-RELEASE") | Where-Object { $_.name -eq $Name })
    if ($matches.Count -ne 1) {
        throw "AZ-UPDATE-RELEASE: expected exactly one release asset named $Name."
    }
    return $matches[0]
}

function Copy-ReleaseAsset {
    param(
        [object]$Release,
        [string]$Name,
        [string]$Destination,
        [string]$OfflineAssetRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($OfflineAssetRoot)) {
        $source = Join-Path $OfflineAssetRoot $Name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "AZ-UPDATE-RELEASE: offline asset is missing: $Name"
        }
        Copy-Item -LiteralPath $source -Destination $Destination -Force
        return
    }

    $asset = Get-ReleaseAssetObject -Release $Release -Name $Name
    $downloadUrl = [string](Get-RequiredProperty $asset "browser_download_url" "AZ-UPDATE-RELEASE")
    if ($downloadUrl -notmatch '^https://github\.com/' -and $downloadUrl -notmatch '^https://objects\.githubusercontent\.com/') {
        throw "AZ-UPDATE-RELEASE: unexpected asset host."
    }
    Invoke-WebRequest -UseBasicParsing -Headers @{ "User-Agent" = "Agent-Zero-Updater" } -Uri $downloadUrl -OutFile $Destination
}

function Assert-ReleaseMetadata {
    param([object]$Release, [object]$Manifest)

    if ([bool](Get-RequiredProperty $Release "draft" "AZ-UPDATE-RELEASE") -or
        [bool](Get-RequiredProperty $Release "prerelease" "AZ-UPDATE-RELEASE")) {
        throw "AZ-UPDATE-RELEASE: latest release must be published, stable and non-prerelease."
    }
    if ([string](Get-RequiredProperty $Release "tag_name" "AZ-UPDATE-RELEASE") -ne [string]$Manifest.tag) {
        throw "AZ-UPDATE-RELEASE: release tag does not match manifest."
    }
    $apiUrl = [string](Get-RequiredProperty $Release "url" "AZ-UPDATE-RELEASE")
    if ($apiUrl -notmatch ("/repos/" + [regex]::Escape($Repository) + "/releases/")) {
        throw "AZ-UPDATE-RELEASE: release API identity does not match repository."
    }
    [void](Get-RequiredProperty $Release "id" "AZ-UPDATE-RELEASE")
    foreach ($assetName in @($Manifest.assets.manifest, $Manifest.assets.checksums, $Manifest.assets.kit)) {
        [void](Get-ReleaseAssetObject -Release $Release -Name ([string]$assetName))
    }
}

function Expand-VerifiedArchive {
    param([string]$ArchivePath, [string]$Destination, [string]$ExpectedManifestSha256)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $destinationBoundary = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($entryName)) {
                continue
            }
            if ([System.IO.Path]::IsPathRooted($entryName) -or
                $entryName.Contains(':') -or
                $entryName -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "AZ-UPDATE-ARCHIVE: unsafe ZIP entry: $($entry.FullName)"
            }
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $Destination $entryName))
            if (-not $resolved.StartsWith($destinationBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "AZ-UPDATE-ARCHIVE: ZIP entry escapes staging."
            }
            if (-not $seen.Add($resolved)) {
                throw "AZ-UPDATE-ARCHIVE: duplicate ZIP entry: $($entry.FullName)"
            }
            $unixType = (([int64]$entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixType -eq 0xA000) {
                throw "AZ-UPDATE-ARCHIVE: symbolic links are not allowed."
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
    Assert-NoReparseTree -Root $Destination -ErrorCode "AZ-UPDATE-ARCHIVE"
    $manifestMatches = @(Get-ChildItem -Force -File -Recurse -LiteralPath $Destination -Filter "UPDATE_MANIFEST.json")
    $kitCandidates = @($manifestMatches | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.Directory.FullName "AGENT_ZERO_CANDIDATE.md") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_.Directory.FullName "payload/VERSION") -PathType Leaf)
    })
    if ($kitCandidates.Count -ne 1) {
        throw "AZ-UPDATE-ARCHIVE: archive must contain exactly one Agent Zero kit."
    }
    if ((Get-Sha256 $kitCandidates[0].FullName) -ne $ExpectedManifestSha256) {
        throw "AZ-UPDATE-HASH: manifest inside ZIP differs from the verified release manifest."
    }
    return $kitCandidates[0].Directory.FullName
}

function Assert-Kit {
    param([string]$KitRoot, [object]$ManifestRecord)

    $required = @(
        "AGENT_ZERO_CANDIDATE.md",
        "UPDATE.cmd",
        "UPDATE.md",
        "UPDATE_MANIFEST.json",
        "payload/VERSION",
        "payload/START.md",
        "payload/TESTING.md",
        "payload/scripts/update-agent-zero.ps1",
        "payload/scripts/validate-install.ps1",
        "payload/scripts/validate-core-policy.ps1",
        "payload/scripts/validate-memory.ps1"
    )
    Assert-NoReparseTree -Root $KitRoot -ErrorCode "AZ-UPDATE-KIT"
    foreach ($relativePath in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $relativePath) -PathType Leaf)) {
            throw "AZ-UPDATE-KIT: kit is incomplete: $relativePath"
        }
    }
    if ((Get-Sha256 (Join-Path $KitRoot "UPDATE_MANIFEST.json")) -ne $ManifestRecord.Sha256) {
        throw "AZ-UPDATE-HASH: kit manifest differs from the selected manifest."
    }
    if ((Get-Content -Raw -LiteralPath (Join-Path $KitRoot "payload/VERSION")).Trim() -ne $ManifestRecord.Model.version) {
        throw "AZ-UPDATE-KIT: payload version does not match manifest."
    }
    if ((Get-Sha256 (Join-Path $KitRoot "AGENT_ZERO_CANDIDATE.md")) -ne
        ([string]$ManifestRecord.Model.targetCoreSha256).ToUpperInvariant()) {
        throw "AZ-UPDATE-HASH: target core does not match manifest."
    }
    $coreArguments = @{
        CorePath = Join-Path $KitRoot "AGENT_ZERO_CANDIDATE.md"
        ReferenceRoot = Join-Path $KitRoot "payload/references"
        ExpectedVersion = [string]$ManifestRecord.Model.version
        Quiet = $true
    }
    & (Join-Path $KitRoot "payload/scripts/validate-core-policy.ps1") @coreArguments | Out-Null
}

function Get-ReleaseBundle {
    param([switch]$NeedKit)

    if (-not [string]::IsNullOrWhiteSpace($LocalKitPath)) {
        $kitRoot = [System.IO.Path]::GetFullPath($LocalKitPath).TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath $kitRoot -PathType Container)) {
            throw "AZ-UPDATE-KIT: local kit does not exist: $kitRoot"
        }
        $manifestRecord = Read-UpdateManifest -Path (Join-Path $kitRoot "UPDATE_MANIFEST.json")
        if ($NeedKit) {
            Assert-Kit -KitRoot $kitRoot -ManifestRecord $manifestRecord
        }
        return [pscustomobject]@{
            ManifestRecord = $manifestRecord
            KitRoot = if ($NeedKit) { $kitRoot } else { $null }
            Source = "LOCAL_KIT"
            ReleaseUrl = [string]$manifestRecord.Model.display.releaseNotesUrl
        }
    }

    $temporaryRoot = New-TemporaryRoot
    if (-not [string]::IsNullOrWhiteSpace($ReleaseMetadataPath)) {
        if (-not (Test-Path -LiteralPath $ReleaseMetadataPath -PathType Leaf)) {
            throw "AZ-UPDATE-RELEASE: release metadata file is missing."
        }
        try {
            $release = Get-Content -Raw -LiteralPath $ReleaseMetadataPath | ConvertFrom-Json
        }
        catch {
            throw "AZ-UPDATE-RELEASE: invalid release metadata JSON."
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($ReleaseAssetPath)) {
            throw "AZ-UPDATE-RELEASE: offline assets require ReleaseMetadataPath."
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $releaseApi = $ApiBaseUrl.TrimEnd('/') + "/repos/$Repository/releases/latest"
        $release = Invoke-RestMethod -Headers @{ "User-Agent" = "Agent-Zero-Updater" } -Uri $releaseApi
    }

    $manifestPath = Join-Path $temporaryRoot "UPDATE_MANIFEST.json"
    $checksumsPath = Join-Path $temporaryRoot "SHA256SUMS.txt"
    Copy-ReleaseAsset -Release $release -Name "UPDATE_MANIFEST.json" -Destination $manifestPath -OfflineAssetRoot $ReleaseAssetPath
    Copy-ReleaseAsset -Release $release -Name "SHA256SUMS.txt" -Destination $checksumsPath -OfflineAssetRoot $ReleaseAssetPath
    $manifestRecord = Read-UpdateManifest -Path $manifestPath
    Assert-ReleaseMetadata -Release $release -Manifest $manifestRecord.Model
    $checksums = Get-ChecksumMap -Path $checksumsPath
    Assert-FileChecksum -Path $manifestPath -Checksums $checksums

    $kitRoot = $null
    if ($NeedKit) {
        $kitName = [string]$manifestRecord.Model.assets.kit
        $archivePath = Join-Path $temporaryRoot $kitName
        Copy-ReleaseAsset -Release $release -Name $kitName -Destination $archivePath -OfflineAssetRoot $ReleaseAssetPath
        Assert-FileChecksum -Path $archivePath -Checksums $checksums
        $kitRoot = Expand-VerifiedArchive -ArchivePath $archivePath -Destination (Join-Path $temporaryRoot "extracted") -ExpectedManifestSha256 $manifestRecord.Sha256
        Assert-Kit -KitRoot $kitRoot -ManifestRecord $manifestRecord
    }

    return [pscustomobject]@{
        ManifestRecord = $manifestRecord
        KitRoot = $kitRoot
        Source = if ([string]::IsNullOrWhiteSpace($ReleaseAssetPath)) { "GITHUB_RELEASE" } else { "OFFLINE_RELEASE_ASSETS" }
        ReleaseUrl = [string](Get-RequiredProperty $release "html_url" "AZ-UPDATE-RELEASE")
    }
}

function Get-StricterMode {
    param([string[]]$Modes)

    $selected = "CORE_ONLY"
    foreach ($mode in $Modes) {
        if (-not $script:ModeRanks.ContainsKey($mode)) {
            throw "AZ-UPDATE-MODE: unknown mode: $mode"
        }
        if ($script:ModeRanks[$mode] -gt $script:ModeRanks[$selected]) {
            $selected = $mode
        }
    }
    return $selected
}

function Get-InstalledAssessment {
    param([string]$ProjectRoot, [object]$Manifest)

    $installedVersionPath = Join-Path $ProjectRoot ".agent-zero/VERSION"
    if (-not (Test-Path -LiteralPath $installedVersionPath -PathType Leaf)) {
        throw "AZ-UPDATE-INSTALLATION: .agent-zero/VERSION is missing. Use INSTALL.cmd before the updater."
    }
    $installedVersion = (Get-Content -Raw -LiteralPath $installedVersionPath).Trim()
    if (-not (Test-SemVer $installedVersion)) {
        throw "AZ-UPDATE-INSTALLATION: installed VERSION is invalid."
    }
    $targetVersion = [string]$Manifest.version
    $comparison = Compare-SemVer -Left $installedVersion -Right $targetVersion
    if ($comparison -eq 0) {
        return [pscustomobject]@{
            Status = "UP_TO_DATE"
            InstalledVersion = $installedVersion
            TargetVersion = $targetVersion
            DeclaredMode = [string]$Manifest.declaredMode
            LocalMode = "CORE_ONLY"
            EffectiveMode = "CORE_ONLY"
            CoreRelativePath = $null
            ValidationMode = $null
            Transition = $null
            Reasons = @("VERSION_MATCH")
        }
    }
    if ($comparison -gt 0) {
        return [pscustomobject]@{
            Status = "LOCAL_NEWER"
            InstalledVersion = $installedVersion
            TargetVersion = $targetVersion
            DeclaredMode = [string]$Manifest.declaredMode
            LocalMode = "CORE_ONLY"
            EffectiveMode = "CORE_ONLY"
            CoreRelativePath = $null
            ValidationMode = $null
            Transition = $null
            Reasons = @("DOWNGRADE_NOT_ATTEMPTED")
        }
    }

    $transitionMatches = @($Manifest.transitions | Where-Object { $_.from -eq $installedVersion })
    if ($transitionMatches.Count -ne 1) {
        return [pscustomobject]@{
            Status = "UNSUPPORTED"
            InstalledVersion = $installedVersion
            TargetVersion = $targetVersion
            DeclaredMode = [string]$Manifest.declaredMode
            LocalMode = "UNSUPPORTED"
            EffectiveMode = "UNSUPPORTED"
            CoreRelativePath = $null
            ValidationMode = $null
            Transition = $null
            Reasons = @("NO_EXACT_TRANSITION")
        }
    }
    $transition = $transitionMatches[0]
    $reasons = [System.Collections.Generic.List[string]]::new()
    $observedCores = [System.Collections.Generic.List[object]]::new()
    foreach ($relativePathValue in @($Manifest.coreCandidates)) {
        $relativePath = [string]$relativePathValue
        $corePath = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
            continue
        }
        $coreText = Get-Content -Raw -LiteralPath $corePath
        $coreHash = Get-Sha256 $corePath
        if ($coreText -match '(?m)^# Agent Zero v\d+\.\d+\.\d+' -or
            $coreHash -in @($transition.recognizedCoreSha256)) {
            $observedCores.Add([pscustomobject]@{
                RelativePath = $relativePath
                Path = $corePath
                Sha256 = $coreHash
            })
        }
    }
    if ($observedCores.Count -eq 0) {
        return [pscustomobject]@{
            Status = "UNSUPPORTED"
            InstalledVersion = $installedVersion
            TargetVersion = $targetVersion
            DeclaredMode = [string]$Manifest.declaredMode
            LocalMode = "UNSUPPORTED"
            EffectiveMode = "UNSUPPORTED"
            CoreRelativePath = $null
            ValidationMode = $null
            Transition = $transition
            Reasons = @("CORE_TARGET_UNKNOWN")
        }
    }
    if ($observedCores.Count -gt 1) {
        return [pscustomobject]@{
            Status = "UNSUPPORTED"
            InstalledVersion = $installedVersion
            TargetVersion = $targetVersion
            DeclaredMode = [string]$Manifest.declaredMode
            LocalMode = "UNSUPPORTED"
            EffectiveMode = "UNSUPPORTED"
            CoreRelativePath = $null
            ValidationMode = $null
            Transition = $transition
            Reasons = @("AMBIGUOUS_AGENT_ZERO_CORES")
        }
    }

    $core = $observedCores[0]
    $localMode = "CORE_ONLY"
    if ($core.Sha256 -notin @($transition.recognizedCoreSha256 | ForEach-Object { ([string]$_).ToUpperInvariant() })) {
        $localMode = "SEMANTIC_REVIEW"
        $reasons.Add("LOCAL_CORE_DRIFT")
    }
    else {
        $reasons.Add("RECOGNIZED_CORE_SHA256")
    }

    $validationMode = if ($core.RelativePath -eq "AGENTS.md") { "UpgradeActive" } else { "UpgradeCandidate" }
    if ($validationMode -eq "UpgradeActive") {
        $statePath = Join-Path $ProjectRoot ".agent/STATE.md"
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            $localMode = "SEMANTIC_REVIEW"
            $reasons.Add("ACTIVE_MEMORY_MISSING")
        }
        else {
            $stateText = Get-Content -Raw -LiteralPath $statePath
            $schemaMatch = [regex]::Match($stateText, '(?m)^- Schema:\s+\x60?(?<schema>\d+)\x60?\s*$')
            $acceptedSchemas = @($transition.acceptedContextSchemas | ForEach-Object { [int]$_ })
            if (-not $schemaMatch.Success -or [int]$schemaMatch.Groups["schema"].Value -notin $acceptedSchemas) {
                $localMode = "SEMANTIC_REVIEW"
                $reasons.Add("CONTEXT_SCHEMA_REVIEW_REQUIRED")
            }
            $currentValidator = Join-Path $ProjectRoot ".agent-zero/scripts/validate-memory.ps1"
            if (Test-Path -LiteralPath $currentValidator -PathType Leaf) {
                try {
                    & $currentValidator -ProjectRoot $ProjectRoot -AllowLegacyStateSchema5 | Out-Null
                    $reasons.Add("LIVE_MEMORY_VALID")
                }
                catch {
                    $localMode = "SEMANTIC_REVIEW"
                    $reasons.Add("LIVE_MEMORY_VALIDATION_FAILED")
                }
            }
            else {
                $localMode = "SEMANTIC_REVIEW"
                $reasons.Add("LIVE_MEMORY_VALIDATOR_MISSING")
            }
        }
    }
    else {
        $reasons.Add("ADOPTION_CANDIDATE_CONTEXT_READ_ONLY")
        $releaseMinimum = Get-StricterMode -Modes @([string]$Manifest.declaredMode, [string]$transition.minimumMode)
        if ($releaseMinimum -ne "CORE_ONLY") {
            $localMode = "SEMANTIC_REVIEW"
            $reasons.Add("CANDIDATE_MIGRATION_REQUIRES_REVIEW")
        }
    }

    $effectiveMode = Get-StricterMode -Modes @(
        [string]$Manifest.declaredMode,
        [string]$transition.minimumMode,
        $localMode
    )
    return [pscustomobject]@{
        Status = "UPDATE_AVAILABLE"
        InstalledVersion = $installedVersion
        TargetVersion = $targetVersion
        DeclaredMode = [string]$Manifest.declaredMode
        LocalMode = $localMode
        EffectiveMode = $effectiveMode
        CoreRelativePath = $core.RelativePath
        CoreSha256 = $core.Sha256
        ValidationMode = $validationMode
        Transition = $transition
        Reasons = @($reasons)
    }
}

function Show-Assessment {
    param([object]$Assessment, [object]$Manifest, [string]$ReleaseUrl, [string]$Source)

    Write-Host ""
    Write-Host "KET QUA KIEM TRA UPDATE" -ForegroundColor Cyan
    Write-Host "AZ-UPDATE-$($Assessment.Status)"
    Write-Host "Installed: $($Assessment.InstalledVersion)"
    Write-Host "Latest:    $($Assessment.TargetVersion)"
    Write-Host "Source:    $Source"
    Write-Host "Release:   $ReleaseUrl"
    Write-Host ""
    Write-Host ([string]$Manifest.display.title) -ForegroundColor White
    Write-Host ([string]$Manifest.display.summary)
    foreach ($change in @($Manifest.display.changes)) {
        Write-Host "- $change"
    }
    Write-Host ""
    Write-Host "Context impact: $($Manifest.display.contextImpact)"
    Write-Host "Declared mode:  $($Assessment.DeclaredMode)"
    Write-Host "Local evidence: $($Assessment.LocalMode)"
    Write-Host "Effective mode: $($Assessment.EffectiveMode)" -ForegroundColor Yellow
    Write-Host "Evidence:       $(@($Assessment.Reasons) -join ', ')"
}

function Get-UpdateRoot {
    param([string]$ProjectRoot)

    $updateRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ".agent-zero-update"))
    $projectBoundary = $ProjectRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $updateRoot.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $updateRoot) -ne ".agent-zero-update") {
        throw "AZ-UPDATE-PATH: invalid transaction root."
    }
    if (Test-Path -LiteralPath $updateRoot) {
        Assert-NoReparseTree -Root $updateRoot -ErrorCode "AZ-UPDATE-PATH"
    }
    return $updateRoot
}

function Assert-UpdateLockHeld {
    param([string]$ProjectRoot)

    if ($null -eq $script:UpdateLockStream) {
        throw "AZ-UPDATE-LOCK: a mutating update operation requires the exclusive update lock."
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot) -and
        [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/') -ne $script:UpdateLockProjectRoot) {
        throw "AZ-UPDATE-LOCK: the held lock belongs to a different project root."
    }
}

function Enter-UpdateLock {
    param([string]$ProjectRoot)

    if ($null -ne $script:UpdateLockStream) {
        throw "AZ-UPDATE-LOCK: this process already holds an update lock."
    }
    $updateRoot = Get-UpdateRoot -ProjectRoot $ProjectRoot
    New-Item -ItemType Directory -Force -Path $updateRoot | Out-Null
    Assert-NoReparseTree -Root $updateRoot -ErrorCode "AZ-UPDATE-PATH"
    $lockPath = Join-Path $updateRoot "UPDATE.lock"
    try {
        $script:UpdateLockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $script:UpdateLockProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    }
    catch [System.IO.IOException] {
        throw "AZ-UPDATE-LOCKED: another Agent Zero update process owns the project lock."
    }

    try {
        $lockText = "PID=$PID`r`nAcquiredAt=$((Get-Date).ToString('o'))`r`n"
        $lockBytes = [System.Text.Encoding]::ASCII.GetBytes($lockText)
        $script:UpdateLockStream.SetLength(0)
        $script:UpdateLockStream.Write($lockBytes, 0, $lockBytes.Length)
        $script:UpdateLockStream.Flush()
        Write-Utf8File -Path (Join-Path $updateRoot ".gitignore") -Content "*`r`n!.gitignore`r`n"
    }
    catch {
        $script:UpdateLockStream.Dispose()
        $script:UpdateLockStream = $null
        $script:UpdateLockProjectRoot = $null
        throw
    }
}

function Exit-UpdateLock {
    if ($null -ne $script:UpdateLockStream) {
        $script:UpdateLockStream.Dispose()
        $script:UpdateLockStream = $null
        $script:UpdateLockProjectRoot = $null
    }
}

function Copy-VerifiedFileAtomic {
    param([string]$Source, [string]$Destination)

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = "$Destination.$([Guid]::NewGuid().ToString('N')).tmp"
    Copy-Item -LiteralPath $Source -Destination $temporaryPath -Force
    if ((Get-Sha256 $temporaryPath) -ne (Get-Sha256 $Source)) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        throw "AZ-UPDATE-RECOVERY: recovery engine copy failed hash verification."
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backupPath = "$Destination.replace-backup"
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
        [System.IO.File]::Replace($temporaryPath, $Destination, $backupPath)
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
    else {
        [System.IO.File]::Move($temporaryPath, $Destination)
    }
}

function Initialize-RecoveryTools {
    param([string]$ProjectRoot, [string]$EnginePath)

    Assert-UpdateLockHeld -ProjectRoot $ProjectRoot
    $updateRoot = Get-UpdateRoot -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) {
        throw "AZ-UPDATE-RECOVERY: current recovery engine source is missing."
    }
    $recoveryRoot = Join-Path $updateRoot "recovery"
    $recoveryEngine = Join-Path $recoveryRoot "update-agent-zero.ps1"
    Copy-VerifiedFileAtomic -Source $EnginePath -Destination $recoveryEngine

    $launcher = @(
        "@echo off",
        "setlocal",
        'set "PROJECT_ROOT=%~dp0.."',
        'set "ENGINE=%~dp0recovery\update-agent-zero.ps1"',
        "where powershell.exe >nul 2>&1",
        "if errorlevel 1 (",
        "  echo AZ-UPDATE-POWERSHELL-MISSING",
        "  echo Windows PowerShell 5 or newer is required.",
        "  pause",
        "  exit /b 1",
        ")",
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ENGINE%" -TargetPath "%PROJECT_ROOT%" -Recover -LauncherOwnsFailurePause',
        'set "EXIT_CODE=%ERRORLEVEL%"',
        "echo.",
        'if not "%EXIT_CODE%"=="0" echo Recovery stopped safely. Review the error above.',
        "pause",
        "exit /b %EXIT_CODE%"
    )
    Write-Utf8File -Path (Join-Path $updateRoot "RECOVER.cmd") -Content (($launcher -join "`r`n") + "`r`n")
}

function Get-TransactionRoot {
    param([string]$ProjectRoot, [string]$TransactionId)

    if ($TransactionId -notmatch '^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$') {
        throw "AZ-UPDATE-TRANSACTION: invalid transaction ID."
    }
    $updateRoot = Get-UpdateRoot -ProjectRoot $ProjectRoot
    $transactionsRoot = [System.IO.Path]::GetFullPath((Join-Path $updateRoot "transactions"))
    $transactionRoot = [System.IO.Path]::GetFullPath((Join-Path $transactionsRoot $TransactionId))
    $boundary = $transactionsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $transactionRoot.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $transactionRoot) -ne $TransactionId) {
        throw "AZ-UPDATE-PATH: transaction path escaped the update root."
    }
    return $transactionRoot
}

function Write-Journal {
    param([string]$TransactionRoot, [object]$Journal)

    $Journal.updatedAt = (Get-Date).ToString("o")
    Write-JsonAtomic -Path (Join-Path $TransactionRoot "TRANSACTION.json") -Value $Journal
}

function Write-ActivePointer {
    param([string]$ProjectRoot, [object]$Journal)

    Assert-UpdateLockHeld -ProjectRoot $ProjectRoot
    $pointerPath = Join-Path (Get-UpdateRoot -ProjectRoot $ProjectRoot) "ACTIVE_TRANSACTION.json"
    if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
        try {
            $existingPointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json
        }
        catch {
            throw "AZ-UPDATE-TRANSACTION: refusing to overwrite an invalid active transaction pointer."
        }
        if ($existingPointer.schema -ne 1) {
            throw "AZ-UPDATE-TRANSACTION: refusing to overwrite a pointer with an unsupported schema."
        }
        if ([string]$existingPointer.transactionId -ne [string]$Journal.transactionId) {
            throw "AZ-UPDATE-TRANSACTION: refusing to overwrite another transaction pointer."
        }
    }
    $pointer = [ordered]@{
        schema = 1
        transactionId = [string]$Journal.transactionId
        state = [string]$Journal.state
        updatedAt = (Get-Date).ToString("o")
    }
    Write-JsonAtomic -Path $pointerPath -Value $pointer
}

function Remove-ActivePointer {
    param([string]$ProjectRoot, [string]$ExpectedTransactionId)

    Assert-UpdateLockHeld -ProjectRoot $ProjectRoot
    $pointerPath = Join-Path (Get-UpdateRoot -ProjectRoot $ProjectRoot) "ACTIVE_TRANSACTION.json"
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        return
    }
    $pointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json
    if ([string]$pointer.transactionId -ne $ExpectedTransactionId) {
        throw "AZ-UPDATE-TRANSACTION: refusing to remove another transaction pointer."
    }
    Remove-Item -LiteralPath $pointerPath -Force
}

function Get-ActiveJournal {
    param([string]$ProjectRoot)

    $pointerPath = Join-Path (Get-UpdateRoot -ProjectRoot $ProjectRoot) "ACTIVE_TRANSACTION.json"
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        return $null
    }
    try {
        $pointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json
    }
    catch {
        throw "AZ-UPDATE-TRANSACTION: active transaction pointer is invalid."
    }
    if ($pointer.schema -ne 1) {
        throw "AZ-UPDATE-TRANSACTION: unsupported pointer schema."
    }
    $transactionRoot = Get-TransactionRoot -ProjectRoot $ProjectRoot -TransactionId ([string]$pointer.transactionId)
    $journalPath = Join-Path $transactionRoot "TRANSACTION.json"
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "AZ-UPDATE-TRANSACTION: active journal is missing: $transactionRoot"
    }
    try {
        $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
    }
    catch {
        throw "AZ-UPDATE-TRANSACTION: active journal is invalid."
    }
    if ($journal.schema -ne 1 -or [string]$journal.transactionId -ne [string]$pointer.transactionId) {
        throw "AZ-UPDATE-TRANSACTION: pointer and journal do not agree."
    }
    return [pscustomobject]@{
        Root = $transactionRoot
        Journal = $journal
    }
}

function Write-UpdateResult {
    param(
        [string]$StageProjectRoot,
        [object]$Journal,
        [string]$Status
    )

    $lines = @(
        "# Agent Zero Update Result",
        "",
        "- Status: $Status",
        "- From: $($Journal.installedVersion)",
        "- To: $($Journal.targetVersion)",
        "- Declared mode: $($Journal.declaredMode)",
        "- Effective mode: $($Journal.effectiveMode)",
        "- Source core identity: VERIFIED",
        "- Context activation: $(if ($Journal.mutatesAgent) { 'STAGED_MIGRATION' } else { 'PRESERVE_BYTES' })",
        "- Transaction: $($Journal.transactionId)",
        "- Snapshot retained: .agent-zero-update/transactions/$($Journal.transactionId)/snapshot"
    )
    Write-Utf8File -Path (Join-Path $StageProjectRoot ".agent-zero/UPDATE_RESULT.md") -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Install-PayloadIntoStage {
    param([string]$KitRoot, [string]$StageProjectRoot)

    $stageAgentZero = Join-Path $StageProjectRoot ".agent-zero"
    New-Item -ItemType Directory -Force -Path $stageAgentZero | Out-Null
    foreach ($fileName in @("VERSION", "TESTING.md", "START.md")) {
        Copy-Item -LiteralPath (Join-Path $KitRoot "payload/$fileName") -Destination (Join-Path $stageAgentZero $fileName) -Force
    }
    foreach ($fileName in @("UPDATE.cmd", "UPDATE.md", "UPDATE_MANIFEST.json")) {
        Copy-Item -LiteralPath (Join-Path $KitRoot $fileName) -Destination (Join-Path $stageAgentZero $fileName) -Force
    }
    foreach ($directoryName in @("references", "templates", "scripts")) {
        Copy-DirectoryContents -Source (Join-Path $KitRoot "payload/$directoryName") -Destination (Join-Path $stageAgentZero $directoryName)
    }
    $nextStepsPath = Join-Path $stageAgentZero "NEXT_STEPS.md"
    if (-not (Test-Path -LiteralPath $nextStepsPath -PathType Leaf)) {
        $nextSteps = @(
            "# Agent Zero - Buoc tiep theo",
            "",
            "- Ket qua: CAI DAT THANH CONG",
            "- Auto-detect: UPDATE",
            "",
            "Khoi dong Agent Zero theo .agent-zero/START.md",
            "",
            "Lan sau nhap dup .agent-zero/UPDATE.cmd de kiem tra ban moi."
        )
        Write-Utf8File -Path $nextStepsPath -Content (($nextSteps -join [Environment]::NewLine) + [Environment]::NewLine)
    }
}

function Invoke-StageValidation {
    param([string]$StageProjectRoot, [object]$Journal)

    $validator = Join-Path $StageProjectRoot ".agent-zero/scripts/validate-install.ps1"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "AZ-UPDATE-VALIDATION: staged install validator is missing."
    }
    & $validator -Mode ([string]$Journal.validationMode) | Out-Null
}

function Write-SemanticPrompt {
    param([string]$ProjectRoot, [string]$TransactionRoot, [object]$Journal)

    $stageProject = Join-Path $TransactionRoot "stage/project"
    $snapshotRoot = Join-Path $TransactionRoot "snapshot"
    $enginePath = Join-Path $ProjectRoot ".agent-zero-update/recovery/update-agent-zero.ps1"
    $reportPath = Join-Path $TransactionRoot "AI_MIGRATION_REPORT.md"
    $promptPath = Join-Path $TransactionRoot "AI_UPDATE_PROMPT.md"
    $lines = @(
        "# Prompt ho tro update Agent Zero",
        "",
        "Ban la agent AI hien tai cua user; khong gia dinh ban la Codex, Claude, Gemini hay nha cung cap cu the nao.",
        "",
        "Muc tieu: review/migrate Agent Zero $($Journal.installedVersion) -> $($Journal.targetVersion) cho transaction $($Journal.transactionId), chi trong staging.",
        "",
        "Live project: $ProjectRoot",
        "Staging project: $stageProject",
        "Raw snapshot: $snapshotRoot",
        "Journal: $(Join-Path $TransactionRoot 'TRANSACTION.json')",
        "Report phai tao: $reportPath",
        "",
        "Rang buoc:",
        "- Khong sua, rename, delete hoac overwrite bat ky file live nao. Chi ghi trong staging va report cua transaction.",
        "- Doc manifest, journal, core cu trong snapshot va core moi trong staging; giu goal, user decision, fact, lesson, current state, provenance va unknown.",
        "- Khong sua .agents hoac .codex; capability ngoai Agent Zero la read-only.",
        "- Khong bien assumption thanh fact, khong tu giai quyet conflict product intent va khong tu tuyen bo semantic equivalence.",
        "- Neu can chuyen project memory, tao patch nho nhat trong staging, giu nguyen raw snapshot va chay validator cua staging.",
        "- Report phai co ba dong chinh xac: Live paths modified: NO; Stage validation: PASS; User approval: CONFIRMED.",
        "- Truoc dong User approval: CONFIRMED, trinh bay mapping/thay doi/unknown cho user va chi ghi CONFIRMED sau khi user chap nhan ro rang.",
        "",
        "Sau khi report va validation da pass, chay lenh PowerShell sau:",
        "& ""$enginePath"" -TargetPath ""$ProjectRoot"" -FinalizeTransaction ""$($Journal.transactionId)"" -ApproveSemanticMigration -NonInteractive",
        "",
        "Neu evidence mau thuan, live context da doi hoac user chua chap nhan, dung; khong chay finalizer."
    )
    Write-Utf8File -Path $promptPath -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    if (-not $NoClipboard) {
        try {
            Set-Clipboard -Value (($lines -join [Environment]::NewLine)) -ErrorAction Stop
            Write-Host "AZ-UPDATE-PROMPT-COPIED" -ForegroundColor Green
        }
        catch {
            Write-Host "AZ-UPDATE-PROMPT-NOT-COPIED: copy manually from $promptPath" -ForegroundColor Yellow
        }
    }
    return $promptPath
}

function Invoke-VerifiedMigrator {
    param(
        [string]$MigratorPath,
        [string]$StageProjectRoot,
        [string]$LiveProjectRoot,
        [object]$Journal,
        [string]$FromVersion,
        [string]$ToVersion
    )

    $nonAsciiByte = [System.IO.File]::ReadAllBytes($MigratorPath) | Where-Object { $_ -gt 127 } | Select-Object -First 1
    if ($null -ne $nonAsciiByte) {
        throw "AZ-UPDATE-MIGRATION: migrator source must be ASCII for Windows PowerShell 5."
    }

    $isolationRoot = New-TemporaryRoot
    $isolatedProject = Join-Path $isolationRoot "project"
    $isolatedMigrations = Join-Path $isolationRoot "migrations"
    Copy-DirectoryContents -Source $StageProjectRoot -Destination $isolatedProject
    Copy-DirectoryContents -Source (Split-Path -Parent $MigratorPath) -Destination $isolatedMigrations
    $isolatedMigrator = Join-Path $isolatedMigrations (Split-Path -Leaf $MigratorPath)
    $runnerPath = Join-Path $isolationRoot "run-migrator.ps1"
    $runner = @'
param(
    [string]$MigratorPath,
    [string]$ProjectRoot,
    [string]$FromVersion,
    [string]$ToVersion
)
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues["Get-Content:Encoding"] = "UTF8"
$PSDefaultParameterValues["Set-Content:Encoding"] = "UTF8"
$PSDefaultParameterValues["Add-Content:Encoding"] = "UTF8"
$PSDefaultParameterValues["Out-File:Encoding"] = "UTF8"
try {
    & $MigratorPath -ProjectRoot $ProjectRoot -FromVersion $FromVersion -ToVersion $ToVersion
    if (-not $?) {
        exit 1
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    Write-Utf8File -Path $runnerPath -Content ($runner + [Environment]::NewLine)

    $boundaryBefore = Get-BoundaryFingerprint -Root $isolationRoot -ExcludedRelativePaths @("project/.agent")
    $hostExecutable = if ($PSVersionTable.PSEdition -eq "Core") {
        Join-Path $PSHOME "pwsh.exe"
    }
    else {
        Join-Path $PSHOME "powershell.exe"
    }
    if (-not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
        throw "AZ-UPDATE-MIGRATION: current PowerShell host executable is unavailable."
    }
    Push-Location -LiteralPath $isolationRoot
    try {
        $migrationOutput = & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $runnerPath -MigratorPath $isolatedMigrator -ProjectRoot $isolatedProject -FromVersion $FromVersion -ToVersion $ToVersion 2>&1
        $migrationExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    foreach ($line in @($migrationOutput)) {
        Write-Host ([string]$line)
    }
    if ($migrationExitCode -ne 0) {
        throw "AZ-UPDATE-MIGRATION: isolated migrator failed with exit code $migrationExitCode."
    }
    $boundaryAfter = Get-BoundaryFingerprint -Root $isolationRoot -ExcludedRelativePaths @("project/.agent")
    if ($boundaryAfter -ne $boundaryBefore) {
        throw "AZ-UPDATE-MIGRATION-BOUNDARY: migrator wrote outside the isolated project/.agent allowlist."
    }

    $isolatedAgent = Join-Path $isolatedProject ".agent"
    if (-not (Test-Path -LiteralPath $isolatedAgent -PathType Container)) {
        throw "AZ-UPDATE-MIGRATION: isolated migrator removed project memory."
    }
    Assert-NoReparseTree -Root $isolatedAgent -ErrorCode "AZ-UPDATE-MIGRATION-BOUNDARY"
    if (-not (Test-LiveBaseline -ProjectRoot $LiveProjectRoot -Journal $Journal)) {
        throw "AZ-UPDATE-MIGRATION-LIVE-MUTATION: live core or context changed while the isolated migrator ran."
    }
    $incomingAgent = Join-Path $StageProjectRoot (".agent-migrated-" + [Guid]::NewGuid().ToString("N"))
    Copy-DirectoryContents -Source $isolatedAgent -Destination $incomingAgent
    if ((Get-BoundaryFingerprint -Root $incomingAgent) -ne (Get-BoundaryFingerprint -Root $isolatedAgent)) {
        throw "AZ-UPDATE-MIGRATION: isolated project memory copy failed verification."
    }
    $stageAgent = Join-Path $StageProjectRoot ".agent"
    $previousStageAgent = Join-Path $StageProjectRoot (".agent-before-migration-" + [Guid]::NewGuid().ToString("N"))
    Move-Item -LiteralPath $stageAgent -Destination $previousStageAgent
    try {
        Move-Item -LiteralPath $incomingAgent -Destination $stageAgent
    }
    catch {
        if (-not (Test-Path -LiteralPath $stageAgent) -and (Test-Path -LiteralPath $previousStageAgent -PathType Container)) {
            Move-Item -LiteralPath $previousStageAgent -Destination $stageAgent
        }
        throw
    }
    Remove-Item -LiteralPath $previousStageAgent -Recurse -Force
}

function New-UpdateTransaction {
    param(
        [string]$ProjectRoot,
        [object]$Assessment,
        [object]$Bundle
    )

    Assert-UpdateLockHeld -ProjectRoot $ProjectRoot
    if ($null -ne (Get-ActiveJournal -ProjectRoot $ProjectRoot)) {
        throw "AZ-UPDATE-TRANSACTION: another update transaction is active."
    }
    $updateRoot = Get-UpdateRoot -ProjectRoot $ProjectRoot
    if ((Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot ".agent-zero/VERSION")).Trim() -ne [string]$Assessment.InstalledVersion -or
        (Get-Sha256 (Join-Path $ProjectRoot $Assessment.CoreRelativePath)) -ne [string]$Assessment.CoreSha256) {
        throw "AZ-UPDATE-STALE-ASSESSMENT: installed version or core changed after update assessment."
    }
    Initialize-RecoveryTools -ProjectRoot $ProjectRoot -EnginePath $script:CurrentEnginePath
    New-Item -ItemType Directory -Force -Path (Join-Path $updateRoot "transactions") | Out-Null
    $transactionId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    $transactionRoot = Get-TransactionRoot -ProjectRoot $ProjectRoot -TransactionId $transactionId
    $snapshotRoot = Join-Path $transactionRoot "snapshot"
    $stageProject = Join-Path $transactionRoot "stage/project"
    $packageRoot = Join-Path $transactionRoot "package/agent-zero-kit"
    New-Item -ItemType Directory -Force -Path $snapshotRoot, $stageProject, $packageRoot | Out-Null

    $mutatesAgent = $Assessment.EffectiveMode -ne "CORE_ONLY" -and $Assessment.ValidationMode -eq "UpgradeActive"
    $externalProtectedPaths = @($Bundle.ManifestRecord.Model.protectedPaths | Where-Object { $_ -ne ".agent/**" })
    $baseline = [ordered]@{
        core = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @([string]$Assessment.CoreRelativePath)
        agentZero = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent-zero/**")
        agent = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent/**")
        external = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths $externalProtectedPaths
    }
    $journal = [pscustomobject][ordered]@{
        schema = 1
        transactionId = $transactionId
        state = "PREPARING"
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
        projectRoot = $ProjectRoot
        installedVersion = [string]$Assessment.InstalledVersion
        targetVersion = [string]$Assessment.TargetVersion
        declaredMode = [string]$Assessment.DeclaredMode
        localMode = [string]$Assessment.LocalMode
        effectiveMode = [string]$Assessment.EffectiveMode
        reasons = @($Assessment.Reasons)
        coreRelativePath = [string]$Assessment.CoreRelativePath
        coreBeforeSha256 = [string]$Assessment.CoreSha256
        targetCoreSha256 = ([string]$Bundle.ManifestRecord.Model.targetCoreSha256).ToUpperInvariant()
        validationMode = [string]$Assessment.ValidationMode
        mutatesAgent = [bool]$mutatesAgent
        migrator = if ($null -eq $Assessment.Transition.migrator) { $null } else { [string]$Assessment.Transition.migrator }
        source = [string]$Bundle.Source
        manifestSha256 = [string]$Bundle.ManifestRecord.Sha256
        baseline = $baseline
        activationStep = "NONE"
        snapshotVerified = $false
        stageValidated = $false
        semanticApprovalRequired = $Assessment.EffectiveMode -eq "SEMANTIC_REVIEW"
        packageFingerprint = ""
        stageAgentZeroFingerprint = ""
    }
    Write-Journal -TransactionRoot $transactionRoot -Journal $journal
    Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal

    Copy-DirectoryContents -Source $Bundle.KitRoot -Destination $packageRoot
    $packagedManifest = Read-UpdateManifest -Path (Join-Path $packageRoot "UPDATE_MANIFEST.json")
    if ($packagedManifest.Sha256 -ne $journal.manifestSha256) {
        throw "AZ-UPDATE-HASH: transaction package changed during copy."
    }
    Assert-Kit -KitRoot $packageRoot -ManifestRecord $packagedManifest
    $journal.packageFingerprint = Get-PathFingerprint -ProjectRoot $transactionRoot -RelativePaths @("package/**")
    Write-Journal -TransactionRoot $transactionRoot -Journal $journal
    Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal

    Copy-DirectoryContents -Source (Join-Path $ProjectRoot ".agent-zero") -Destination (Join-Path $snapshotRoot ".agent-zero")
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $Assessment.CoreRelativePath) -Destination (Join-Path $snapshotRoot $Assessment.CoreRelativePath) -Force
    if ($mutatesAgent) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot ".agent") -PathType Container)) {
            throw "AZ-UPDATE-SNAPSHOT: active memory is missing."
        }
        Copy-DirectoryContents -Source (Join-Path $ProjectRoot ".agent") -Destination (Join-Path $snapshotRoot ".agent")
    }
    if ((Get-PathFingerprint -ProjectRoot $snapshotRoot -RelativePaths @(".agent-zero/**")) -ne $baseline.agentZero -or
        (Get-PathFingerprint -ProjectRoot $snapshotRoot -RelativePaths @([string]$Assessment.CoreRelativePath)) -ne $baseline.core -or
        ($mutatesAgent -and (Get-PathFingerprint -ProjectRoot $snapshotRoot -RelativePaths @(".agent/**")) -ne $baseline.agent)) {
        throw "AZ-UPDATE-SNAPSHOT: snapshot hash verification failed."
    }
    $journal.snapshotVerified = $true
    Write-Journal -TransactionRoot $transactionRoot -Journal $journal
    Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal

    Copy-DirectoryContents -Source (Join-Path $ProjectRoot ".agent-zero") -Destination (Join-Path $stageProject ".agent-zero")
    if ($Assessment.ValidationMode -eq "UpgradeActive") {
        Copy-DirectoryContents -Source (Join-Path $ProjectRoot ".agent") -Destination (Join-Path $stageProject ".agent")
    }
    Copy-Item -LiteralPath (Join-Path $packageRoot "AGENT_ZERO_CANDIDATE.md") -Destination (Join-Path $stageProject $Assessment.CoreRelativePath) -Force
    Install-PayloadIntoStage -KitRoot $packageRoot -StageProjectRoot $stageProject
    Write-UpdateResult -StageProjectRoot $stageProject -Journal $journal -Status "PREPARED"
    $journal.stageAgentZeroFingerprint = Get-PathFingerprint -ProjectRoot $stageProject -RelativePaths @(".agent-zero/**")

    if ($Assessment.EffectiveMode -eq "LOSSLESS_SCRIPTED") {
        if (-not $mutatesAgent) {
            throw "AZ-UPDATE-MIGRATION: scripted project-memory migration is unavailable in candidate adoption mode."
        }
        if ([string]::IsNullOrWhiteSpace([string]$journal.migrator)) {
            throw "AZ-UPDATE-MIGRATION: transition did not provide a migrator."
        }
        $migratorPath = Join-Path $packageRoot ([string]$journal.migrator)
        if (-not (Test-Path -LiteralPath $migratorPath -PathType Leaf)) {
            throw "AZ-UPDATE-MIGRATION: migrator is missing from verified kit."
        }
        if (-not (Test-LiveBaseline -ProjectRoot $ProjectRoot -Journal $journal)) {
            throw "AZ-UPDATE-STALE_BASELINE: live core or context changed before the isolated migrator ran."
        }
        Invoke-VerifiedMigrator -MigratorPath $migratorPath -StageProjectRoot $stageProject -LiveProjectRoot $ProjectRoot -Journal $journal -FromVersion $journal.installedVersion -ToVersion $journal.targetVersion
        if (-not (Test-LiveBaseline -ProjectRoot $ProjectRoot -Journal $journal)) {
            throw "AZ-UPDATE-MIGRATION-LIVE-MUTATION: live core or context changed while the isolated migrator ran."
        }
    }

    if ($Assessment.EffectiveMode -eq "SEMANTIC_REVIEW") {
        $journal.state = "AWAITING_AI"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        $promptPath = Write-SemanticPrompt -ProjectRoot $ProjectRoot -TransactionRoot $transactionRoot -Journal $journal
        Write-Host "AZ-UPDATE-AWAITING_AI" -ForegroundColor Yellow
        Write-Host "Live context was not changed."
        Write-Host "Prompt: $promptPath"
    }
    else {
        Invoke-StageValidation -StageProjectRoot $stageProject -Journal $journal
        $journal.stageValidated = $true
        $journal.state = "READY_TO_ACTIVATE"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        Write-Host "AZ-UPDATE-READY_TO_ACTIVATE" -ForegroundColor Green
        Write-Host "Transaction: $transactionId"
    }

    return [pscustomobject]@{
        Root = $transactionRoot
        Journal = $journal
    }
}

function Test-LiveBaseline {
    param([string]$ProjectRoot, [object]$Journal)

    $manifest = (Read-UpdateManifest -Path (Join-Path (Get-TransactionRoot -ProjectRoot $ProjectRoot -TransactionId $Journal.transactionId) "package/agent-zero-kit/UPDATE_MANIFEST.json")).Model
    $externalProtectedPaths = @($manifest.protectedPaths | Where-Object { $_ -ne ".agent/**" })
    $current = [ordered]@{
        core = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @([string]$Journal.coreRelativePath)
        agentZero = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent-zero/**")
        agent = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent/**")
        external = Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths $externalProtectedPaths
    }
    return (
        $current.core -eq [string]$Journal.baseline.core -and
        $current.agentZero -eq [string]$Journal.baseline.agentZero -and
        $current.agent -eq [string]$Journal.baseline.agent -and
        $current.external -eq [string]$Journal.baseline.external
    )
}

function Assert-TransactionStage {
    param([string]$ProjectRoot, [string]$TransactionRoot, [object]$Journal)

    $packageRoot = Join-Path $TransactionRoot "package/agent-zero-kit"
    $stageProject = Join-Path $TransactionRoot "stage/project"
    $manifestRecord = Read-UpdateManifest -Path (Join-Path $packageRoot "UPDATE_MANIFEST.json")
    if ($manifestRecord.Sha256 -ne [string]$Journal.manifestSha256) {
        throw "AZ-UPDATE-HASH: transaction manifest changed after preparation."
    }
    Assert-Kit -KitRoot $packageRoot -ManifestRecord $manifestRecord
    if ((Get-Sha256 (Join-Path $stageProject $Journal.coreRelativePath)) -ne [string]$Journal.targetCoreSha256) {
        throw "AZ-UPDATE-HASH: staged core changed after preparation."
    }
    if ($null -ne $Journal.PSObject.Properties["stageAgentZeroFingerprint"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Journal.stageAgentZeroFingerprint) -and
        (Get-PathFingerprint -ProjectRoot $stageProject -RelativePaths @(".agent-zero/**")) -ne [string]$Journal.stageAgentZeroFingerprint) {
        throw "AZ-UPDATE-STAGE-DRIFT: staged Agent Zero system files changed."
    }
    if ($null -ne $Journal.PSObject.Properties["packageFingerprint"] -and
        -not [string]::IsNullOrWhiteSpace([string]$Journal.packageFingerprint) -and
        (Get-PathFingerprint -ProjectRoot $TransactionRoot -RelativePaths @("package/**")) -ne [string]$Journal.packageFingerprint) {
        throw "AZ-UPDATE-STAGE-DRIFT: verified package changed after preparation."
    }
}

function Assert-SemanticApproval {
    param([string]$TransactionRoot)

    $reportPath = Join-Path $TransactionRoot "AI_MIGRATION_REPORT.md"
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "AZ-UPDATE-APPROVAL: AI_MIGRATION_REPORT.md is missing."
    }
    $report = Get-Content -Raw -LiteralPath $reportPath
    foreach ($marker in @(
        "Live paths modified: NO",
        "Stage validation: PASS",
        "User approval: CONFIRMED"
    )) {
        if (-not $report.Contains($marker)) {
            throw "AZ-UPDATE-APPROVAL: migration report is missing marker: $marker"
        }
    }
}

function Save-RecoveryConflict {
    param([string]$Source, [string]$ConflictRoot, [string]$Name)

    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }
    New-Item -ItemType Directory -Force -Path $ConflictRoot | Out-Null
    $destination = Join-Path $ConflictRoot $Name
    if ((Get-Item -Force -LiteralPath $Source).PSIsContainer) {
        Copy-DirectoryContents -Source $Source -Destination $destination
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $destination -Force
    }
}

function Restore-Transaction {
    param([string]$ProjectRoot, [string]$TransactionRoot, [object]$Journal, [string]$Reason)

    $snapshotRoot = Join-Path $TransactionRoot "snapshot"
    $snapshotAgentZero = Join-Path $snapshotRoot ".agent-zero"
    $snapshotCore = Join-Path $snapshotRoot $Journal.coreRelativePath
    if (-not (Test-Path -LiteralPath $snapshotAgentZero -PathType Container) -or
        -not (Test-Path -LiteralPath $snapshotCore -PathType Leaf)) {
        throw "AZ-UPDATE-RECOVERY: verified snapshot is incomplete."
    }
    $journal.state = "ROLLING_BACK"
    $journal.activationStep = "RESTORE_STARTED"
    Write-Journal -TransactionRoot $TransactionRoot -Journal $journal
    Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal

    $conflictRoot = Join-Path $TransactionRoot ("recovery-conflicts/" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    $liveAgentZero = Join-Path $ProjectRoot ".agent-zero"
    $liveCore = Join-Path $ProjectRoot $Journal.coreRelativePath
    Save-RecoveryConflict -Source $liveAgentZero -ConflictRoot $conflictRoot -Name ".agent-zero"
    Save-RecoveryConflict -Source $liveCore -ConflictRoot $conflictRoot -Name $Journal.coreRelativePath
    if ([bool]$Journal.mutatesAgent) {
        Save-RecoveryConflict -Source (Join-Path $ProjectRoot ".agent") -ConflictRoot $conflictRoot -Name ".agent"
    }

    if (Test-Path -LiteralPath $liveAgentZero) {
        Remove-Item -LiteralPath $liveAgentZero -Recurse -Force
    }
    Copy-DirectoryContents -Source $snapshotAgentZero -Destination $liveAgentZero
    Copy-Item -LiteralPath $snapshotCore -Destination $liveCore -Force
    if ([bool]$Journal.mutatesAgent) {
        $liveAgent = Join-Path $ProjectRoot ".agent"
        if (Test-Path -LiteralPath $liveAgent) {
            Remove-Item -LiteralPath $liveAgent -Recurse -Force
        }
        Copy-DirectoryContents -Source (Join-Path $snapshotRoot ".agent") -Destination $liveAgent
    }

    if ((Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent-zero/**")) -ne [string]$Journal.baseline.agentZero -or
        (Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @([string]$Journal.coreRelativePath)) -ne [string]$Journal.baseline.core -or
        ([bool]$Journal.mutatesAgent -and (Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent/**")) -ne [string]$Journal.baseline.agent)) {
        throw "AZ-UPDATE-RECOVERY: rollback hash verification failed. Snapshot: $snapshotRoot"
    }
    $journal.state = "ROLLED_BACK"
    $journal.activationStep = "RESTORE_VERIFIED"
    if ($null -eq $Journal.PSObject.Properties["recoveryReason"]) {
        $journal | Add-Member -NotePropertyName recoveryReason -NotePropertyValue $Reason
    }
    else {
        $journal.recoveryReason = $Reason
    }
    Write-Journal -TransactionRoot $TransactionRoot -Journal $journal
    Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
    Remove-ActivePointer -ProjectRoot $ProjectRoot -ExpectedTransactionId $Journal.transactionId
    Write-Host "AZ-UPDATE-ROLLED_BACK" -ForegroundColor Yellow
    Write-Host "Snapshot restored and retained: $snapshotRoot"
    Write-Host "Any partial live tree was retained under: $conflictRoot"
}

function Invoke-FinalizeTransaction {
    param(
        [string]$ProjectRoot,
        [string]$TransactionId,
        [switch]$SemanticApproval
    )

    Assert-UpdateLockHeld -ProjectRoot $ProjectRoot
    $transactionRoot = Get-TransactionRoot -ProjectRoot $ProjectRoot -TransactionId $TransactionId
    $journalPath = Join-Path $transactionRoot "TRANSACTION.json"
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "AZ-UPDATE-TRANSACTION: transaction journal is missing."
    }
    $journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
    $active = Get-ActiveJournal -ProjectRoot $ProjectRoot
    if ($null -eq $active -or [string]$active.Journal.transactionId -ne $TransactionId) {
        throw "AZ-UPDATE-TRANSACTION: transaction is not the active transaction."
    }
    if ([string]$journal.state -notin @("READY_TO_ACTIVATE", "AWAITING_AI")) {
        throw "AZ-UPDATE-TRANSACTION: transaction cannot be finalized from state $($journal.state)."
    }
    if ([bool]$journal.semanticApprovalRequired) {
        if (-not $SemanticApproval) {
            throw "AZ-UPDATE-APPROVAL: semantic migration requires explicit approval."
        }
        Assert-SemanticApproval -TransactionRoot $transactionRoot
    }

    Assert-TransactionStage -ProjectRoot $ProjectRoot -TransactionRoot $transactionRoot -Journal $journal
    if (-not (Test-LiveBaseline -ProjectRoot $ProjectRoot -Journal $journal)) {
        $journal.state = "STALE_BASELINE"
        $journal.activationStep = "NONE"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        Remove-ActivePointer -ProjectRoot $ProjectRoot -ExpectedTransactionId $TransactionId
        throw "AZ-UPDATE-STALE_BASELINE: live core or context changed after preparation; no live update was activated."
    }

    $stageProject = Join-Path $transactionRoot "stage/project"
    Invoke-StageValidation -StageProjectRoot $stageProject -Journal $journal
    $journal.stageValidated = $true
    $expectedAgentFingerprint = if ([bool]$journal.mutatesAgent) {
        Get-PathFingerprint -ProjectRoot $stageProject -RelativePaths @(".agent/**")
    }
    else {
        [string]$journal.baseline.agent
    }
    $journal | Add-Member -Force -NotePropertyName expectedAgentFingerprint -NotePropertyValue $expectedAgentFingerprint
    Write-UpdateResult -StageProjectRoot $stageProject -Journal $journal -Status "COMMITTED"
    $journal.stageAgentZeroFingerprint = Get-PathFingerprint -ProjectRoot $stageProject -RelativePaths @(".agent-zero/**")
    $journal.state = "ACTIVATING"
    $journal.activationStep = "BEGIN"
    Write-Journal -TransactionRoot $transactionRoot -Journal $journal
    Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal

    $activationOldRoot = Join-Path $transactionRoot "activation-old"
    New-Item -ItemType Directory -Force -Path $activationOldRoot | Out-Null
    try {
        if ([bool]$journal.mutatesAgent) {
            $journal.activationStep = "REPLACE_AGENT_MEMORY"
            Write-Journal -TransactionRoot $transactionRoot -Journal $journal
            Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
            Move-Item -LiteralPath (Join-Path $ProjectRoot ".agent") -Destination (Join-Path $activationOldRoot ".agent")
            Move-Item -LiteralPath (Join-Path $stageProject ".agent") -Destination (Join-Path $ProjectRoot ".agent")
        }

        $journal.activationStep = "REPLACE_AGENT_ZERO"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        Move-Item -LiteralPath (Join-Path $ProjectRoot ".agent-zero") -Destination (Join-Path $activationOldRoot ".agent-zero")
        Move-Item -LiteralPath (Join-Path $stageProject ".agent-zero") -Destination (Join-Path $ProjectRoot ".agent-zero")

        $journal.activationStep = "REPLACE_CORE"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        Copy-Item -LiteralPath (Join-Path $stageProject $journal.coreRelativePath) -Destination (Join-Path $ProjectRoot $journal.coreRelativePath) -Force

        $journal.state = "VALIDATING"
        $journal.activationStep = "POST_ACTIVATION_VALIDATION"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        & (Join-Path $ProjectRoot ".agent-zero/scripts/validate-install.ps1") -Mode ([string]$journal.validationMode) | Out-Null
        if ((Get-Sha256 (Join-Path $ProjectRoot $journal.coreRelativePath)) -ne [string]$journal.targetCoreSha256) {
            throw "AZ-UPDATE-VALIDATION: live target core hash is wrong."
        }
        if ((Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot ".agent-zero/VERSION")).Trim() -ne [string]$journal.targetVersion) {
            throw "AZ-UPDATE-VALIDATION: live target version is wrong."
        }
        if ((Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths @(".agent/**")) -ne [string]$expectedAgentFingerprint) {
            throw "AZ-UPDATE-CONCURRENT-DRIFT: project memory changed during activation."
        }
        $manifest = (Read-UpdateManifest -Path (Join-Path $ProjectRoot ".agent-zero/UPDATE_MANIFEST.json")).Model
        $externalPaths = @($manifest.protectedPaths | Where-Object { $_ -ne ".agent/**" })
        if ((Get-PathFingerprint -ProjectRoot $ProjectRoot -RelativePaths $externalPaths) -ne [string]$journal.baseline.external) {
            throw "AZ-UPDATE-CONCURRENT-DRIFT: external user capability/context changed during activation."
        }

        $journal.state = "COMMITTED"
        $journal.activationStep = "COMPLETE"
        Write-Journal -TransactionRoot $transactionRoot -Journal $journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $journal
        Remove-ActivePointer -ProjectRoot $ProjectRoot -ExpectedTransactionId $TransactionId
        Write-Host "AZ-UPDATE-COMMITTED" -ForegroundColor Green
        Write-Host "Agent Zero $($journal.installedVersion) -> $($journal.targetVersion)"
        Write-Host "Context mode: $($journal.effectiveMode)"
        Write-Host "Snapshot retained: $(Join-Path $transactionRoot 'snapshot')"
        Write-Host "Open a new AI chat/session so the new core is loaded." -ForegroundColor Cyan
    }
    catch {
        $activationFailure = $_.Exception.Message
        Restore-Transaction -ProjectRoot $ProjectRoot -TransactionRoot $transactionRoot -Journal $journal -Reason $activationFailure
        throw "AZ-UPDATE-ACTIVATION-FAILED: $activationFailure"
    }
}

function Invoke-Recovery {
    param([string]$ProjectRoot)

    Assert-UpdateLockHeld -ProjectRoot $ProjectRoot
    $active = Get-ActiveJournal -ProjectRoot $ProjectRoot
    if ($null -eq $active) {
        Write-Host "AZ-UPDATE-NO-RECOVERY-NEEDED"
        return "NONE"
    }
    $state = [string]$active.Journal.state
    if ($state -in @("ACTIVATING", "VALIDATING", "ROLLING_BACK")) {
        Restore-Transaction -ProjectRoot $ProjectRoot -TransactionRoot $active.Root -Journal $active.Journal -Reason "Recovered interrupted state $state"
        return "ROLLED_BACK"
    }
    if ($state -eq "PREPARING") {
        $active.Journal.state = "ABORTED_PREPARATION"
        Write-Journal -TransactionRoot $active.Root -Journal $active.Journal
        Write-ActivePointer -ProjectRoot $ProjectRoot -Journal $active.Journal
        Remove-ActivePointer -ProjectRoot $ProjectRoot -ExpectedTransactionId $active.Journal.transactionId
        Write-Host "AZ-UPDATE-PREPARATION-ABORTED"
        Write-Host "Live installation was not mutated."
        return "ABORTED"
    }
    if ($state -in @("READY_TO_ACTIVATE", "AWAITING_AI")) {
        Write-Host "AZ-UPDATE-$state"
        Write-Host "No live mutation has started. Resume transaction: $($active.Journal.transactionId)"
        if ($state -eq "AWAITING_AI") {
            Write-Host "Prompt: $(Join-Path $active.Root 'AI_UPDATE_PROMPT.md')"
        }
        return "PENDING"
    }
    if ($state -in @("COMMITTED", "ROLLED_BACK", "STALE_BASELINE", "ABORTED_PREPARATION")) {
        Remove-ActivePointer -ProjectRoot $ProjectRoot -ExpectedTransactionId $active.Journal.transactionId
        Write-Host "AZ-UPDATE-TERMINAL-POINTER-CLEARED"
        return "CLEARED"
    }
    throw "AZ-UPDATE-RECOVERY: unknown transaction state cannot be cleared: $state"
}

function Select-UpdateAction {
    param([string]$EffectiveMode)

    if (-not $script:InteractiveMode) {
        return "CHECK"
    }
    Write-Host ""
    if ($EffectiveMode -eq "SEMANTIC_REVIEW") {
        Write-Host "P. Prepare staging va copy prompt cho agent AI hien tai"
    }
    else {
        Write-Host "U. Update bang snapshot, staging va validation"
        Write-Host "P. Chi prepare staging, chua activate"
    }
    Write-Host "Q. Dong, khong thay doi file"
    $choice = (Read-Host "Lua chon").Trim().ToUpperInvariant()
    if ($choice -eq "P") {
        return "PREPARE"
    }
    if ($choice -eq "U" -and $EffectiveMode -ne "SEMANTIC_REVIEW") {
        return "APPLY"
    }
    return "CANCEL"
}

try {
    $operationCount = 0
    foreach ($requestedOperation in @([bool]$CheckOnly, [bool]$Apply, [bool]$PrepareOnly, [bool]$Recover)) {
        if ($requestedOperation) {
            $operationCount++
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FinalizeTransaction)) {
        $operationCount++
    }
    if ($operationCount -gt 1) {
        throw "AZ-UPDATE-ARGUMENT: choose at most one operation: CheckOnly, Apply, PrepareOnly, Recover or FinalizeTransaction."
    }
    if ($ApproveSemanticMigration -and [string]::IsNullOrWhiteSpace($FinalizeTransaction)) {
        throw "AZ-UPDATE-ARGUMENT: ApproveSemanticMigration is valid only with FinalizeTransaction."
    }
    $projectRoot = Resolve-ProjectRoot -RequestedPath $TargetPath
    $implicitReadOnly = $NonInteractive -and $operationCount -eq 0

    if ($Recover) {
        Enter-UpdateLock -ProjectRoot $projectRoot
        [void](Invoke-Recovery -ProjectRoot $projectRoot)
        Exit-UpdateLock
        Wait-UpdateClose
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($FinalizeTransaction)) {
        Enter-UpdateLock -ProjectRoot $projectRoot
        Invoke-FinalizeTransaction -ProjectRoot $projectRoot -TransactionId $FinalizeTransaction -SemanticApproval:$ApproveSemanticMigration
        Exit-UpdateLock
        Wait-UpdateClose
        return
    }

    $activeTransaction = Get-ActiveJournal -ProjectRoot $projectRoot
    if ($null -ne $activeTransaction) {
        $activeState = [string]$activeTransaction.Journal.state
        if ($activeState -in @("ACTIVATING", "VALIDATING", "ROLLING_BACK", "PREPARING", "COMMITTED", "ROLLED_BACK", "STALE_BASELINE", "ABORTED_PREPARATION")) {
            if ($CheckOnly -or $implicitReadOnly) {
                throw "AZ-UPDATE-RECOVERY-REQUIRED: interrupted transaction $($activeTransaction.Journal.transactionId) must be recovered first."
            }
            Enter-UpdateLock -ProjectRoot $projectRoot
            $recoveryOutcome = Invoke-Recovery -ProjectRoot $projectRoot
            Exit-UpdateLock
            if ($recoveryOutcome -ne "CLEARED") {
                Write-Host "Run UPDATE.cmd again after reviewing the recovery result."
                Write-Host "If .agent-zero/UPDATE.cmd is unavailable, run .agent-zero-update/RECOVER.cmd."
                Wait-UpdateClose
                return
            }
        }
        elseif ($activeState -in @("READY_TO_ACTIVATE", "AWAITING_AI")) {
            Write-Host "AZ-UPDATE-$activeState"
            Write-Host "Active transaction: $($activeTransaction.Journal.transactionId)"
            if ($activeState -eq "AWAITING_AI") {
                $existingPrompt = Join-Path $activeTransaction.Root "AI_UPDATE_PROMPT.md"
                Write-Host "Paste the prompt into your current AI agent: $existingPrompt"
                if (-not $NoClipboard -and (Test-Path -LiteralPath $existingPrompt -PathType Leaf)) {
                    try { Set-Clipboard -Value (Get-Content -Raw -LiteralPath $existingPrompt) -ErrorAction Stop } catch {}
                }
            }
            Wait-UpdateClose
            return
        }
        else {
            throw "AZ-UPDATE-RECOVERY: unknown active transaction state: $activeState"
        }
    }

    $discoveryBundle = Get-ReleaseBundle
    $assessment = Get-InstalledAssessment -ProjectRoot $projectRoot -Manifest $discoveryBundle.ManifestRecord.Model
    Show-Assessment -Assessment $assessment -Manifest $discoveryBundle.ManifestRecord.Model -ReleaseUrl $discoveryBundle.ReleaseUrl -Source $discoveryBundle.Source
    if ($assessment.Status -in @("UP_TO_DATE", "LOCAL_NEWER")) {
        Wait-UpdateClose
        return
    }
    if ($assessment.Status -eq "UNSUPPORTED") {
        throw "AZ-UPDATE-UNSUPPORTED: no safe automatic transition is available; open UPDATE.md and ask your current AI agent to review."
    }
    if ($CheckOnly -or $implicitReadOnly) {
        Write-Host "AZ-UPDATE-CHECK-ONLY: no project file was changed."
        Wait-UpdateClose
        return
    }

    $action = if ($Apply) { "APPLY" } elseif ($PrepareOnly) { "PREPARE" } else { Select-UpdateAction -EffectiveMode $assessment.EffectiveMode }
    if ($action -eq "CANCEL" -or $action -eq "CHECK") {
        Write-Host "AZ-UPDATE-CANCELLED: no project file was changed."
        Wait-UpdateClose
        return
    }

    $verifiedBundle = Get-ReleaseBundle -NeedKit
    if ($verifiedBundle.ManifestRecord.Sha256 -ne $discoveryBundle.ManifestRecord.Sha256 -or
        [string]$verifiedBundle.ManifestRecord.Model.version -ne [string]$assessment.TargetVersion) {
        throw "AZ-UPDATE-RELEASE: release changed between check and preparation; run the check again."
    }
    Enter-UpdateLock -ProjectRoot $projectRoot
    if ($null -ne (Get-ActiveJournal -ProjectRoot $projectRoot)) {
        throw "AZ-UPDATE-TRANSACTION: another update transaction became active after the check."
    }
    $lockedAssessment = Get-InstalledAssessment -ProjectRoot $projectRoot -Manifest $verifiedBundle.ManifestRecord.Model
    foreach ($propertyName in @("Status", "InstalledVersion", "TargetVersion", "DeclaredMode", "LocalMode", "EffectiveMode", "CoreRelativePath", "CoreSha256", "ValidationMode")) {
        if ([string]$lockedAssessment.$propertyName -ne [string]$assessment.$propertyName) {
            throw "AZ-UPDATE-STALE-ASSESSMENT: local update evidence changed after the displayed check."
        }
    }
    if ((@($lockedAssessment.Reasons) -join "|") -ne (@($assessment.Reasons) -join "|")) {
        throw "AZ-UPDATE-STALE-ASSESSMENT: local update reasons changed after the displayed check."
    }
    $assessment = $lockedAssessment
    $transaction = New-UpdateTransaction -ProjectRoot $projectRoot -Assessment $assessment -Bundle $verifiedBundle
    if ($assessment.EffectiveMode -eq "SEMANTIC_REVIEW" -or $action -eq "PREPARE") {
        Exit-UpdateLock
        Wait-UpdateClose
        return
    }
    Invoke-FinalizeTransaction -ProjectRoot $projectRoot -TransactionId $transaction.Journal.transactionId
    Exit-UpdateLock
    Wait-UpdateClose
}
catch {
    Exit-UpdateLock
    Write-Host ""
    Write-Host "AZ-UPDATE-SAFE-STOP" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Khong bo qua manifest, hash, validation, approval hoac drift gate." -ForegroundColor Yellow
    Write-Host "Ban cai cu va snapshot/transaction (neu da tao) duoc giu lai."
    Wait-UpdateClose
    throw
}
finally {
    Exit-UpdateLock
    foreach ($temporaryRoot in $script:TemporaryRoots) {
        if (-not (Test-Path -LiteralPath $temporaryRoot)) {
            continue
        }
        $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
        $systemTemporary = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($resolvedTemporary.StartsWith($systemTemporary, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTemporary).StartsWith("agent-zero-update-", [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
