param(
    [string]$ProjectRoot,
    [string[]]$Paths = @(),
    [string[]]$Components = @(),
    [string[]]$Tools = @(),
    [string[]]$ErrorSignatures = @(),
    [string[]]$TaskTypes = @(),
    [string[]]$CapabilityKeys = @(),
    [string[]]$ProviderIds = @(),
    [string[]]$ProviderNames = @(),
    [switch]$IncludeCandidates,
    [switch]$IncludeCapabilityCandidates,
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
if ($Paths.Count -eq 0 -and $Components.Count -eq 0 -and $Tools.Count -eq 0 -and $ErrorSignatures.Count -eq 0 -and $TaskTypes.Count -eq 0 -and $CapabilityKeys.Count -eq 0 -and $ProviderIds.Count -eq 0 -and $ProviderNames.Count -eq 0 -and $FallbackReason -eq "NONE") {
    throw "AZ-CONTEXT-FINGERPRINT: provide at least one path, component, tool, error signature, task type, capability key, provider id/name, or fallback reason."
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

function Normalize-RegistryReference {
    param([string]$Value)
    return ([string]$Value).Replace('\', '/')
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}

function Read-Utf8Lines {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}

function Get-IndexRows {
    param([string]$Path, [string]$Kind, [switch]$Archive)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Context index is missing: $Path" }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in (Read-Utf8Lines $Path)) {
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
        $cursor = if ($cursor -is [System.IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    return $fullPath
}

if (-not (Test-Path -LiteralPath $contextIndexPath -PathType Leaf)) { throw "Missing .agent/CONTEXT_INDEX.md" }
$contextText = Read-Utf8Text $contextIndexPath
$contextSchema = Get-MarkdownField $contextText "Schema"
$detailBudget = [int](Get-MarkdownField $contextText "Retrieved detail byte limit")
$recordLimit = [int](Get-MarkdownField $contextText "Max retrieved records")
$detailRecordLimit = [int](Get-MarkdownField $contextText "Detail record byte limit")
if ($detailBudget -ne 16384 -or $recordLimit -ne 8 -or $detailRecordLimit -ne 4096) {
    throw "Context budgets are invalid; run validate-memory.ps1."
}
$registryRequested = @($CapabilityKeys).Count -gt 0 -or @($ProviderIds).Count -gt 0 -or @($ProviderNames).Count -gt 0
$registryBudget = 0
$registryRowLimit = 0
if ($contextSchema -eq "2") {
    $registryBudget = [int](Get-MarkdownField $contextText "Retrieved registry byte limit")
    $registryRowLimit = [int](Get-MarkdownField $contextText "Max retrieved registry rows")
    if ($registryBudget -ne 8192 -or $registryRowLimit -ne 24) { throw "Registry context budgets are invalid; run validate-memory.ps1." }
}
elseif ($contextSchema -ne "1") { throw "Context index schema is invalid; run validate-memory.ps1." }
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
    $globalRecord = $record.Load -eq "GLOBAL" -and -not $record.Archive
    $criticalSignalMatch = $record.Priority -eq "CRITICAL" -and $reasons.Count -gt 0
    if ($score -lt 30 -and -not $globalRecord -and -not $criticalSignalMatch) { continue }

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
function Get-PreparedDetailRecord {
    param([object]$Record)

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

    return [pscustomobject]@{
        Record = $record
        DetailFullPath = $detailFullPath
        DetailBytes = $detailBytes
    }
}

function ConvertTo-SelectedDetailRecord {
    param([object]$Prepared)

    $record = $Prepared.Record
    $item = [ordered]@{
        id = $record.Id
        title = $record.Title
        kind = $record.Kind
        status = $record.Status
        priority = $record.Priority
        score = $record.Score
        reason = $record.MatchReason
        detailPath = $record.DetailPath
        bytes = $Prepared.DetailBytes
        archived = $record.Archive
    }
    if ($IncludeContent) {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $item.content = [System.IO.File]::ReadAllText($Prepared.DetailFullPath, $strictUtf8)
    }
    return [pscustomobject]$item
}

$criticalOrdered = @($ordered | Where-Object { $_.Priority -eq "CRITICAL" })
if ($criticalOrdered.Count -gt $recordLimit) {
    throw "Matching CRITICAL context count $($criticalOrdered.Count) exceeds retrieval record limit $recordLimit."
}

$criticalPrepared = [System.Collections.Generic.List[object]]::new()
[long]$criticalBytes = 0
foreach ($record in $criticalOrdered) {
    $prepared = Get-PreparedDetailRecord -Record $record
    $criticalPrepared.Add($prepared)
    $criticalBytes += $prepared.DetailBytes
}
if ($criticalBytes -gt $detailBudget) {
    throw "Matching CRITICAL context is $criticalBytes bytes and exceeds retrieval byte limit $detailBudget."
}

foreach ($prepared in $criticalPrepared) {
    $selected.Add((ConvertTo-SelectedDetailRecord -Prepared $prepared))
}
[long]$totalBytes = $criticalBytes

foreach ($record in @($ordered | Where-Object { $_.Priority -ne "CRITICAL" })) {
    if ($selected.Count -ge $recordLimit) { break }
    $prepared = Get-PreparedDetailRecord -Record $record
    if (($totalBytes + $prepared.DetailBytes) -gt $detailBudget) { continue }

    $selected.Add((ConvertTo-SelectedDetailRecord -Prepared $prepared))
    $totalBytes += $prepared.DetailBytes
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

if ($registryRequested) {
    $registryRows = [System.Collections.Generic.List[object]]::new()
    $providerRows = @{}
    $routeRows = [System.Collections.Generic.List[object]]::new()
    $linkedRows = [System.Collections.Generic.List[object]]::new()

    $capabilityPath = Join-Path $memoryRoot "CAPABILITIES.md"
    if ($contextSchema -eq "2" -and -not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
        throw "Capability registry is required by context schema 2; run validate-memory.ps1."
    }
    if ($contextSchema -eq "2" -and (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
        $capabilityText = Read-Utf8Text $capabilityPath
        $providerRowSchema = Get-MarkdownField $capabilityText "Provider row schema"
        $routeRowSchema = Get-MarkdownField $capabilityText "Route row schema"
        if (($null -eq $providerRowSchema) -ne ($null -eq $routeRowSchema) -or ($null -ne $providerRowSchema -and $providerRowSchema -ne "2") -or ($null -ne $routeRowSchema -and $routeRowSchema -ne "2")) {
            throw "Capability registry row schema is partial or unsupported; run validate-memory.ps1."
        }
        $canonicalProviderRows = $providerRowSchema -eq "2"
        $canonicalRouteRows = $routeRowSchema -eq "2"
        $tableSection = "NONE"
        $seenRouteIds = @{}
        foreach ($line in (Read-Utf8Lines $capabilityPath)) {
            $trimmed = $line.Trim()
            if ($trimmed -eq "## Providers") { $tableSection = "PROVIDERS"; continue }
            if ($trimmed -eq "## Resolutions") { $tableSection = "RESOLUTIONS"; continue }
            if ($trimmed -match '^##\s') { $tableSection = "NONE"; continue }
            if ($tableSection -eq "NONE" -and $trimmed -match '^\|\s*`(?:CP|CR)-\d{3,}`\s*\|') {
                throw "Capability row appears outside its declared table; run validate-memory.ps1: $trimmed"
            }

            if ($tableSection -eq "PROVIDERS" -and $line -match '^\|\s*`(?<id>CP-\d{3,})`\s*\|') {
                $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
                if ($cells.Count -ne 14) { throw "Malformed capability provider row $($matches['id']); run validate-memory.ps1." }
                if ($providerRows.ContainsKey($cells[0])) { throw "Duplicate capability provider ID $($cells[0]); run validate-memory.ps1." }
                $legacyProvider = -not $canonicalProviderRows
                $providerRows[$cells[0]] = [pscustomobject][ordered]@{
                    recordType = "PROVIDER"
                    id = $cells[0]
                    displayName = $cells[3]
                    kind = $cells[2]
                    scope = $cells[4]
                    ownership = $cells[5]
                    authority = if ($legacyProvider) { "UNKNOWN" } else { $cells[6] }
                    availability = $cells[7]
                    capabilityKeys = [object[]]@(Split-Metadata $cells[1])
                    contributions = [object[]]$(if ($legacyProvider) { @() } else { @(Split-Metadata $cells[8]) })
                    sideEffect = $cells[9]
                    delegation = $cells[10]
                    sourceRef = $cells[11]
                    observedSha256 = $cells[12]
                    lastSeen = $cells[13]
                    metadataState = if ($legacyProvider) { "LEGACY_INCOMPLETE" } else { "CANONICAL" }
                    raw = $line
                }
            }
            elseif ($tableSection -eq "RESOLUTIONS" -and $line -match '^\|\s*`(?<id>CR-\d{3,})`\s*\|') {
                $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
                $expectedRouteCells = if ($canonicalRouteRows) { 15 } else { 12 }
                if ($cells.Count -ne $expectedRouteCells) { throw "Malformed capability route row $($matches['id']); run validate-memory.ps1." }
                if ($seenRouteIds.ContainsKey($cells[0])) { throw "Duplicate capability route ID $($cells[0]); run validate-memory.ps1." }
                $seenRouteIds[$cells[0]] = $true
                if ($canonicalRouteRows) {
                    $routeRows.Add([pscustomobject][ordered]@{
                        recordType = "ROUTE"
                        id = $cells[0]
                        capabilityKey = $cells[1]
                        useCase = $cells[2]
                        candidateProviders = [object[]]@(Split-Metadata $cells[3])
                        decision = $cells[4]
                        selectedProviders = [object[]]@(Split-Metadata $cells[5])
                        requiredContributions = [object[]]@(Split-Metadata $cells[6])
                        maxSideEffect = $cells[7]
                        delegationAllowance = $cells[8]
                        authority = $cells[9]
                        fallbackEvidence = $cells[10]
                        evidence = $cells[11]
                        parentRunAccounting = $cells[12]
                        reviewTrigger = $cells[13]
                        status = $cells[14]
                        metadataState = "CANONICAL"
                        raw = $line
                    })
                }
                else {
                    $routeRows.Add([pscustomobject][ordered]@{
                        recordType = "ROUTE"
                        id = $cells[0]
                        capabilityKey = $cells[1]
                        useCase = $cells[2]
                        candidateProviders = [object[]]@(Split-Metadata $cells[3])
                        decision = $cells[4]
                        selectedProviders = [object[]]@(Split-Metadata $cells[5])
                        requiredContributions = [object[]]@()
                        maxSideEffect = "UNKNOWN"
                        delegationAllowance = "UNKNOWN"
                        authority = $cells[7]
                        fallbackEvidence = "UNKNOWN"
                        evidence = $cells[9]
                        parentRunAccounting = $cells[8]
                        reviewTrigger = $cells[10]
                        status = $cells[11]
                        metadataState = "LEGACY_INCOMPLETE"
                        raw = $line
                    })
                }
            }
            elseif ($tableSection -in @("PROVIDERS", "RESOLUTIONS") -and $trimmed.StartsWith('|') -and $trimmed -notmatch '^\|\s*(?:Provider ID|Route ID)\s*\|' -and $trimmed -notmatch '^\|\s*:?-{3,}') {
                throw "Capability registry contains an unparseable table row; run validate-memory.ps1: $trimmed"
            }
        }

        $directProviderIds = @{}
        foreach ($provider in @($providerRows.Values)) {
            $keyMatch = Test-AnyLiteralMatch -Signals $CapabilityKeys -Metadata (@($provider.capabilityKeys) -join '; ')
            $idMatch = Test-AnyLiteralMatch -Signals $ProviderIds -Metadata $provider.id
            $nameMatch = Test-AnyLiteralMatch -Signals $ProviderNames -Metadata $provider.displayName
            if ($keyMatch -or $idMatch -or $nameMatch) { $directProviderIds[$provider.id] = $true }
        }

        $wantedProviderIds = @{}
        foreach ($id in $directProviderIds.Keys) { $wantedProviderIds[$id] = $true }
        foreach ($route in $routeRows) {
            $keyMatch = Test-AnyLiteralMatch -Signals $CapabilityKeys -Metadata $route.capabilityKey
            $providerMatch = $false
            foreach ($id in @($route.candidateProviders) + @($route.selectedProviders)) {
                if ($directProviderIds.ContainsKey($id)) { $providerMatch = $true; break }
            }
            if (-not $keyMatch -and -not $providerMatch) { continue }

            $registryRows.Add($route)
            foreach ($id in @($route.candidateProviders) + @($route.selectedProviders)) {
                if ($id -ne "NONE") { $wantedProviderIds[$id] = $true }
            }
        }
        foreach ($id in @($wantedProviderIds.Keys)) {
            if (-not $providerRows.ContainsKey($id)) { throw "Capability registry dependency closure references missing provider $id; run validate-memory.ps1." }
        }
        foreach ($provider in @($providerRows.Values | Sort-Object id)) {
            if ($wantedProviderIds.ContainsKey($provider.id)) { $registryRows.Add($provider) }
        }

        $linkedProviderIds = @{}
        foreach ($registrySpec in @(
            @{
                Path=(Join-Path $memoryRoot "SKILLS.md"); RecordType="SKILL_LINK"; IdPattern='^\|\s*`(?<id>S-\d{3,})`\s*\|'
                Headers=@{
                    "2"='| ID | Provider ID | Capability key | Skill name | Status | Ownership | Candidate path | Active path | Evidence/evals | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |'
                    "3"='| ID | Provider ID | Capability key | Skill name | Status | Ownership | Candidate path | Active path | Evidence/evals | Evals SHA256 | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |'
                }
                CellCounts=@{ "2"=15; "3"=16 }
            },
            @{
                Path=(Join-Path $memoryRoot "SUBAGENTS.md"); RecordType="SUBAGENT_LINK"; IdPattern='^\|\s*`(?<id>SA-\d{3,})`\s*\|'
                Headers=@{
                    "1"='| ID | Provider ID | Capability key | Agent name | Status | Ownership | Candidate config | Active config | Evals | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |'
                    "2"='| ID | Provider ID | Capability key | Agent name | Status | Ownership | Candidate config | Active config | Evals | Evals SHA256 | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |'
                }
                CellCounts=@{ "1"=15; "2"=16 }
            }
        )) {
            if (-not (Test-Path -LiteralPath $registrySpec.Path -PathType Leaf)) { throw "Capability lifecycle registry is missing: $($registrySpec.Path)" }
            $registryText = Read-Utf8Text $registrySpec.Path
            $registrySchema = Get-MarkdownField $registryText "Schema"
            if (-not $registrySpec.Headers.ContainsKey($registrySchema)) { throw "Capability lifecycle registry has an unsupported schema: $($registrySpec.Path)" }
            $expectedCellCount = [int]$registrySpec.CellCounts[$registrySchema]
            $registryLines = Read-Utf8Lines $registrySpec.Path
            $separator = '|' + ('---|' * $expectedCellCount)
            if ($registrySpec.Headers[$registrySchema] -notin $registryLines -or $separator -notin $registryLines) { throw "Capability lifecycle registry is missing its exact header/separator: $($registrySpec.Path)" }
            $insideRegistry = $false
            $seenLifecycleIds = @{}
            foreach ($line in $registryLines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq "## Registry") { $insideRegistry = $true; continue }
                if ($trimmed -match '^##\s') { $insideRegistry = $false; continue }
                if (-not $insideRegistry -or -not $trimmed.StartsWith('|')) { continue }
                if ($trimmed -match '^\|\s*ID\s*\|' -or $trimmed -match '^\|\s*:?-{3,}') { continue }
                if ($line -notmatch $registrySpec.IdPattern) { throw "Capability lifecycle registry contains an unparseable data row: $trimmed" }
                $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
                if ($cells.Count -ne $expectedCellCount) { throw "Capability lifecycle registry row $($matches['id']) must contain $expectedCellCount cells." }
                if ($seenLifecycleIds.ContainsKey($cells[0])) { throw "Capability lifecycle registry contains duplicate ID $($cells[0])." }
                $seenLifecycleIds[$cells[0]] = $true
                $providerId = $cells[1]
                $status = $cells[4]
                if ($status -notin @("OBSERVED", "PROPOSED", "DRAFT", "EVALUATED", "APPROVED", "ENABLED", "RETIRED")) {
                    throw "Capability lifecycle registry row $($cells[0]) has invalid Status $status."
                }
                if ($expectedCellCount -eq 15 -and $status -notin @("OBSERVED", "PROPOSED", "DRAFT")) {
                    throw "Capability lifecycle registry row $($cells[0]) at Status $status requires the Evals SHA256 registry schema."
                }
                if ($expectedCellCount -eq 16) {
                    $requiresEvalsHash = $status -in @("EVALUATED", "APPROVED", "ENABLED") -or ($status -eq "RETIRED" -and $cells[8] -notin @("NONE", "UNKNOWN"))
                    if ($requiresEvalsHash -and $cells[9] -notmatch '^SHA256:[A-Fa-f0-9]{64}$') {
                        throw "Capability lifecycle registry row $($cells[0]) at Status $status requires Evals SHA256."
                    }
                    if (-not $requiresEvalsHash -and $cells[9] -ne "UNKNOWN" -and $cells[9] -notmatch '^SHA256:[A-Fa-f0-9]{64}$') {
                        throw "Capability lifecycle registry row $($cells[0]) has invalid Evals SHA256."
                    }
                }
                $lifecycleLink = [pscustomobject][ordered]@{
                    RecordType = $registrySpec.RecordType
                    Id = $cells[0]
                    ProviderId = $providerId
                    CapabilityKey = $cells[2]
                    Name = $cells[3]
                    Status = $status
                    Candidate = $cells[6]
                    Active = $cells[7]
                    EvidenceHash = if ($expectedCellCount -eq 16) { $cells[9] } else { "UNKNOWN" }
                    Raw = $line
                }
                if ($providerId -notin @("NONE", "UNKNOWN")) {
                    if ($linkedProviderIds.ContainsKey($providerId)) {
                        throw "Agent Zero-managed provider $providerId is linked by more than one lifecycle registry row: $($linkedProviderIds[$providerId].Id), $($cells[0])."
                    }
                    $linkedProviderIds[$providerId] = $lifecycleLink
                }
                if (-not $wantedProviderIds.ContainsKey($providerId)) { continue }
                if (-not $IncludeCapabilityCandidates -and $status -in @("OBSERVED", "PROPOSED", "DRAFT", "EVALUATED", "APPROVED")) { continue }
                $linkedRows.Add([pscustomobject][ordered]@{
                    recordType = $lifecycleLink.RecordType
                    id = $lifecycleLink.Id
                    providerId = $lifecycleLink.ProviderId
                    capabilityKey = $lifecycleLink.CapabilityKey
                    name = $lifecycleLink.Name
                    status = $lifecycleLink.Status
                    candidate = $lifecycleLink.Candidate
                    active = $lifecycleLink.Active
                    evidenceHash = $lifecycleLink.EvidenceHash
                    raw = $line
                })
            }
        }
        foreach ($providerId in @($wantedProviderIds.Keys)) {
            $provider = $providerRows[$providerId]
            if ($provider.ownership -eq "AGENT_ZERO_PROJECT") {
                if ($provider.kind -notin @("SKILL", "CUSTOM_AGENT")) {
                    throw "Agent Zero-managed provider $providerId must use Kind SKILL or CUSTOM_AGENT; run validate-memory.ps1."
                }
                if (-not $linkedProviderIds.ContainsKey($providerId)) {
                    throw "Agent Zero-managed provider $providerId is missing its lifecycle registry link; run validate-memory.ps1."
                }
                $link = $linkedProviderIds[$providerId]
                $expectedRecordType = if ($provider.kind -eq "SKILL") { "SKILL_LINK" } else { "SUBAGENT_LINK" }
                if ($link.RecordType -ne $expectedRecordType) {
                    throw "Agent Zero-managed provider $providerId of Kind $($provider.kind) must link through $expectedRecordType, not $($link.RecordType)."
                }
                if ($link.CapabilityKey -cnotin @($provider.capabilityKeys)) {
                    throw "Lifecycle link $($link.Id) Capability key $($link.CapabilityKey) is not declared by provider $providerId."
                }
                if (-not $link.Name.Equals($provider.displayName, [System.StringComparison]::Ordinal)) {
                    throw "Lifecycle link $($link.Id) Name $($link.Name) does not match provider $providerId Display name $($provider.displayName)."
                }
                $expectedAvailability = if ($link.Status -eq "ENABLED") { "AVAILABLE" } elseif ($link.Status -eq "RETIRED") { "RETIRED" } else { "CANDIDATE" }
                if ($provider.availability -ne $expectedAvailability) {
                    throw "Lifecycle link $($link.Id) Status $($link.Status) requires provider $providerId Availability $expectedAvailability."
                }
                $normalizedSourceRef = Normalize-RegistryReference $provider.sourceRef
                if ($link.Status -in @("DRAFT", "EVALUATED", "APPROVED") -and $normalizedSourceRef -cne (Normalize-RegistryReference $link.Candidate)) {
                    throw "Lifecycle link $($link.Id) requires provider $providerId Source ref to match Candidate."
                }
                if ($link.Status -eq "ENABLED" -and $normalizedSourceRef -cne (Normalize-RegistryReference $link.Active)) {
                    throw "Lifecycle link $($link.Id) requires provider $providerId Source ref to match Active."
                }
            }
        }
        foreach ($linked in $linkedRows) { $registryRows.Add($linked) }
    }

    $orderedRegistry = @($registryRows | Sort-Object @{ Expression="recordType"; Ascending=$true }, @{ Expression="id"; Ascending=$true })
    $requiredRegistryBytes = [long]0
    foreach ($row in $orderedRegistry) { $requiredRegistryBytes += [System.Text.UTF8Encoding]::new($false).GetByteCount([string]$row.raw) }
    if ($orderedRegistry.Count -gt $registryRowLimit) {
        throw "Matching capability registry closure has $($orderedRegistry.Count) rows and exceeds retrieval row limit $registryRowLimit; narrow the capability/provider query."
    }
    if ($requiredRegistryBytes -gt $registryBudget) {
        throw "Matching capability registry closure is $requiredRegistryBytes bytes and exceeds retrieval byte limit $registryBudget; narrow the capability/provider query."
    }
    $selectedRegistry = [System.Collections.Generic.List[object]]::new()
    $selectedRegistryBytes = 0
    foreach ($row in $orderedRegistry) {
        $rowBytes = [System.Text.UTF8Encoding]::new($false).GetByteCount([string]$row.raw)
        $public = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) {
            if ($property.Name -ne "raw") { $public[$property.Name] = $property.Value }
        }
        $selectedRegistry.Add([pscustomobject]$public)
        $selectedRegistryBytes += $rowBytes
    }
    $result["selectedRegistryCount"] = $selectedRegistry.Count
    $result["selectedRegistryBytes"] = $selectedRegistryBytes
    $result["registryRowLimit"] = $registryRowLimit
    $result["registryByteLimit"] = $registryBudget
    $result["registries"] = @($selectedRegistry)
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
