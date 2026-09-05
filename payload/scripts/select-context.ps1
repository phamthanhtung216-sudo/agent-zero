param(
    [string]$ProjectRoot,
    [string[]]$Paths = @(),
    [string[]]$Components = @(),
    [string[]]$Tools = @(),
    [string[]]$ErrorSignatures = @(),
    [string[]]$TaskTypes = @(),
    [switch]$IncludeCandidates,
    [switch]$IncludeProposed,
    [switch]$IncludeArchive,
    [ValidateSet("NONE", "HISTORY", "REGRESSION", "REPAIR", "CONFLICT", "RECALIBRATION", "ROLLBACK", "ADOPTION_AUDIT")]
    [string]$FallbackReason = "NONE",
    [switch]$IncludeContent,
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptParent = Split-Path -Parent $scriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ((Split-Path -Leaf $scriptParent) -eq ".agent-zero") {
        $ProjectRoot = Split-Path -Parent $scriptParent
    }
    else {
        $ProjectRoot = $scriptParent
    }
}

$projectFullPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
$projectBoundary = $projectFullPath + [System.IO.Path]::DirectorySeparatorChar
$memoryRoot = Join-Path $projectFullPath ".agent"
$contextIndexPath = Join-Path $memoryRoot "CONTEXT_INDEX.md"

$normalizedPaths = [System.Collections.Generic.List[string]]::new()
foreach ($inputPath in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) { continue }
    if ([System.IO.Path]::IsPathRooted($inputPath)) {
        $inputFullPath = [System.IO.Path]::GetFullPath($inputPath)
        if (-not $inputFullPath.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "AZ-CONTEXT-FINGERPRINT: input path is outside the project root: $inputPath"
        }
        $normalizedPaths.Add($inputFullPath.Substring($projectBoundary.Length).Replace('\', '/'))
    }
    else {
        if ($inputPath -match '(^|[\\/])\.\.([\\/]|$)') { throw "AZ-CONTEXT-FINGERPRINT: input path contains traversal: $inputPath" }
        $normalizedInputPath = $inputPath.Replace('\', '/')
        if ($normalizedInputPath.StartsWith('./')) { $normalizedInputPath = $normalizedInputPath.Substring(2) }
        $normalizedPaths.Add($normalizedInputPath.TrimStart('/'))
    }
}
$Paths = @($normalizedPaths)
if ($Paths.Count -eq 0 -and $Components.Count -eq 0 -and $Tools.Count -eq 0 -and $ErrorSignatures.Count -eq 0 -and $TaskTypes.Count -eq 0 -and $FallbackReason -eq "NONE") {
    throw "AZ-CONTEXT-FINGERPRINT: provide at least one path, component, tool, error signature, task type, or fallback reason."
}

function Get-MarkdownField {
    param([string]$Text, [string]$Label)
    $pattern = '(?m)^\s*-\s*' + [regex]::Escape($Label) + ':\s*`(?<value>[^`]+)`\s*$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups["value"].Value.Trim() }
    return $null
}

function Split-Metadata {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "NONE" -or $Value -eq "UNKNOWN") { return @() }
    return @($Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Clean-Cell {
    param([string]$Value)
    return $Value.Trim().Trim('`').Trim()
}

function Get-IndexRows {
    param([string]$Path, [string]$Kind, [switch]$Archive)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Context index is missing: $Path" }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^\|\s*`(?<id>[LD]-\d{3,})`\s*\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
        $expectedCount = if ($Archive) { 13 } else { 14 }
        if ($cells.Count -ne $expectedCount) { throw "Malformed $Kind index row $($matches['id']) in $Path" }

        if ($Archive) {
            $row = [pscustomobject]@{
                Id = $cells[0]; Title = $cells[1]; Status = $cells[2]; Load = "MATCH"; Priority = $cells[3]
                Components = $cells[4]; Paths = $cells[5]; Tools = $cells[6]; ErrorSignatures = $cells[7]
                TaskTypes = $cells[8]; Excludes = $cells[9]; DetailPath = $cells[10]; LastVerified = $cells[11]
                DetailHash = $cells[12]; Kind = $Kind; Archive = $true
            }
        }
        else {
            $row = [pscustomobject]@{
                Id = $cells[0]; Title = $cells[1]; Status = $cells[2]; Load = $cells[3]; Priority = $cells[4]
                Components = $cells[5]; Paths = $cells[6]; Tools = $cells[7]; ErrorSignatures = $cells[8]
                TaskTypes = $cells[9]; Excludes = $cells[10]; DetailPath = $cells[11]; LastVerified = $cells[12]
                DetailHash = $cells[13]; Kind = $Kind; Archive = $false
            }
        }
        $rows.Add($row)
    }
    return @($rows)
}

function Test-AnyLiteralMatch {
    param([string[]]$Signals, [string]$Metadata)
    foreach ($expected in @(Split-Metadata $Metadata)) {
        foreach ($signal in @($Signals)) {
            if ($signal.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Test-AnyErrorMatch {
    param([string[]]$Signals, [string]$Metadata)
    foreach ($expected in @(Split-Metadata $Metadata)) {
        foreach ($signal in @($Signals)) {
            if ($signal.IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
    }
    return $false
}

function Test-AnyPathMatch {
    param([string[]]$Signals, [string]$Metadata)
    foreach ($patternText in @(Split-Metadata $Metadata)) {
        $normalizedPattern = $patternText.Replace('\', '/')
        $pattern = New-Object System.Management.Automation.WildcardPattern($normalizedPattern, ([System.Management.Automation.WildcardOptions]::IgnoreCase))
        foreach ($signal in @($Signals)) {
            if ($pattern.IsMatch($signal.Replace('\', '/'))) { return $true }
        }
    }
    return $false
}

function Resolve-ContainedDetail {
    param([string]$RelativePath, [string]$ExpectedRoot)
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { throw "Detail path must be project-relative: $RelativePath" }
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $projectFullPath $RelativePath))
    if (-not $fullPath.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Detail path escapes project root: $RelativePath"
    }
    $expectedFullRoot = [System.IO.Path]::GetFullPath((Join-Path $projectFullPath $ExpectedRoot)).TrimEnd('\', '/')
    $expectedBoundary = $expectedFullRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($expectedBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Detail path escapes its registered root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Detail record is missing: $RelativePath" }

    $cursor = Get-Item -LiteralPath $fullPath -Force
    while ($null -ne $cursor -and $cursor.FullName.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Detail path traverses a reparse point: $RelativePath"
        }
        $cursor = $cursor.Parent
    }
    return $fullPath
}

if (-not (Test-Path -LiteralPath $contextIndexPath -PathType Leaf)) { throw "Missing .agent/CONTEXT_INDEX.md" }
$contextText = Get-Content -Raw -LiteralPath $contextIndexPath
$detailBudget = [int](Get-MarkdownField $contextText "Retrieved detail byte limit")
$recordLimit = [int](Get-MarkdownField $contextText "Max retrieved records")
$detailRecordLimit = [int](Get-MarkdownField $contextText "Detail record byte limit")
if ($detailBudget -ne 16384 -or $recordLimit -ne 8 -or $detailRecordLimit -ne 4096) {
    throw "Context budgets are invalid; run validate-memory.ps1."
}
if ($IncludeArchive -and $FallbackReason -eq "NONE") {
    throw "IncludeArchive requires an explicit fallback reason."
}

$records = [System.Collections.Generic.List[object]]::new()
foreach ($row in @(Get-IndexRows -Path (Join-Path $memoryRoot "LESSONS.md") -Kind "LESSON")) { $records.Add($row) }
foreach ($row in @(Get-IndexRows -Path (Join-Path $memoryRoot "DECISIONS.md") -Kind "DECISION")) { $records.Add($row) }
if ($IncludeArchive) {
    foreach ($row in @(Get-IndexRows -Path (Join-Path $memoryRoot "archive/LESSONS_INDEX.md") -Kind "LESSON" -Archive)) { $records.Add($row) }
    foreach ($row in @(Get-IndexRows -Path (Join-Path $memoryRoot "archive/DECISIONS_INDEX.md") -Kind "DECISION" -Archive)) { $records.Add($row) }
}

$candidates = [System.Collections.Generic.List[object]]::new()
foreach ($record in $records) {
    $eligible = if ($record.Kind -eq "LESSON") {
        $record.Status -in @("VERIFIED", "ENFORCED") -or ($IncludeCandidates -and $record.Status -eq "CANDIDATE") -or ($IncludeArchive -and $record.Status -eq "RETIRED")
    }
    else {
        $record.Status -eq "ACCEPTED" -or ($IncludeProposed -and $record.Status -eq "PROPOSED") -or ($IncludeArchive -and $record.Status -in @("SUPERSEDED", "REJECTED"))
    }
    if (-not $eligible) { continue }
    if (Test-AnyPathMatch -Signals $Paths -Metadata $record.Excludes) { continue }

    $score = 0
    $reasons = [System.Collections.Generic.List[string]]::new()
    if (Test-AnyErrorMatch -Signals $ErrorSignatures -Metadata $record.ErrorSignatures) { $score += 100; $reasons.Add("error") }
    if (Test-AnyPathMatch -Signals $Paths -Metadata $record.Paths) { $score += 50; $reasons.Add("path") }
    if (Test-AnyLiteralMatch -Signals $Components -Metadata $record.Components) { $score += 30; $reasons.Add("component") }
    if (Test-AnyLiteralMatch -Signals $Tools -Metadata $record.Tools) { $score += 20; $reasons.Add("tool") }
    if (Test-AnyLiteralMatch -Signals $TaskTypes -Metadata $record.TaskTypes) { $score += 10; $reasons.Add("task-type") }
    if ($record.Load -eq "GLOBAL" -and -not $record.Archive) { $score += 5; $reasons.Add("global") }
    if ($score -lt 30 -and -not ($record.Load -eq "GLOBAL" -and -not $record.Archive)) { continue }

    $statusRank = switch ($record.Status) {
        "ENFORCED" { 0 }
        "ACCEPTED" { 1 }
        "VERIFIED" { 2 }
        "CANDIDATE" { 3 }
        "PROPOSED" { 4 }
        default { 5 }
    }
    $priorityRank = switch ($record.Priority) {
        "CRITICAL" { 0 }
        "HIGH" { 1 }
        "NORMAL" { 2 }
        "LOW" { 3 }
        default { 4 }
    }
    $record | Add-Member -NotePropertyName Score -NotePropertyValue $score
    $record | Add-Member -NotePropertyName MatchReason -NotePropertyValue ($reasons -join ',')
    $record | Add-Member -NotePropertyName StatusRank -NotePropertyValue $statusRank
    $record | Add-Member -NotePropertyName PriorityRank -NotePropertyValue $priorityRank
    $candidates.Add($record)
}

$ordered = @($candidates | Sort-Object @{Expression = "Score"; Descending = $true}, @{Expression = "StatusRank"; Descending = $false}, @{Expression = "PriorityRank"; Descending = $false}, @{Expression = "LastVerified"; Descending = $true}, @{Expression = "Id"; Descending = $false})
$selected = [System.Collections.Generic.List[object]]::new()
$totalBytes = 0
foreach ($record in $ordered) {
    if ($selected.Count -ge $recordLimit) { break }
    $expectedDetailRoot = if ($record.Archive) {
        if ($record.Kind -eq "LESSON") { ".agent/archive/lessons" } else { ".agent/archive/decisions" }
    }
    else {
        if ($record.Kind -eq "LESSON") { ".agent/lessons" } else { ".agent/decisions" }
    }
    $detailFullPath = Resolve-ContainedDetail $record.DetailPath $expectedDetailRoot
    $detailBytes = (Get-Item -LiteralPath $detailFullPath).Length
    if ($detailBytes -gt $detailRecordLimit) { throw "Detail record exceeds $detailRecordLimit bytes: $($record.DetailPath)" }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $detailFullPath).Hash
    if (-not $actualHash.Equals($record.DetailHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Detail hash mismatch for $($record.Id); run validate-memory.ps1."
    }
    if (($totalBytes + $detailBytes) -gt $detailBudget) {
        if ($record.Priority -eq "CRITICAL") { throw "Critical context record does not fit the retrieval byte budget: $($record.Id)" }
        continue
    }

    $item = [ordered]@{
        id = $record.Id
        kind = $record.Kind
        status = $record.Status
        priority = $record.Priority
        score = $record.Score
        reason = $record.MatchReason
        detailPath = $record.DetailPath
        bytes = $detailBytes
        archived = $record.Archive
    }
    if ($IncludeContent) { $item.content = Get-Content -Raw -LiteralPath $detailFullPath }
    $selected.Add([pscustomobject]$item)
    $totalBytes += $detailBytes
}

$result = [ordered]@{
    projectRoot = $projectFullPath
    fallbackReason = $FallbackReason
    selectedCount = $selected.Count
    selectedBytes = $totalBytes
    recordLimit = $recordLimit
    byteLimit = $detailBudget
    records = @($selected)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
}
else {
    Write-Output "Selected context: $($selected.Count) record(s), $totalBytes / $detailBudget bytes"
    foreach ($item in $selected) {
        Write-Output "- $($item.id) [$($item.kind)/$($item.status)] $($item.detailPath) - $($item.reason), $($item.bytes) bytes"
        if ($IncludeContent) { Write-Output $item.content }
    }
}
