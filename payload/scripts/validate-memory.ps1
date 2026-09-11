param(
    [string]$ProjectRoot,
    [switch]$AllowLegacyStateSchema5,
    [string]$PreviousStatePath,
    [ValidateSet("NONE", "CONTINUE", "RESUME", "COMPACTION", "SESSION_RELOAD", "NEW_OBJECTIVE", "MIGRATION")]
    [string]$TransitionKind = "NONE"
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptParent = Split-Path -Parent $scriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ((Split-Path -Leaf $scriptParent) -eq ".agent-zero") { $ProjectRoot = Split-Path -Parent $scriptParent }
    else { $ProjectRoot = $scriptParent }
}

$projectFullPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
$projectBoundary = $projectFullPath + [System.IO.Path]::DirectorySeparatorChar
$memoryRoot = Join-Path $projectFullPath ".agent"
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError { param([string]$Code, [string]$Message); $errors.Add("$Code`: $Message") }
function Add-ValidationWarning { param([string]$Code, [string]$Message); $warnings.Add("$Code`: $Message") }
function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}

function Get-MarkdownField {
    param([string]$Text, [string]$Label)
    $pattern = '(?m)^\s*-\s*' + [regex]::Escape($Label) + ':\s*`(?<value>[^`]+)`\s*$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups["value"].Value.Trim() }
    return $null
}

function Require-Field {
    param([string]$Text, [string]$Label, [string]$Path)
    $value = Get-MarkdownField -Text $Text -Label $Label
    if ([string]::IsNullOrWhiteSpace($value)) { Add-ValidationError "AZ-MEMORY-SCHEMA" "$Path is missing field: $Label" }
    return $value
}

function Test-PlaceholderValue {
    param([string]$Value)
    return [string]::IsNullOrWhiteSpace($Value) -or $Value -in @("UNKNOWN", "UNKNOWN_OR_HYPOTHESIS", "UNASSIGNED")
}

function Clean-Cell { param([string]$Value); return $Value.Trim().Trim('`').Trim() }

function Split-CellValues {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @("NONE", "UNKNOWN")) { return @() }
    return @($Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Check-DuplicateIds {
    param([string]$Text, [string]$Pattern, [string]$Path, [string]$Kind)
    $ids = @([regex]::Matches($Text, $Pattern) | ForEach-Object { $_.Groups[1].Value })
    foreach ($duplicate in @($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
        Add-ValidationError "AZ-MEMORY-INDEX" "$Path contains duplicate $Kind ID: $($duplicate.Name)"
    }
}

function Test-ContainedPath {
    param([string]$RelativePath, [string]$ExpectedRoot, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        Add-ValidationError "AZ-MEMORY-POINTER" "$Label must be project-relative: $RelativePath"
        return $null
    }
    $normalized = $RelativePath.Replace('\', '/')
    if (-not $normalized.StartsWith($ExpectedRoot.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError "AZ-MEMORY-POINTER" "$Label must stay under $ExpectedRoot`: $RelativePath"
        return $null
    }
    try { $fullPath = [System.IO.Path]::GetFullPath((Join-Path $projectFullPath $RelativePath)) }
    catch {
        Add-ValidationError "AZ-MEMORY-POINTER" "$Label is invalid: $RelativePath"
        return $null
    }
    if (-not $fullPath.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError "AZ-MEMORY-POINTER" "$Label escapes project root: $RelativePath"
        return $null
    }
    $expectedFullRoot = [System.IO.Path]::GetFullPath((Join-Path $projectFullPath $ExpectedRoot)).TrimEnd('\', '/')
    $expectedBoundary = $expectedFullRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($expectedBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError "AZ-MEMORY-POINTER" "$Label escapes its detail root: $RelativePath"
        return $null
    }
    return $fullPath
}

function Test-GlobList {
    param([string]$Value, [string]$Label)
    if ($Value -in @("NONE", "UNKNOWN")) { return }
    foreach ($item in @($Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ([System.IO.Path]::IsPathRooted($item) -or $item -match '(^|[\\/])\.\.([\\/]|$)') {
            Add-ValidationError "AZ-MEMORY-INDEX" "$Label contains a rooted or traversal glob: $item"
            continue
        }
        try { [void](New-Object System.Management.Automation.WildcardPattern($item.Replace('\', '/'), ([System.Management.Automation.WildcardOptions]::IgnoreCase))) }
        catch { Add-ValidationError "AZ-MEMORY-INDEX" "$Label contains an invalid glob: $item" }
    }
}

function Test-ReparseFreePath {
    param([string]$FullPath, [string]$Label)
    if (-not (Test-Path -LiteralPath $FullPath)) { return }
    $cursor = Get-Item -LiteralPath $FullPath -Force
    while ($null -ne $cursor -and $cursor.FullName.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-ValidationError "AZ-MEMORY-POINTER" "$Label traverses a reparse point: $($cursor.FullName)"
            return
        }
        $cursor = if ($cursor -is [System.IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
}

function Get-IndexRows {
    param([string]$Path, [string]$Kind, [switch]$Archive)
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-ValidationError "AZ-MEMORY-INDEX" "Missing $Kind index: $Path"
        return @()
    }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^\|\s*`(?<id>[LD]-\d{3,})`\s*\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
        $expectedCount = if ($Archive) { 13 } else { 14 }
        if ($cells.Count -ne $expectedCount) {
            Add-ValidationError "AZ-MEMORY-INDEX" "Malformed row $($matches['id']) in $Path; expected $expectedCount cells, found $($cells.Count)"
            continue
        }
        if ($Archive) {
            $row = [pscustomobject]@{
                Id=$cells[0]; Title=$cells[1]; Status=$cells[2]; Load="MATCH"; Priority=$cells[3]; Components=$cells[4]
                Paths=$cells[5]; Tools=$cells[6]; ErrorSignatures=$cells[7]; TaskTypes=$cells[8]; Excludes=$cells[9]
                DetailPath=$cells[10]; LastVerified=$cells[11]; DetailHash=$cells[12]; Kind=$Kind; Archive=$true; IndexPath=$Path
            }
        }
        else {
            $row = [pscustomobject]@{
                Id=$cells[0]; Title=$cells[1]; Status=$cells[2]; Load=$cells[3]; Priority=$cells[4]; Components=$cells[5]
                Paths=$cells[6]; Tools=$cells[7]; ErrorSignatures=$cells[8]; TaskTypes=$cells[9]; Excludes=$cells[10]
                DetailPath=$cells[11]; LastVerified=$cells[12]; DetailHash=$cells[13]; Kind=$Kind; Archive=$false; IndexPath=$Path
            }
        }
        $rows.Add($row)
    }
    return @($rows)
}

$capabilitiesPath = Join-Path $memoryRoot "CAPABILITIES.md"
$subagentsPath = Join-Path $memoryRoot "SUBAGENTS.md"
$hasCapabilities = Test-Path -LiteralPath $capabilitiesPath -PathType Leaf
$hasSubagents = Test-Path -LiteralPath $subagentsPath -PathType Leaf
$vNextMemory = $hasCapabilities -and $hasSubagents
if ($hasCapabilities -xor $hasSubagents) {
    Add-ValidationError "AZ-MEMORY-SCHEMA" "CAPABILITIES.md and SUBAGENTS.md must be introduced together; partial capability schema is not allowed."
}

$requiredMemoryFiles = @("PROJECT.md", "STATE.md", "CONTEXT_INDEX.md", "DECISIONS.md", "LESSONS.md", "SKILLS.md", "CHANGELOG.md")
if ($vNextMemory) { $requiredMemoryFiles += @("CAPABILITIES.md", "SUBAGENTS.md") }
foreach ($memoryFile in $requiredMemoryFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $memoryRoot $memoryFile) -PathType Leaf)) {
        Add-ValidationError "AZ-MEMORY-SCHEMA" "Missing project memory file: .agent/$memoryFile"
    }
}
foreach ($relativePath in @(".agent/archive/LESSONS_INDEX.md", ".agent/archive/DECISIONS_INDEX.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectFullPath $relativePath) -PathType Leaf)) {
        Add-ValidationError "AZ-MEMORY-SCHEMA" "Missing archive index: $relativePath"
    }
}
foreach ($relativePath in @(".agent/lessons", ".agent/decisions", ".agent/archive/lessons", ".agent/archive/decisions", ".agent/archive/changelog")) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectFullPath $relativePath) -PathType Container)) {
        Add-ValidationError "AZ-MEMORY-SCHEMA" "Missing memory directory: $relativePath"
    }
}

$quotaMap = [ordered]@{
    "AGENTS.md" = @{ Warning = 26624; Hard = 28672 }
    ".agent/PROJECT.md" = @{ Warning = 13107; Hard = 16384 }
    ".agent/STATE.md" = @{ Warning = 6553; Hard = 8192 }
    ".agent/CONTEXT_INDEX.md" = @{ Warning = 6553; Hard = 8192 }
    ".agent/LESSONS.md" = @{ Warning = 13107; Hard = 16384 }
    ".agent/DECISIONS.md" = @{ Warning = 13107; Hard = 16384 }
    ".agent/SKILLS.md" = @{ Warning = 13107; Hard = 16384 }
    ".agent/CHANGELOG.md" = @{ Warning = 19661; Hard = 24576 }
}
if ($vNextMemory) {
    $quotaMap[".agent/CAPABILITIES.md"] = @{ Warning = 13107; Hard = 16384 }
    $quotaMap[".agent/SUBAGENTS.md"] = @{ Warning = 13107; Hard = 16384 }
}
foreach ($relativePath in $quotaMap.Keys) {
    $fullPath = Join-Path $projectFullPath $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $bytes = (Get-Item -LiteralPath $fullPath).Length
    $budget = $quotaMap[$relativePath]
    if ($bytes -gt $budget.Hard) { Add-ValidationError "AZ-MEMORY-QUOTA" "$relativePath is $bytes bytes; hard limit is $($budget.Hard)" }
    elseif ($bytes -ge $budget.Warning) { Add-ValidationWarning "AZ-MEMORY-QUOTA-WARN" "$relativePath is $bytes / $($budget.Hard) bytes" }
}
$defaultHotPaths = @("AGENTS.md", ".agent/PROJECT.md", ".agent/STATE.md", ".agent/CONTEXT_INDEX.md")
$defaultHotBytes = 0
foreach ($relativePath in $defaultHotPaths) {
    $fullPath = Join-Path $projectFullPath $relativePath
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $defaultHotBytes += (Get-Item -LiteralPath $fullPath).Length }
}
if ($defaultHotBytes -gt 65536) { Add-ValidationError "AZ-MEMORY-QUOTA" "Default hot control plane is $defaultHotBytes bytes; hard limit is 65536" }
elseif ($defaultHotBytes -ge 52429) { Add-ValidationWarning "AZ-MEMORY-QUOTA-WARN" "Default hot control plane is $defaultHotBytes / 65536 bytes" }

$contextPath = Join-Path $memoryRoot "CONTEXT_INDEX.md"
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    $contextText = Read-Utf8Text $contextPath
    $expectedContextFields = [ordered]@{
        "Schema" = $(if ($vNextMemory) { "2" } else { "1" }); "Retrieval mode" = "DETERMINISTIC"; "Default hot byte limit" = "65536"
        "Retrieved detail byte limit" = "16384"; "Max retrieved records" = "8"; "Detail record byte limit" = "4096"
        "Changelog entry limit" = "30"; "Archive root" = ".agent/archive"
    }
    if ($vNextMemory) {
        $expectedContextFields["Retrieved registry byte limit"] = "8192"
        $expectedContextFields["Max retrieved registry rows"] = "24"
    }
    foreach ($label in $expectedContextFields.Keys) {
        $value = Require-Field $contextText $label ".agent/CONTEXT_INDEX.md"
        if ($value -ne $expectedContextFields[$label]) { Add-ValidationError "AZ-MEMORY-CONTEXT-INDEX" "$label must be $($expectedContextFields[$label]), found: $value" }
    }
    $policyRows = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($contextPath)) {
        if ($line -notmatch '^\|\s*`(?<source>(?:AGENTS\.md|\.agent/[^`]+))`\s*\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
        if ($cells.Count -ne 5) { Add-ValidationError "AZ-MEMORY-CONTEXT-INDEX" "Malformed load-policy row for $($matches['source'])"; continue }
        if ($policyRows.ContainsKey($cells[0])) { Add-ValidationError "AZ-MEMORY-CONTEXT-INDEX" "Duplicate load-policy source: $($cells[0])" }
        else { $policyRows[$cells[0]] = @{ Policy = $cells[1]; Warning = $cells[2]; Hard = $cells[3] } }
        if ($cells[1] -notin @("ALWAYS", "ACTIVE_TASK", "INDEX_ONLY", "MATCH", "AUDIT_ONLY", "EVIDENCE_ONLY", "NEVER_DEFAULT")) {
            Add-ValidationError "AZ-MEMORY-CONTEXT-INDEX" "Invalid load policy for $($cells[0]): $($cells[1])"
        }
    }
    $expectedPolicies = [ordered]@{
        "AGENTS.md"="ALWAYS"; ".agent/PROJECT.md"="ALWAYS"; ".agent/STATE.md"="ACTIVE_TASK"; ".agent/CONTEXT_INDEX.md"="ALWAYS"
        ".agent/LESSONS.md"="INDEX_ONLY"; ".agent/DECISIONS.md"="INDEX_ONLY"; ".agent/SKILLS.md"="MATCH"; ".agent/CHANGELOG.md"="AUDIT_ONLY"
    }
    if ($vNextMemory) {
        $expectedPolicies[".agent/CAPABILITIES.md"] = "MATCH"
        $expectedPolicies[".agent/SUBAGENTS.md"] = "MATCH"
    }
    foreach ($source in $expectedPolicies.Keys) {
        if (-not $policyRows.ContainsKey($source) -or $policyRows[$source].Policy -ne $expectedPolicies[$source]) {
            Add-ValidationError "AZ-MEMORY-CONTEXT-INDEX" "Load policy must map $source to $($expectedPolicies[$source])"
        }
        elseif ($policyRows[$source].Warning -ne [string]$quotaMap[$source].Warning -or $policyRows[$source].Hard -ne [string]$quotaMap[$source].Hard) {
            Add-ValidationError "AZ-MEMORY-CONTEXT-INDEX" "Quota row for $source must be warning=$($quotaMap[$source].Warning), hard=$($quotaMap[$source].Hard)"
        }
    }
}

$projectStatus = $null
$projectPath = Join-Path $memoryRoot "PROJECT.md"
if (Test-Path -LiteralPath $projectPath -PathType Leaf) {
    $projectText = Read-Utf8Text $projectPath
    $projectStatus = Require-Field $projectText "Status" ".agent/PROJECT.md"
    $projectSchema = Require-Field $projectText "Schema" ".agent/PROJECT.md"
    if ($projectSchema -ne "4") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md Schema must be 4, found: $projectSchema" }
    if ($projectStatus -notin @("BOOTSTRAP", "ACTIVE", "RECALIBRATION")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md Status is invalid: $projectStatus" }

    $goalId = Require-Field $projectText "Goal ID" ".agent/PROJECT.md"
    $goalStatement = Require-Field $projectText "Goal statement" ".agent/PROJECT.md"
    $goalStatus = Require-Field $projectText "Goal status" ".agent/PROJECT.md"
    $goalOwner = Require-Field $projectText "Goal owner" ".agent/PROJECT.md"
    $goalReviewTrigger = Require-Field $projectText "Review trigger" ".agent/PROJECT.md"
    if ($goalStatus -notin @("HYPOTHESIS", "PROPOSED", "ACCEPTED", "SUPERSEDED", "REJECTED")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md Goal status is invalid: $goalStatus" }
    if ($goalStatus -eq "ACCEPTED") {
        if ($goalId -notmatch '^G-\d{3,}$') { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md ACCEPTED goal requires Goal ID G-NNN" }
        foreach ($field in @(@{Label="Goal statement";Value=$goalStatement}, @{Label="Goal owner";Value=$goalOwner}, @{Label="Review trigger";Value=$goalReviewTrigger})) {
            if (Test-PlaceholderValue $field.Value) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md ACCEPTED goal requires $($field.Label)" }
        }
    }
    if ($projectStatus -eq "ACTIVE") {
        foreach ($label in @("Problem", "Primary user", "Desired outcome", "Phase", "Success criteria", "Agent may decide")) {
            if (Test-PlaceholderValue (Require-Field $projectText $label ".agent/PROJECT.md")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md ACTIVE contract cannot leave $label unknown" }
        }
        if ($projectText -match '(?ms)### In scope\s+\r?\n\s*-\s*`UNKNOWN`') { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md ACTIVE contract must define In scope" }
        if ($projectText -match '(?ms)### Non-goals\s+\r?\n\s*-\s*`UNKNOWN`') { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md ACTIVE contract must define Non-goals" }
        if ($goalStatus -ne "ACCEPTED") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md ACTIVE contract requires an ACCEPTED goal" }
    }
    Check-DuplicateIds $projectText '(?m)^\|\s*`(O-\d{3,})`\s*\|' ".agent/PROJECT.md" "opportunity"
    $activeOpportunityCount = 0
    foreach ($match in [regex]::Matches($projectText, '(?m)^\|\s*`O-\d{3,}`\s*\|\s*[^|]+\|\s*`(?<status>[^`]+)`\s*\|')) {
        $status = $match.Groups['status'].Value
        if ($status -notin @("NOW", "NEXT", "WATCH", "REJECTED")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md contains invalid opportunity Status: $status" }
        if ($status -in @("NOW", "NEXT", "WATCH")) { $activeOpportunityCount++ }
    }
    if ($activeOpportunityCount -gt 5) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/PROJECT.md Opportunity backlog has $activeOpportunityCount active items; maximum is 5" }
}

$stateTaskStatus = $null
$stateSelectedIds = @()
$stateSelectedBytes = 0
$statePath = Join-Path $memoryRoot "STATE.md"
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $stateText = Read-Utf8Text $statePath
    $stateSchema = Require-Field $stateText "Schema" ".agent/STATE.md"
    $projectPhase = Require-Field $stateText "Project phase" ".agent/STATE.md"
    $runId = Require-Field $stateText "Run ID" ".agent/STATE.md"
    $currentObjective = Require-Field $stateText "Current objective" ".agent/STATE.md"
    $stateTaskStatus = Require-Field $stateText "Status" ".agent/STATE.md"
    $executionProfile = Require-Field $stateText "Execution profile" ".agent/STATE.md"
    $loopPhase = Require-Field $stateText "Loop phase" ".agent/STATE.md"
    $repairAttemptText = Require-Field $stateText "Repair attempt" ".agent/STATE.md"
    $repairLimitText = Require-Field $stateText "Repair limit" ".agent/STATE.md"
    $reviewPassText = Require-Field $stateText "Review pass" ".agent/STATE.md"
    $reviewLimitText = Require-Field $stateText "Review limit" ".agent/STATE.md"
    $metaReviewCountText = Require-Field $stateText "Meta-review count" ".agent/STATE.md"
    $metaReviewLimitText = Require-Field $stateText "Meta-review limit" ".agent/STATE.md"
    $proposalCountText = Require-Field $stateText "Proposal count" ".agent/STATE.md"
    $proposalLimitText = Require-Field $stateText "Proposal limit" ".agent/STATE.md"
    $memoryTransactionCountText = Require-Field $stateText "Memory transaction count" ".agent/STATE.md"
    $memoryTransactionLimitText = Require-Field $stateText "Memory transaction limit" ".agent/STATE.md"
    $blockerFingerprint = Require-Field $stateText "Blocker fingerprint" ".agent/STATE.md"
    $isStateSchema6 = $stateSchema -eq "6"
    $isLegacyStateSchema5 = $stateSchema -eq "5"
    if (-not $isStateSchema6 -and -not ($isLegacyStateSchema5 -and $AllowLegacyStateSchema5)) {
        Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Schema must be 6, found: $stateSchema"
    }
    if ($projectPhase -notin @("BOOTSTRAP", "ACTIVE", "RECALIBRATION")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Project phase is invalid: $projectPhase" }
    if ($projectStatus -and $projectPhase -ne $projectStatus) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Project phase ($projectPhase) must match PROJECT.md Status ($projectStatus)" }
    if ($stateTaskStatus -notin @("NOT_STARTED", "IN_PROGRESS", "BLOCKED", "COMPLETE", "AWAITING_USER_DECISION")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md task Status is invalid: $stateTaskStatus" }
    if ($executionProfile -notin @("TRIVIAL", "STANDARD", "HIGH_RISK", "GOVERNANCE")) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Execution profile is invalid: $executionProfile" }
    if ($loopPhase -notin @("UNDERSTAND", "DIRECT_REPORT", "DEFINE_DONE", "PLAN", "CHECKPOINT", "IMPLEMENT", "VERIFY", "REVIEW", "REPAIR", "LEARN", "SYNC", "REPORT", "META_REVIEW", "PROPOSAL", "IDLE", "BLOCKED", "COMPLETE", "AWAITING_USER_DECISION")) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Loop phase is invalid: $loopPhase" }
    $repairAttempt = 0; $repairLimit = 0; $reviewPass = 0; $reviewLimit = 0
    $metaReviewCount = 0; $metaReviewLimit = 0; $proposalCount = 0; $proposalLimit = 0
    $memoryTransactionCount = 0; $memoryTransactionLimit = 0
    if (-not [int]::TryParse($repairAttemptText, [ref]$repairAttempt) -or $repairAttempt -lt 0) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Repair attempt must be a non-negative integer" }
    if (-not [int]::TryParse($repairLimitText, [ref]$repairLimit) -or $repairLimit -ne 2) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Repair limit must be 2" }
    if ($repairAttempt -gt $repairLimit) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Repair attempt ($repairAttempt) exceeds Repair limit ($repairLimit)" }
    if (-not [int]::TryParse($reviewPassText, [ref]$reviewPass) -or $reviewPass -lt 0) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Review pass must be a non-negative integer" }
    if (-not [int]::TryParse($reviewLimitText, [ref]$reviewLimit) -or $reviewLimit -ne 2) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Review limit must be 2" }
    if ($reviewPass -gt $reviewLimit) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Review pass ($reviewPass) exceeds Review limit ($reviewLimit)" }
    if (-not [int]::TryParse($metaReviewCountText, [ref]$metaReviewCount) -or $metaReviewCount -lt 0) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Meta-review count must be a non-negative integer" }
    if (-not [int]::TryParse($metaReviewLimitText, [ref]$metaReviewLimit) -or $metaReviewLimit -ne 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Meta-review limit must be 1" }
    if ($metaReviewCount -gt $metaReviewLimit) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Meta-review count ($metaReviewCount) exceeds Meta-review limit ($metaReviewLimit)" }
    if (-not [int]::TryParse($proposalCountText, [ref]$proposalCount) -or $proposalCount -lt 0) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Proposal count must be a non-negative integer" }
    if (-not [int]::TryParse($proposalLimitText, [ref]$proposalLimit) -or $proposalLimit -ne 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Proposal limit must be 1" }
    if ($proposalCount -gt $proposalLimit) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Proposal count ($proposalCount) exceeds Proposal limit ($proposalLimit)" }
    if (-not [int]::TryParse($memoryTransactionCountText, [ref]$memoryTransactionCount) -or $memoryTransactionCount -lt 0) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Memory transaction count must be a non-negative integer" }
    if (-not [int]::TryParse($memoryTransactionLimitText, [ref]$memoryTransactionLimit) -or $memoryTransactionLimit -ne 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Memory transaction limit must be 1" }
    if ($memoryTransactionCount -gt $memoryTransactionLimit) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Memory transaction count ($memoryTransactionCount) exceeds Memory transaction limit ($memoryTransactionLimit)" }
    if ($loopPhase -eq "REPAIR" -and $repairAttempt -lt 1) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md REPAIR phase requires Repair attempt >= 1" }
    if ($loopPhase -eq "REVIEW" -and $reviewPass -lt 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md REVIEW phase requires Review pass >= 1" }
    if ($loopPhase -eq "META_REVIEW" -and $metaReviewCount -lt 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md META_REVIEW phase requires Meta-review count = 1" }
    if ($loopPhase -eq "PROPOSAL" -and $proposalCount -lt 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md PROPOSAL phase requires Proposal count = 1" }
    if ($proposalCount -gt $metaReviewCount) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md Proposal count cannot exceed Meta-review count" }
    if (($metaReviewCount -gt 0 -or $proposalCount -gt 0) -and $executionProfile -ne "GOVERNANCE") { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md meta-review or proposal requires GOVERNANCE execution profile" }
    if ($stateTaskStatus -eq "BLOCKED" -and $blockerFingerprint -eq "NONE") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md BLOCKED status requires a Blocker fingerprint" }
    $terminalPairs = @{ "COMPLETE" = "COMPLETE"; "BLOCKED" = "BLOCKED"; "AWAITING_USER_DECISION" = "AWAITING_USER_DECISION" }
    if ($terminalPairs.ContainsKey($stateTaskStatus) -and $loopPhase -ne $terminalPairs[$stateTaskStatus]) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md terminal Status $stateTaskStatus requires Loop phase $($terminalPairs[$stateTaskStatus])" }
    if ($loopPhase -in @("COMPLETE", "BLOCKED", "AWAITING_USER_DECISION") -and $stateTaskStatus -ne $loopPhase) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md terminal Loop phase $loopPhase requires matching task Status" }
    if ($stateTaskStatus -eq "COMPLETE" -and $executionProfile -in @("STANDARD", "HIGH_RISK") -and $reviewPass -lt 1) { Add-ValidationError "AZ-MEMORY-LOOP" ".agent/STATE.md completed STANDARD or HIGH_RISK task requires Review pass >= 1" }

    if ($isStateSchema6) {
        $logicalTaskId = Require-Field $stateText "Logical task ID" ".agent/STATE.md"
        $taskPhase = Require-Field $stateText "Task phase" ".agent/STATE.md"
        $auditStatus = Require-Field $stateText "Audit status" ".agent/STATE.md"
        $remediationAuthority = Require-Field $stateText "Remediation authority" ".agent/STATE.md"
        $subagentStartsText = Require-Field $stateText "Sub-agent starts" ".agent/STATE.md"
        $subagentStartLimitText = Require-Field $stateText "Sub-agent start limit" ".agent/STATE.md"
        $fullMatrixRunsText = Require-Field $stateText "Full-matrix runs" ".agent/STATE.md"
        $fullMatrixLimitText = Require-Field $stateText "Full-matrix limit" ".agent/STATE.md"
        $fullMatrixLastResult = Require-Field $stateText "Full-matrix last result" ".agent/STATE.md"
        $fullMatrixRerunReason = Require-Field $stateText "Full-matrix rerun reason" ".agent/STATE.md"
        $fullMatrixRetryState = Require-Field $stateText "Full-matrix retry state" ".agent/STATE.md"
        $fullMatrixFailureRepairBaselineText = Require-Field $stateText "Full-matrix failure repair baseline" ".agent/STATE.md"
        $fullMatrixRetryEvidence = Require-Field $stateText "Full-matrix retry evidence" ".agent/STATE.md"
        $usageUsedPercentText = Require-Field $stateText "Usage used percent" ".agent/STATE.md"
        $usageGate = Require-Field $stateText "Usage gate" ".agent/STATE.md"
        $usageWarningIssued = Require-Field $stateText "Usage warning issued" ".agent/STATE.md"
        $quotaCheckpointSummary = Require-Field $stateText "Quota checkpoint summary" ".agent/STATE.md"
        $quotaCheckpointNextAction = Require-Field $stateText "Quota checkpoint next action" ".agent/STATE.md"
        $quotaResumeCondition = Require-Field $stateText "Quota resume condition" ".agent/STATE.md"

        if ($stateTaskStatus -in @("IN_PROGRESS", "COMPLETE") -and (Test-PlaceholderValue $logicalTaskId)) {
            Add-ValidationError "AZ-MEMORY-RUN" ".agent/STATE.md active or completed task requires Logical task ID"
        }
        if ($taskPhase -notin @("SINGLE_PHASE", "AUDIT", "REMEDIATION")) { Add-ValidationError "AZ-MEMORY-PHASE-GATE" ".agent/STATE.md Task phase is invalid: $taskPhase" }
        if ($auditStatus -notin @("NOT_APPLICABLE", "IN_PROGRESS", "COMPLETE")) { Add-ValidationError "AZ-MEMORY-PHASE-GATE" ".agent/STATE.md Audit status is invalid: $auditStatus" }
        if ($remediationAuthority -notin @("NOT_REQUIRED", "NOT_GRANTED", "USER_GRANTED")) { Add-ValidationError "AZ-MEMORY-PHASE-GATE" ".agent/STATE.md Remediation authority is invalid: $remediationAuthority" }
        if ($taskPhase -eq "SINGLE_PHASE" -and $auditStatus -ne "NOT_APPLICABLE") { Add-ValidationError "AZ-MEMORY-PHASE-GATE" ".agent/STATE.md SINGLE_PHASE requires Audit status NOT_APPLICABLE" }
        if ($taskPhase -eq "AUDIT" -and $auditStatus -eq "NOT_APPLICABLE") { Add-ValidationError "AZ-MEMORY-PHASE-GATE" ".agent/STATE.md AUDIT requires an active audit status" }
        if ($taskPhase -eq "REMEDIATION" -and ($auditStatus -ne "COMPLETE" -or $remediationAuthority -ne "USER_GRANTED")) { Add-ValidationError "AZ-MEMORY-PHASE-GATE" ".agent/STATE.md REMEDIATION requires completed audit and USER_GRANTED authority" }

        $subagentStarts = 0; $subagentStartLimit = 0; $fullMatrixRuns = 0; $fullMatrixLimit = 0
        if (-not [int]::TryParse($subagentStartsText, [ref]$subagentStarts) -or $subagentStarts -lt 0) { Add-ValidationError "AZ-MEMORY-SUBAGENT-BUDGET" ".agent/STATE.md Sub-agent starts must be a non-negative integer" }
        if (-not [int]::TryParse($subagentStartLimitText, [ref]$subagentStartLimit) -or $subagentStartLimit -ne 3) { Add-ValidationError "AZ-MEMORY-SUBAGENT-BUDGET" ".agent/STATE.md Sub-agent start limit must be 3" }
        if ($subagentStarts -gt $subagentStartLimit) { Add-ValidationError "AZ-MEMORY-SUBAGENT-BUDGET" ".agent/STATE.md Sub-agent starts ($subagentStarts) exceeds limit ($subagentStartLimit)" }
        if (-not [int]::TryParse($fullMatrixRunsText, [ref]$fullMatrixRuns) -or $fullMatrixRuns -lt 0) { Add-ValidationError "AZ-MEMORY-VERIFY-BUDGET" ".agent/STATE.md Full-matrix runs must be a non-negative integer" }
        if (-not [int]::TryParse($fullMatrixLimitText, [ref]$fullMatrixLimit) -or $fullMatrixLimit -ne 2) { Add-ValidationError "AZ-MEMORY-VERIFY-BUDGET" ".agent/STATE.md Full-matrix limit must be 2" }
        if ($fullMatrixRuns -gt $fullMatrixLimit) { Add-ValidationError "AZ-MEMORY-VERIFY-BUDGET" ".agent/STATE.md Full-matrix runs ($fullMatrixRuns) exceeds limit ($fullMatrixLimit)" }
        if ($fullMatrixLastResult -notin @("NOT_RUN", "RUNNING", "PASS", "FAIL")) { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md Full-matrix last result is invalid: $fullMatrixLastResult" }
        if ($fullMatrixRerunReason -notin @("NONE", "FIRST_FULL_MATRIX_FAILED")) { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md Full-matrix rerun reason is invalid: $fullMatrixRerunReason" }
        if ($fullMatrixRetryState -notin @("NOT_REQUIRED", "PENDING", "VERIFIED")) { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md Full-matrix retry state is invalid: $fullMatrixRetryState" }
        $fullMatrixFailureRepairBaseline = 0
        $hasFullMatrixRepairBaseline = [int]::TryParse($fullMatrixFailureRepairBaselineText, [ref]$fullMatrixFailureRepairBaseline) -and $fullMatrixFailureRepairBaseline -ge 0
        $hasFullMatrixRetryEvidence = $fullMatrixRetryEvidence -match '^PASS:.+'

        if ($fullMatrixRuns -eq 0) {
            if ($fullMatrixLastResult -ne "NOT_RUN" -or $fullMatrixRerunReason -ne "NONE" -or $fullMatrixRetryState -ne "NOT_REQUIRED" -or $fullMatrixFailureRepairBaselineText -ne "NONE" -or $fullMatrixRetryEvidence -ne "NONE") {
                Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md zero matrix runs require NOT_RUN, NONE and NOT_REQUIRED retry fields"
            }
        }
        elseif ($fullMatrixRuns -eq 1) {
            if ($fullMatrixLastResult -eq "NOT_RUN" -or $fullMatrixRerunReason -ne "NONE") { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md first matrix run requires RUNNING, PASS or FAIL with rerun reason NONE" }
            if ($fullMatrixLastResult -eq "FAIL") {
                if ($fullMatrixRetryState -notin @("PENDING", "VERIFIED") -or -not $hasFullMatrixRepairBaseline) {
                    Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md failed first matrix requires a valid PENDING or VERIFIED post-failure repair baseline"
                }
                if ($fullMatrixRetryState -eq "PENDING" -and ($repairAttempt -ne $fullMatrixFailureRepairBaseline -or $fullMatrixRetryEvidence -ne "NONE")) { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md pending matrix retry must retain the failure repair baseline and cannot claim repair evidence" }
                if ($fullMatrixRetryState -eq "VERIFIED" -and ($repairAttempt -ne ($fullMatrixFailureRepairBaseline + 1) -or -not $hasFullMatrixRetryEvidence)) { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md verified matrix retry requires exactly one new repair and PASS evidence after the first failure" }
            }
            elseif ($fullMatrixRetryState -ne "NOT_REQUIRED" -or $fullMatrixFailureRepairBaselineText -ne "NONE" -or $fullMatrixRetryEvidence -ne "NONE") {
                Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md running or passed first matrix cannot open the retry gate"
            }
        }
        elseif ($fullMatrixRuns -eq 2) {
            if ($fullMatrixLastResult -eq "NOT_RUN" -or $fullMatrixRerunReason -ne "FIRST_FULL_MATRIX_FAILED" -or $fullMatrixRetryState -ne "VERIFIED" -or -not $hasFullMatrixRepairBaseline -or $repairAttempt -ne ($fullMatrixFailureRepairBaseline + 1) -or -not $hasFullMatrixRetryEvidence) {
                Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" ".agent/STATE.md second matrix requires first failure followed by exactly one new repair and focused PASS evidence"
            }
        }

        if ($usageGate -notin @("UNKNOWN", "NORMAL", "WARNED_80", "CHECKPOINT_90")) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md Usage gate is invalid: $usageGate" }
        if ($usageWarningIssued -notin @("NO", "YES")) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md Usage warning issued must be NO or YES" }
        $quotaCheckpointEmpty = $quotaCheckpointSummary -eq "NONE" -and $quotaCheckpointNextAction -eq "NONE" -and $quotaResumeCondition -eq "NONE"
        $quotaCheckpointComplete = $quotaCheckpointSummary -notin @("NONE", "UNKNOWN", "UNASSIGNED") -and $quotaCheckpointNextAction -notin @("NONE", "UNKNOWN", "UNASSIGNED") -and $quotaResumeCondition -eq "USAGE_BELOW_90"
        if (-not $quotaCheckpointEmpty -and -not $quotaCheckpointComplete) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md quota checkpoint fields must be all NONE or contain summary, next action and USAGE_BELOW_90" }
        $usagePercentKnown = $false
        $usageUsedPercent = 0
        if ($usageUsedPercentText -eq "UNKNOWN") {
            if ($usageGate -ne "UNKNOWN") { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md UNKNOWN usage requires Usage gate UNKNOWN" }
            if ($quotaCheckpointComplete -and $loopPhase -ne "CHECKPOINT") { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md UNKNOWN usage with an active quota checkpoint must remain in CHECKPOINT" }
        }
        else {
            if (-not [int]::TryParse($usageUsedPercentText, [ref]$usageUsedPercent) -or $usageUsedPercent -lt 0 -or $usageUsedPercent -gt 100) {
                Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md Usage used percent must be UNKNOWN or an integer from 0 to 100"
            }
            else {
                $usagePercentKnown = $true
                $expectedUsageGate = if ($usageUsedPercent -lt 80) { "NORMAL" } elseif ($usageUsedPercent -lt 90) { "WARNED_80" } else { "CHECKPOINT_90" }
                if ($usageGate -ne $expectedUsageGate) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md Usage $usageUsedPercent requires gate $expectedUsageGate, found $usageGate" }
                if ($usageUsedPercent -ge 80 -and $usageWarningIssued -ne "YES") { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md usage at or above 80 requires a recorded warning" }
                if ($usageUsedPercent -ge 90 -and $stateTaskStatus -notin @("BLOCKED", "COMPLETE", "AWAITING_USER_DECISION") -and ($loopPhase -ne "CHECKPOINT" -or -not $quotaCheckpointComplete)) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md active usage at or above 90 requires CHECKPOINT with summary, next action and USAGE_BELOW_90" }
                if ($usageUsedPercent -lt 90 -and -not $quotaCheckpointEmpty) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" ".agent/STATE.md usage below 90 must clear the quota checkpoint before resuming" }
            }
        }
    }

    $goalLink = Require-Field $stateText "Goal link" ".agent/STATE.md"
    $alignmentStatus = Require-Field $stateText "Alignment status" ".agent/STATE.md"
    $contribution = Require-Field $stateText "Contribution" ".agent/STATE.md"
    $scopeImpact = Require-Field $stateText "Scope impact" ".agent/STATE.md"
    $decisionRequired = Require-Field $stateText "Decision required" ".agent/STATE.md"
    if ($alignmentStatus -notin @("NOT_ASSESSED", "ALIGNED", "AT_RISK", "OFF_GOAL", "NEEDS_USER_DECISION")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Alignment status is invalid: $alignmentStatus" }
    if ($stateTaskStatus -in @("IN_PROGRESS", "COMPLETE")) {
        if ($goalLink -notmatch '^(G-\d{3,}|MAINTENANCE|INCIDENT)$') { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md active or completed task requires Goal link G-NNN, MAINTENANCE, or INCIDENT" }
        if ($alignmentStatus -eq "NOT_ASSESSED") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md active or completed task cannot leave Alignment status NOT_ASSESSED" }
        if (Test-PlaceholderValue $contribution) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md active or completed task requires Contribution" }
        if (Test-PlaceholderValue $scopeImpact) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md active or completed task requires Scope impact" }
    }
    if ($alignmentStatus -in @("AT_RISK", "OFF_GOAL", "NEEDS_USER_DECISION") -and ($decisionRequired -eq "NONE" -or (Test-PlaceholderValue $decisionRequired))) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md $alignmentStatus requires Decision required" }
    if ($stateTaskStatus -eq "COMPLETE" -and $alignmentStatus -in @("OFF_GOAL", "NEEDS_USER_DECISION")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md completed task cannot remain $alignmentStatus" }

    $querySummary = Require-Field $stateText "Query summary" ".agent/STATE.md"
    $selectedRecordsText = Require-Field $stateText "Selected records" ".agent/STATE.md"
    $selectedBytesText = Require-Field $stateText "Retrieved detail bytes" ".agent/STATE.md"
    $retrievalReason = Require-Field $stateText "Retrieval reason" ".agent/STATE.md"
    if (-not [int]::TryParse($selectedBytesText, [ref]$stateSelectedBytes) -or $stateSelectedBytes -lt 0 -or $stateSelectedBytes -gt 16384) { Add-ValidationError "AZ-MEMORY-RETRIEVAL" ".agent/STATE.md Retrieved detail bytes must be 0..16384" }
    if ($selectedRecordsText -ne "NONE") { $stateSelectedIds = @($selectedRecordsText.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($stateTaskStatus -in @("IN_PROGRESS", "COMPLETE") -and ($querySummary -eq "NONE" -or (Test-PlaceholderValue $querySummary) -or $retrievalReason -in @("NONE", "INITIAL_CONTEXT_ONLY") -or (Test-PlaceholderValue $retrievalReason))) {
        Add-ValidationError "AZ-MEMORY-RETRIEVAL" ".agent/STATE.md active or completed task requires a context query and selector outcome"
    }
    if ($stateSelectedIds.Count -gt 8) { Add-ValidationError "AZ-MEMORY-RETRIEVAL" ".agent/STATE.md selected more than 8 context records" }

    $verificationCheck = Require-Field $stateText "Command/check" ".agent/STATE.md"
    $verificationResult = Require-Field $stateText "Exit/result" ".agent/STATE.md"
    $evidencePath = Require-Field $stateText "Evidence path" ".agent/STATE.md"
    $verifiedAt = Require-Field $stateText "Verified at" ".agent/STATE.md"
    if ($verificationCheck -ne "NOT_RUN") {
        if (Test-PlaceholderValue $verificationResult) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md completed verification requires Exit/result" }
        if ($evidencePath -eq "NONE" -or (Test-PlaceholderValue $evidencePath)) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md completed verification requires Evidence path" }
        if (Test-PlaceholderValue $verifiedAt) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md completed verification requires Verified at" }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreviousStatePath)) {
        if (-not (Test-Path -LiteralPath $PreviousStatePath -PathType Leaf)) {
            Add-ValidationError "AZ-MEMORY-TRANSITION" "Previous state does not exist: $PreviousStatePath"
        }
        elseif ($TransitionKind -eq "NONE") {
            Add-ValidationError "AZ-MEMORY-TRANSITION" "PreviousStatePath requires an explicit TransitionKind"
        }
        else {
            $previousStateText = Read-Utf8Text $PreviousStatePath
            $previousSchema = Get-MarkdownField $previousStateText "Schema"
            $previousRunId = Get-MarkdownField $previousStateText "Run ID"
            $previousObjective = Get-MarkdownField $previousStateText "Current objective"
            $previousLogicalTaskId = Get-MarkdownField $previousStateText "Logical task ID"
            if ($TransitionKind -in @("CONTINUE", "RESUME", "COMPACTION", "SESSION_RELOAD")) {
                if (-not $isStateSchema6 -or $previousSchema -ne "6") { Add-ValidationError "AZ-MEMORY-TRANSITION" "$TransitionKind requires schema 6 on both states" }
                if ($runId -ne $previousRunId -or $currentObjective -ne $previousObjective -or $logicalTaskId -ne $previousLogicalTaskId) { Add-ValidationError "AZ-MEMORY-RUN-RESET" "$TransitionKind must preserve Run ID, Logical task ID and objective" }
                foreach ($label in @("Repair attempt", "Review pass", "Meta-review count", "Proposal count", "Memory transaction count", "Sub-agent starts", "Full-matrix runs")) {
                    $beforeText = Get-MarkdownField $previousStateText $label
                    $afterText = Get-MarkdownField $stateText $label
                    $beforeValue = 0; $afterValue = 0
                    if ([int]::TryParse($beforeText, [ref]$beforeValue) -and [int]::TryParse($afterText, [ref]$afterValue) -and $afterValue -lt $beforeValue) {
                        $code = if ($label -eq "Sub-agent starts") { "AZ-MEMORY-SUBAGENT-RESET" } else { "AZ-MEMORY-RUN-RESET" }
                        Add-ValidationError $code "$TransitionKind cannot reduce $label from $beforeValue to $afterValue"
                    }
                }

                $previousRepairAttempt = 0; $previousSubagentStarts = 0; $previousFullMatrixRuns = 0
                $hasPreviousRepairAttempt = [int]::TryParse((Get-MarkdownField $previousStateText "Repair attempt"), [ref]$previousRepairAttempt)
                $hasPreviousSubagentStarts = [int]::TryParse((Get-MarkdownField $previousStateText "Sub-agent starts"), [ref]$previousSubagentStarts)
                $hasPreviousFullMatrixRuns = [int]::TryParse((Get-MarkdownField $previousStateText "Full-matrix runs"), [ref]$previousFullMatrixRuns)
                $previousFullMatrixLastResult = Get-MarkdownField $previousStateText "Full-matrix last result"
                $previousFullMatrixRetryState = Get-MarkdownField $previousStateText "Full-matrix retry state"
                $previousFullMatrixFailureRepairBaselineText = Get-MarkdownField $previousStateText "Full-matrix failure repair baseline"
                $previousFullMatrixRetryEvidence = Get-MarkdownField $previousStateText "Full-matrix retry evidence"
                $previousUsageGate = Get-MarkdownField $previousStateText "Usage gate"
                $previousQuotaCheckpointSummary = Get-MarkdownField $previousStateText "Quota checkpoint summary"
                $previousQuotaCheckpointNextAction = Get-MarkdownField $previousStateText "Quota checkpoint next action"
                $previousQuotaResumeCondition = Get-MarkdownField $previousStateText "Quota resume condition"
                $previousQuotaCheckpointComplete = $previousQuotaCheckpointSummary -notin @("NONE", "UNKNOWN", "UNASSIGNED", $null, "") -and $previousQuotaCheckpointNextAction -notin @("NONE", "UNKNOWN", "UNASSIGNED", $null, "") -and $previousQuotaResumeCondition -eq "USAGE_BELOW_90"
                if ([string]::IsNullOrWhiteSpace($previousFullMatrixLastResult) -and $hasPreviousFullMatrixRuns -and $previousFullMatrixRuns -eq 0) { $previousFullMatrixLastResult = "NOT_RUN" }
                if ([string]::IsNullOrWhiteSpace($previousFullMatrixRetryState) -and $hasPreviousFullMatrixRuns -and $previousFullMatrixRuns -eq 0) { $previousFullMatrixRetryState = "NOT_REQUIRED" }
                if ([string]::IsNullOrWhiteSpace($previousFullMatrixFailureRepairBaselineText) -and $hasPreviousFullMatrixRuns -and $previousFullMatrixRuns -eq 0) { $previousFullMatrixFailureRepairBaselineText = "NONE" }

                if ($previousFullMatrixRetryState -eq "VERIFIED") {
                    if ($fullMatrixRetryState -ne "VERIFIED" -or -not $hasPreviousRepairAttempt -or $repairAttempt -ne $previousRepairAttempt -or $fullMatrixFailureRepairBaselineText -ne $previousFullMatrixFailureRepairBaselineText -or $fullMatrixRetryEvidence -ne $previousFullMatrixRetryEvidence) {
                        Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "$TransitionKind cannot change a VERIFIED matrix retry state, repair baseline, repair count or PASS evidence"
                    }
                }

                if ($hasPreviousFullMatrixRuns -and $fullMatrixRuns -gt ($previousFullMatrixRuns + 1)) { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "$TransitionKind cannot skip a full-matrix attempt" }
                if ($hasPreviousFullMatrixRuns -and $fullMatrixRuns -gt $previousFullMatrixRuns) {
                    if ($fullMatrixLastResult -ne "RUNNING") { Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "a started full-matrix attempt must first be recorded as RUNNING" }
                    if ($usagePercentKnown -and $usageUsedPercent -ge 90) { Add-ValidationError "AZ-MEMORY-USAGE-GATE" "$TransitionKind cannot start a full matrix while usage is at or above 90" }
                    if ($fullMatrixRuns -eq 2 -and ($previousFullMatrixRuns -ne 1 -or $previousFullMatrixLastResult -ne "FAIL" -or $previousFullMatrixRetryState -ne "VERIFIED")) {
                        Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "matrix attempt 2 requires the immediately previous checkpoint to record matrix 1 FAIL and retry VERIFIED"
                    }
                }
                if ($hasPreviousSubagentStarts -and $subagentStarts -gt $previousSubagentStarts -and $usagePercentKnown -and $usageUsedPercent -ge 90) {
                    Add-ValidationError "AZ-MEMORY-USAGE-GATE" "$TransitionKind cannot start a sub-agent while usage is at or above 90"
                }

                if (-not $usagePercentKnown -and $usageGate -eq "UNKNOWN" -and ($previousUsageGate -eq "CHECKPOINT_90" -or $previousQuotaCheckpointComplete)) {
                    if ($loopPhase -ne "CHECKPOINT" -or -not $quotaCheckpointComplete -or $quotaCheckpointSummary -ne $previousQuotaCheckpointSummary -or $quotaCheckpointNextAction -ne $previousQuotaCheckpointNextAction -or $quotaResumeCondition -ne $previousQuotaResumeCondition) {
                        Add-ValidationError "AZ-MEMORY-USAGE-GATE" "$TransitionKind with UNKNOWN usage after a quota checkpoint must preserve the exact checkpoint until usage below 90 is confirmed"
                    }
                    if (($hasPreviousSubagentStarts -and $subagentStarts -gt $previousSubagentStarts) -or ($hasPreviousFullMatrixRuns -and $fullMatrixRuns -gt $previousFullMatrixRuns)) {
                        Add-ValidationError "AZ-MEMORY-USAGE-GATE" "$TransitionKind with UNKNOWN usage after a quota checkpoint cannot start expensive work"
                    }
                }

                if ($hasPreviousFullMatrixRuns -and $fullMatrixRuns -eq $previousFullMatrixRuns -and $previousFullMatrixLastResult -eq "RUNNING" -and $fullMatrixLastResult -eq "FAIL") {
                    if ($fullMatrixRuns -ne 1 -or $fullMatrixRetryState -ne "PENDING" -or $fullMatrixFailureRepairBaselineText -ne [string]$repairAttempt -or $fullMatrixRetryEvidence -ne "NONE") {
                        Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "matrix 1 failure must open PENDING retry with the current repair count as its baseline"
                    }
                }
                if ($previousFullMatrixRetryState -eq "PENDING" -and $fullMatrixRetryState -eq "VERIFIED") {
                    if (-not $hasPreviousRepairAttempt -or $fullMatrixRuns -ne 1 -or $fullMatrixLastResult -ne "FAIL" -or $repairAttempt -ne ($previousRepairAttempt + 1) -or $fullMatrixFailureRepairBaselineText -ne $previousFullMatrixFailureRepairBaselineText -or -not $hasFullMatrixRetryEvidence) {
                        Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "PENDING to VERIFIED retry requires exactly one new repair and focused PASS evidence"
                    }
                }
                elseif ($previousFullMatrixRetryState -eq "PENDING" -and $fullMatrixRetryState -eq "PENDING" -and $hasPreviousRepairAttempt -and $repairAttempt -ne $previousRepairAttempt) {
                    Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "a PENDING matrix retry cannot consume a repair without becoming VERIFIED with focused PASS evidence"
                }
                elseif ($fullMatrixRetryState -eq "VERIFIED" -and $previousFullMatrixRetryState -ne "VERIFIED" -and $fullMatrixRuns -eq $previousFullMatrixRuns) {
                    Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "matrix retry cannot become VERIFIED without the PENDING repair transition"
                }
                if ($hasPreviousFullMatrixRuns -and $fullMatrixRuns -eq $previousFullMatrixRuns -and $previousFullMatrixLastResult -in @("PASS", "FAIL") -and $fullMatrixLastResult -ne $previousFullMatrixLastResult) {
                    Add-ValidationError "AZ-MEMORY-VERIFY-SEQUENCE" "a completed matrix result cannot change without starting another attempt"
                }
            }
            elseif ($TransitionKind -eq "NEW_OBJECTIVE") {
                if (-not $isStateSchema6 -or $previousSchema -ne "6") { Add-ValidationError "AZ-MEMORY-TRANSITION" "NEW_OBJECTIVE requires schema 6 on both states" }
                if ($runId -eq $previousRunId -or $currentObjective -eq $previousObjective -or $logicalTaskId -eq $previousLogicalTaskId) { Add-ValidationError "AZ-MEMORY-RUN-RESET" "NEW_OBJECTIVE requires new Run ID, Logical task ID and objective" }
            }
            elseif ($TransitionKind -eq "MIGRATION") {
                if (-not $isStateSchema6 -or $previousSchema -ne "5") { Add-ValidationError "AZ-MEMORY-TRANSITION" "MIGRATION requires schema 5 -> 6" }
                if ($runId -ne $previousRunId -or $currentObjective -ne $previousObjective) { Add-ValidationError "AZ-MEMORY-RUN-RESET" "MIGRATION must preserve Run ID and objective" }
            }
        }
    }
    elseif ($TransitionKind -ne "NONE") {
        Add-ValidationError "AZ-MEMORY-TRANSITION" "TransitionKind $TransitionKind requires PreviousStatePath"
    }
}

$activeLessonPath = Join-Path $memoryRoot "LESSONS.md"
$activeDecisionPath = Join-Path $memoryRoot "DECISIONS.md"
$archiveLessonPath = Join-Path $memoryRoot "archive/LESSONS_INDEX.md"
$archiveDecisionPath = Join-Path $memoryRoot "archive/DECISIONS_INDEX.md"
foreach ($schemaCheck in @(
    @{Path=$activeLessonPath; Label=".agent/LESSONS.md"; Schema="2"}, @{Path=$activeDecisionPath; Label=".agent/DECISIONS.md"; Schema="2"},
    @{Path=$archiveLessonPath; Label=".agent/archive/LESSONS_INDEX.md"; Schema="1"}, @{Path=$archiveDecisionPath; Label=".agent/archive/DECISIONS_INDEX.md"; Schema="1"}
)) {
    if (Test-Path -LiteralPath $schemaCheck.Path -PathType Leaf) {
        $text = Read-Utf8Text $schemaCheck.Path
        if ((Require-Field $text "Schema" $schemaCheck.Label) -ne $schemaCheck.Schema) { Add-ValidationError "AZ-MEMORY-INDEX" "$($schemaCheck.Label) has the wrong schema" }
    }
}

if (Test-Path -LiteralPath $activeLessonPath -PathType Leaf) {
    $learningIndexText = Read-Utf8Text $activeLessonPath
    if ((Require-Field $learningIndexText "Purpose" ".agent/LESSONS.md") -ne "PROJECT_LEARNING_MEMORY") {
        Add-ValidationError "AZ-MEMORY-LEARNING-BOUNDARY" ".agent/LESSONS.md Purpose must be PROJECT_LEARNING_MEMORY"
    }
    if (-not $learningIndexText.Contains("Normal project learning") -or -not $learningIndexText.Contains("AGENTS.md")) {
        Add-ValidationError "AZ-MEMORY-LEARNING-BOUNDARY" ".agent/LESSONS.md must keep project learning outside AGENTS.md"
    }
}

$allRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in @(Get-IndexRows $activeLessonPath "LESSON")) { $allRows.Add($row) }
foreach ($row in @(Get-IndexRows $activeDecisionPath "DECISION")) { $allRows.Add($row) }
foreach ($row in @(Get-IndexRows $archiveLessonPath "LESSON" -Archive)) { $allRows.Add($row) }
foreach ($row in @(Get-IndexRows $archiveDecisionPath "DECISION" -Archive)) { $allRows.Add($row) }

$seenIds = @{}
$seenPointers = @{}
$referencedDetails = @{}
foreach ($row in $allRows) {
    if ($seenIds.ContainsKey($row.Id)) { Add-ValidationError "AZ-MEMORY-INDEX" "Duplicate ID across active/archive indexes: $($row.Id)" }
    else { $seenIds[$row.Id] = $row.IndexPath }
    if ($row.Priority -notin @("CRITICAL", "HIGH", "NORMAL", "LOW")) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) has invalid Priority: $($row.Priority)" }
    if (-not $row.Archive -and $row.Load -notin @("MATCH", "GLOBAL")) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) has invalid Load: $($row.Load)" }
    if ($row.Kind -eq "LESSON") {
        $allowed = if ($row.Archive) { @("RETIRED") } else { @("CANDIDATE", "VERIFIED", "ENFORCED") }
        if ($row.Status -notin $allowed) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) status $($row.Status) is in the wrong active/archive index" }
        if (-not $row.Archive -and $row.Load -eq "GLOBAL" -and $row.Status -ne "ENFORCED") { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) may be GLOBAL only when ENFORCED" }
        $expectedRoot = if ($row.Archive) { ".agent/archive/lessons" } else { ".agent/lessons" }
    }
    else {
        $allowed = if ($row.Archive) { @("SUPERSEDED", "REJECTED") } else { @("PROPOSED", "ACCEPTED") }
        if ($row.Status -notin $allowed) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) status $($row.Status) is in the wrong active/archive index" }
        if (-not $row.Archive -and $row.Load -eq "GLOBAL" -and $row.Status -ne "ACCEPTED") { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) may be GLOBAL only when ACCEPTED" }
        $expectedRoot = if ($row.Archive) { ".agent/archive/decisions" } else { ".agent/decisions" }
    }
    $positiveMetadata = @($row.Components, $row.Paths, $row.Tools, $row.ErrorSignatures, $row.TaskTypes)
    if ($row.Load -ne "GLOBAL" -and @($positiveMetadata | Where-Object { $_ -notin @("NONE", "UNKNOWN", "") }).Count -eq 0) {
        Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) requires at least one positive trigger"
    }
    if ($row.Status -in @("VERIFIED", "ENFORCED", "ACCEPTED") -and $row.LastVerified -notmatch '^\d{4}-\d{2}-\d{2}$') {
        Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) requires an ISO date in its index"
    }
    Test-GlobList $row.Paths "$($row.Id) Paths"
    Test-GlobList $row.Excludes "$($row.Id) Excludes"
    if ($row.DetailHash -notmatch '^[A-Fa-f0-9]{64}$') { Add-ValidationError "AZ-MEMORY-HASH" "$($row.Id) Detail SHA256 must be 64 hex characters" }
    $detailFullPath = Test-ContainedPath $row.DetailPath $expectedRoot "$($row.Id) detail"
    if ($detailFullPath) {
        if ([System.IO.Path]::GetFileNameWithoutExtension($detailFullPath) -ne $row.Id -or [System.IO.Path]::GetExtension($detailFullPath) -ne ".md") { Add-ValidationError "AZ-MEMORY-POINTER" "$($row.Id) detail filename must be $($row.Id).md" }
        if ($seenPointers.ContainsKey($detailFullPath)) { Add-ValidationError "AZ-MEMORY-POINTER" "Detail path is referenced more than once: $($row.DetailPath)" }
        else { $seenPointers[$detailFullPath] = $row.Id; $referencedDetails[$detailFullPath] = $true }
        if (-not (Test-Path -LiteralPath $detailFullPath -PathType Leaf)) { Add-ValidationError "AZ-MEMORY-POINTER" "$($row.Id) detail record is missing: $($row.DetailPath)"; continue }
        $cursor = Get-Item -LiteralPath $detailFullPath -Force
        while ($null -ne $cursor -and $cursor.FullName.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { Add-ValidationError "AZ-MEMORY-POINTER" "$($row.Id) detail path traverses a reparse point"; break }
            $cursor = if ($cursor -is [System.IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
        }
        $detailBytes = (Get-Item -LiteralPath $detailFullPath).Length
        if ($detailBytes -gt 4096) { Add-ValidationError "AZ-MEMORY-QUOTA" "$($row.DetailPath) is $detailBytes bytes; detail limit is 4096" }
        elseif ($detailBytes -ge 3277) { Add-ValidationWarning "AZ-MEMORY-QUOTA-WARN" "$($row.DetailPath) is $detailBytes / 4096 bytes" }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $detailFullPath).Hash
        if (-not $actualHash.Equals($row.DetailHash, [System.StringComparison]::OrdinalIgnoreCase)) { Add-ValidationError "AZ-MEMORY-HASH" "$($row.Id) detail hash does not match $($row.DetailPath)" }
        $detailText = Read-Utf8Text $detailFullPath
        foreach ($field in @("Schema", "ID", "Title", "Status", "Priority", "Load mode", "Components", "Applies to paths", "Tools", "Error signatures", "Task types", "Excludes")) { [void](Require-Field $detailText $field $row.DetailPath) }
        if ((Get-MarkdownField $detailText "Schema") -ne "1") { Add-ValidationError "AZ-MEMORY-SCHEMA" "$($row.Id) detail Schema must be 1" }
        foreach ($pair in @(@{Label="ID"; Expected=$row.Id}, @{Label="Title"; Expected=$row.Title}, @{Label="Status"; Expected=$row.Status}, @{Label="Priority"; Expected=$row.Priority})) {
            if ((Get-MarkdownField $detailText $pair.Label) -ne $pair.Expected) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) detail $($pair.Label) does not match its index row" }
        }
        foreach ($pair in @(
            @{Label="Components"; Expected=$row.Components}, @{Label="Applies to paths"; Expected=$row.Paths}, @{Label="Tools"; Expected=$row.Tools},
            @{Label="Error signatures"; Expected=$row.ErrorSignatures}, @{Label="Task types"; Expected=$row.TaskTypes}, @{Label="Excludes"; Expected=$row.Excludes}
        )) {
            if ((Get-MarkdownField $detailText $pair.Label) -ne $pair.Expected) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) detail $($pair.Label) does not match its index metadata" }
        }
        if (-not $row.Archive -and (Get-MarkdownField $detailText "Load mode") -ne $row.Load) { Add-ValidationError "AZ-MEMORY-INDEX" "$($row.Id) detail Load mode does not match its index row" }
        if ($row.Kind -eq "LESSON" -and $row.Status -in @("VERIFIED", "ENFORCED")) {
            foreach ($field in @("Root cause", "Prevention", "Verification/evidence", "Related paths/tests")) { if (Test-PlaceholderValue (Get-MarkdownField $detailText $field)) { Add-ValidationError "AZ-MEMORY-SCHEMA" "$($row.Id) $($row.Status) requires $field" } }
        }
        if ($row.Kind -eq "LESSON" -and $row.Status -eq "ENFORCED") {
            $enforcementTarget = Get-MarkdownField $detailText "Enforcement target"
            if ($enforcementTarget -notin @("PROJECT_POLICY", "TEST_OR_GUARD", "APPROVED_SKILL")) {
                Add-ValidationError "AZ-MEMORY-LEARNING-BOUNDARY" "$($row.Id) ENFORCED requires a project enforcement target and cannot target AGENTS.md"
            }
        }
        if ($row.Kind -eq "DECISION" -and $row.Status -eq "ACCEPTED") {
            foreach ($field in @("Owner", "Authority evidence", "Decision", "Rationale", "Evidence")) { if (Test-PlaceholderValue (Get-MarkdownField $detailText $field)) { Add-ValidationError "AZ-MEMORY-SCHEMA" "$($row.Id) ACCEPTED requires $field" } }
        }
    }
}

foreach ($detailRoot in @(".agent/lessons", ".agent/decisions", ".agent/archive/lessons", ".agent/archive/decisions")) {
    $fullRoot = Join-Path $projectFullPath $detailRoot
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -File -Filter "*.md" -Force)) {
        if (-not $referencedDetails.ContainsKey($file.FullName)) { Add-ValidationError "AZ-MEMORY-ORPHAN" "Unindexed detail record: $($file.FullName)" }
    }
}

if ($stateTaskStatus -in @("IN_PROGRESS", "COMPLETE")) {
    $selectedSum = 0
    foreach ($id in $stateSelectedIds) {
        if (-not $seenIds.ContainsKey($id)) { Add-ValidationError "AZ-MEMORY-RETRIEVAL" ".agent/STATE.md selected unknown context record: $id"; continue }
        $row = @($allRows | Where-Object { $_.Id -eq $id })[0]
        $detailFullPath = Join-Path $projectFullPath $row.DetailPath
        if (Test-Path -LiteralPath $detailFullPath -PathType Leaf) { $selectedSum += (Get-Item -LiteralPath $detailFullPath).Length }
    }
    if ($selectedSum -ne $stateSelectedBytes) { Add-ValidationError "AZ-MEMORY-RETRIEVAL" ".agent/STATE.md Retrieved detail bytes is $stateSelectedBytes but selected records total $selectedSum" }
}

$changelogPath = Join-Path $memoryRoot "CHANGELOG.md"
if (Test-Path -LiteralPath $changelogPath -PathType Leaf) {
    $changelogText = Read-Utf8Text $changelogPath
    if ((Require-Field $changelogText "Schema" ".agent/CHANGELOG.md") -ne "1") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/CHANGELOG.md Schema must be 1" }
    if ((Require-Field $changelogText "Active entry limit" ".agent/CHANGELOG.md") -ne "30") { Add-ValidationError "AZ-MEMORY-QUOTA" ".agent/CHANGELOG.md Active entry limit must be 30" }
    $entryCount = [regex]::Matches($changelogText, '(?m)^##\s+\d{4}-\d{2}-\d{2}\b').Count
    if ($entryCount -gt 30) { Add-ValidationError "AZ-MEMORY-QUOTA" ".agent/CHANGELOG.md has $entryCount entries; maximum is 30" }
}

$capabilityProviders = @{}
$managedProviderLinks = @{}
if ($vNextMemory) {
    $capabilityValidator = Join-Path $scriptRoot "validate-capabilities.ps1"
    if (-not (Test-Path -LiteralPath $capabilityValidator -PathType Leaf)) { Add-ValidationError "AZ-MEMORY-CAPABILITY" "Missing capability validator: $capabilityValidator" }
    else { try { & $capabilityValidator -ProjectRoot $projectFullPath -RegistryPath $capabilitiesPath | Out-Null } catch { Add-ValidationError "AZ-MEMORY-CAPABILITY" $_.Exception.Message } }
    $capabilitySection = "NONE"
    foreach ($line in [System.IO.File]::ReadAllLines($capabilitiesPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "## Providers") { $capabilitySection = "PROVIDERS"; continue }
        if ($trimmed -match '^##\s') { $capabilitySection = "NONE"; continue }
        if ($capabilitySection -ne "PROVIDERS" -or -not $trimmed.StartsWith('|')) { continue }
        if ($trimmed -match '^\|\s*Provider ID\s*\|' -or $trimmed -match '^\|\s*:?-{3,}') { continue }
        if ($line -notmatch '^\|\s*`(?<id>CP-\d{3,})`\s*\|') {
            Add-ValidationError "AZ-MEMORY-CAPABILITY" "Provider table contains an unparseable data row: $trimmed"
            continue
        }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
        if ($cells.Count -ne 14) { Add-ValidationError "AZ-MEMORY-CAPABILITY" "Malformed provider row $($matches['id']); expected 14 cells."; continue }
        if ($capabilityProviders.ContainsKey($cells[0])) { Add-ValidationError "AZ-MEMORY-CAPABILITY" "Duplicate immutable Provider ID: $($cells[0])"; continue }
        $capabilityProviders[$cells[0]] = [pscustomobject]@{ Id=$cells[0]; Keys=[object[]]@(Split-CellValues $cells[1]); Kind=$cells[2]; Name=$cells[3]; Ownership=$cells[5]; State=$cells[7]; SourceRef=$cells[11] }
    }
}

$skillsPath = Join-Path $memoryRoot "SKILLS.md"
$skillRows = [System.Collections.Generic.List[object]]::new()
$skillsSchema = $null
$skillManagedNamespace = $null
if (Test-Path -LiteralPath $skillsPath -PathType Leaf) {
    $skillsText = Read-Utf8Text $skillsPath
    $skillsSchema = Require-Field $skillsText "Schema" ".agent/SKILLS.md"
    if ($skillsSchema -notin @("1", "2", "3")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/SKILLS.md Schema must be 1, 2, or 3, found: $skillsSchema" }
    if ($skillsSchema -in @("2", "3") -and -not $vNextMemory) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/SKILLS.md Schema $skillsSchema requires CAPABILITIES.md and SUBAGENTS.md." }
    if ($vNextMemory -and $skillsSchema -eq "1") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/SKILLS.md legacy Schema 1 cannot be combined with capability memory." }
    if ($skillsSchema -in @("2", "3")) { $skillManagedNamespace = Require-Field $skillsText "Managed namespace" ".agent/SKILLS.md" }
    Check-DuplicateIds $skillsText '(?m)^\|\s*`(S-\d{3,})`\s*\|' ".agent/SKILLS.md" "skill"
    $expectedSkillHeader = if ($skillsSchema -eq "1") {
        '| ID | Skill name | Status | Candidate path | Active path | Evidence/evals | Approved by | Rollback |'
    }
    elseif ($skillsSchema -eq "2") {
        '| ID | Provider ID | Capability key | Skill name | Status | Ownership | Candidate path | Active path | Evidence/evals | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |'
    }
    else {
        '| ID | Provider ID | Capability key | Skill name | Status | Ownership | Candidate path | Active path | Evidence/evals | Evals SHA256 | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |'
    }
    $expectedSkillSeparator = if ($skillsSchema -eq "1") { '|---|---|---|---|---|---|---|---|' } elseif ($skillsSchema -eq "2") { '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|' } else { '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|' }
    $skillLines = [System.IO.File]::ReadAllLines($skillsPath)
    if ($expectedSkillHeader -notin $skillLines -or $expectedSkillSeparator -notin $skillLines) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/SKILLS.md is missing the exact registry header/separator for Schema $skillsSchema." }
    $skillSection = "NONE"
    foreach ($line in $skillLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "## Registry") { $skillSection = "REGISTRY"; continue }
        if ($trimmed -match '^##\s') { $skillSection = "NONE"; continue }
        if ($skillSection -ne "REGISTRY" -or -not $trimmed.StartsWith('|')) { continue }
        if ($trimmed -match '^\|\s*ID\s*\|' -or $trimmed -match '^\|\s*:?-{3,}') { continue }
        if ($line -notmatch '^\|\s*`(?<id>S-\d{3,})`\s*\|') { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/SKILLS.md registry contains an unparseable data row: $trimmed"; continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
        if ($skillsSchema -eq "1") {
            if ($cells.Count -ne 8) { Add-ValidationError "AZ-MEMORY-SCHEMA" "Malformed legacy skill row $($matches['id']); expected 8 cells."; continue }
            $skillRows.Add([pscustomobject]@{ Id=$cells[0]; ProviderId="NONE"; Key="UNKNOWN"; Name=$cells[1]; Status=$cells[2]; Ownership="AGENT_ZERO_PROJECT"; Candidate=$cells[3]; Active=$cells[4]; Evals=$cells[5]; EvalsHash="UNKNOWN"; CandidateHash="UNKNOWN"; ActiveHash="UNKNOWN"; ApprovedBy=$cells[6]; Approval="NONE"; Rollback=$cells[7]; LastVerified="UNKNOWN" })
        }
        elseif ($skillsSchema -eq "2") {
            if ($cells.Count -ne 15) { Add-ValidationError "AZ-MEMORY-SCHEMA" "Malformed skill row $($matches['id']); expected 15 cells."; continue }
            $skillRows.Add([pscustomobject]@{ Id=$cells[0]; ProviderId=$cells[1]; Key=$cells[2]; Name=$cells[3]; Status=$cells[4]; Ownership=$cells[5]; Candidate=$cells[6]; Active=$cells[7]; Evals=$cells[8]; EvalsHash="UNKNOWN"; CandidateHash=$cells[9]; ActiveHash=$cells[10]; ApprovedBy=$cells[11]; Approval=$cells[12]; Rollback=$cells[13]; LastVerified=$cells[14] })
        }
        else {
            if ($cells.Count -ne 16) { Add-ValidationError "AZ-MEMORY-SCHEMA" "Malformed skill row $($matches['id']); expected 16 cells."; continue }
            $skillRows.Add([pscustomobject]@{ Id=$cells[0]; ProviderId=$cells[1]; Key=$cells[2]; Name=$cells[3]; Status=$cells[4]; Ownership=$cells[5]; Candidate=$cells[6]; Active=$cells[7]; Evals=$cells[8]; EvalsHash=$cells[9]; CandidateHash=$cells[10]; ActiveHash=$cells[11]; ApprovedBy=$cells[12]; Approval=$cells[13]; Rollback=$cells[14]; LastVerified=$cells[15] })
        }
    }
}
if ($skillsSchema -in @("2", "3") -and $skillRows.Count -gt 0 -and ($skillManagedNamespace -eq "UNKNOWN" -or $skillManagedNamespace -notmatch '^az-[a-z0-9]+(?:-[a-z0-9]+)*-$')) {
    Add-ValidationError "AZ-MEMORY-SKILL" ".agent/SKILLS.md Managed namespace must be a stable az-<project>- prefix when managed rows exist."
}

$skillValidator = Join-Path $scriptRoot "validate-skill.ps1"
$candidateSkillsRoot = Join-Path $memoryRoot "skill-candidates"
$managedSkillCandidates = @{}
$managedSkillActive = @{}
$managedSkillNames = @{}
$managedSkillRegistryNames = @{}
foreach ($row in $skillRows) {
    if ($row.Status -notin @("OBSERVED", "PROPOSED", "DRAFT", "EVALUATED", "APPROVED", "ENABLED", "RETIRED")) { Add-ValidationError "AZ-MEMORY-SCHEMA" "$($row.Id) has invalid skill lifecycle Status: $($row.Status)" }
    if ($skillsSchema -in @("2", "3")) {
        if ($row.Ownership -ne "AGENT_ZERO_PROJECT") { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) registry may manage only AGENT_ZERO_PROJECT skills." }
        if ($row.ProviderId -notmatch '^CP-\d{3,}$' -or -not $capabilityProviders.ContainsKey($row.ProviderId)) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) references unknown Provider ID: $($row.ProviderId)" }
        else {
            if ($managedProviderLinks.ContainsKey($row.ProviderId)) { Add-ValidationError "AZ-MEMORY-CAPABILITY" "$($row.ProviderId) is linked by more than one lifecycle registry row: $($managedProviderLinks[$row.ProviderId]), $($row.Id)." }
            else { $managedProviderLinks[$row.ProviderId] = $row.Id }
            $provider=$capabilityProviders[$row.ProviderId]
            if ($provider.Ownership -ne "AGENT_ZERO_PROJECT" -or $provider.Kind -ne "SKILL" -or $row.Key -notin @($provider.Keys) -or $provider.Name -ne $row.Name) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) does not match its Agent Zero skill provider metadata." }
            $expectedProviderState = if ($row.Status -eq "ENABLED") { "AVAILABLE" } elseif ($row.Status -eq "RETIRED") { "RETIRED" } else { "CANDIDATE" }
            if ($provider.State -ne $expectedProviderState) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) Status $($row.Status) requires provider State $expectedProviderState." }
            if ($row.Status -in @("DRAFT", "EVALUATED", "APPROVED") -and $row.Candidate -notin @("NONE", "UNKNOWN") -and $provider.SourceRef.Replace('\','/') -ne $row.Candidate.Replace('\','/')) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) candidate provider Source ref must match Candidate path." }
            if ($row.Status -eq "ENABLED" -and $row.Active -notin @("NONE", "UNKNOWN") -and $provider.SourceRef.Replace('\','/') -ne $row.Active.Replace('\','/')) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) enabled provider Source ref must match Active path." }
        }
        if ($row.Key -notmatch '^[a-z0-9]+(?:\.[a-z0-9]+)*$') { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) has invalid Capability key: $($row.Key)" }
        if ($skillManagedNamespace -ne "UNKNOWN" -and -not $row.Name.StartsWith($skillManagedNamespace, [System.StringComparison]::Ordinal)) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) Skill name must start with managed namespace $skillManagedNamespace." }
        $managedSkillRegistryNames[$row.Name.ToLowerInvariant()] = $row
    }

    $needsCandidate = $row.Status -in @("DRAFT", "EVALUATED", "APPROVED", "ENABLED")
    $needsActive = $row.Status -eq "ENABLED"
    if ($row.Status -in @("OBSERVED", "PROPOSED") -and ($row.Candidate -ne "NONE" -or $row.Active -ne "NONE")) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) cannot have candidate or active paths before DRAFT." }
    if ($row.Status -eq "RETIRED" -and $row.Active -ne "NONE") { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) RETIRED skill cannot retain an active discovery path." }
    if ($needsCandidate -and $row.Candidate -in @("NONE", "UNKNOWN")) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) $($row.Status) requires Candidate path." }
    if ($row.Status -in @("DRAFT", "EVALUATED", "APPROVED") -and $row.Active -ne "NONE") { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) cannot have Active path before ENABLED." }
    if ($needsActive -and $row.Active -in @("NONE", "UNKNOWN")) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) ENABLED requires Active path." }
    if ($row.Status -in @("EVALUATED", "APPROVED", "ENABLED") -and $row.CandidateHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$') {
        Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) $($row.Status) requires Candidate SHA256."
    }
    $requiresSkillEvalsHash = $row.Status -in @("EVALUATED", "APPROVED", "ENABLED") -or ($row.Status -eq "RETIRED" -and $row.Evals -notin @("NONE", "UNKNOWN"))
    if ($skillsSchema -eq "2" -and $requiresSkillEvalsHash) {
        Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) $($row.Status) requires SKILLS.md Schema 3 with an Evals SHA256 anchor."
    }
    elseif ($skillsSchema -eq "3") {
        if ($requiresSkillEvalsHash -and $row.EvalsHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$') { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) $($row.Status) requires Evals SHA256." }
        elseif ($row.EvalsHash -ne "UNKNOWN" -and $row.EvalsHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$') { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) Evals SHA256 must be SHA256:<64 hex> or UNKNOWN." }
    }
    if ($row.Status -in @("APPROVED", "ENABLED")) {
        if ($row.ApprovedBy -in @("NONE", "UNKNOWN") -or $row.Approval -in @("NONE", "UNKNOWN") -or $row.Rollback -in @("NONE", "UNKNOWN")) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) $($row.Status) requires approval and rollback provenance." }
    }
    if ($row.Status -eq "ENABLED" -and $row.ActiveHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$') { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) ENABLED requires Active SHA256." }

    if ($row.Candidate -notin @("NONE", "UNKNOWN")) {
        $candidateFull = Test-ContainedPath $row.Candidate ".agent/skill-candidates" "$($row.Id) Candidate path"
        if ($candidateFull) {
            $managedSkillCandidates[$candidateFull.ToLowerInvariant()]=$row.Id
            if ($needsCandidate -and -not (Test-Path -LiteralPath $candidateFull -PathType Container)) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) candidate directory is missing: $($row.Candidate)" }
            elseif (Test-Path -LiteralPath $candidateFull -PathType Container) {
                Test-ReparseFreePath $candidateFull "$($row.Id) candidate"
                try {
                    $args=@{SkillPath=$candidateFull;Mode="Candidate";ProjectRoot=$projectFullPath}
                    if ($skillsSchema -in @("2", "3")) { $args.ExpectedRegistryId=$row.Id; $args.ExpectedProviderId=$row.ProviderId; $args.ExpectedCapabilityKey=$row.Key; $args.ExpectedName=$row.Name; $args.ExpectedLifecycleStatus=$row.Status; if($row.EvalsHash -ne "UNKNOWN"){$args.ExpectedEvalsSha256=$row.EvalsHash};if($row.CandidateHash -ne "UNKNOWN"){$args.ExpectedCandidateSha256=$row.CandidateHash};if($row.Status -in @("APPROVED","ENABLED")){$args.ExpectedApprovedBy=$row.ApprovedBy;$args.ExpectedApprovalReference=$row.Approval;$args.ExpectedRollbackPath=$row.Rollback} }
                    & $skillValidator @args | Out-Null
                } catch { Add-ValidationError "AZ-MEMORY-SKILL" $_.Exception.Message }
            }
        }
    }
    if ($row.Evals -notin @("NONE", "UNKNOWN")) {
        $evalsFull = Test-ContainedPath $row.Evals ".agent/skill-candidates" "$($row.Id) Evidence/evals path"
        if ($evalsFull -and $row.Candidate -notin @("NONE", "UNKNOWN")) {
            $expectedEvals = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $projectFullPath $row.Candidate))) "EVALS.md"
            if (-not $evalsFull.Equals($expectedEvals, [System.StringComparison]::OrdinalIgnoreCase)) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) Evidence/evals must point to EVALS.md inside its candidate directory." }
        }
        if ($evalsFull -and (Test-Path -LiteralPath $evalsFull -PathType Leaf)) {
            Test-ReparseFreePath $evalsFull "$($row.Id) evals"
            if ($row.EvalsHash -match '^SHA256:[A-Fa-f0-9]{64}$') {
                $actualEvalsHash = "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $evalsFull).Hash)"
                if (-not $actualEvalsHash.Equals($row.EvalsHash, [System.StringComparison]::OrdinalIgnoreCase)) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) Evals SHA256 does not match raw EVALS.md bytes." }
            }
        }
    }
    elseif ($needsCandidate) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) $($row.Status) requires Evidence/evals path." }
    if ($row.Active -notin @("NONE", "UNKNOWN")) {
        $activeFull = Test-ContainedPath $row.Active ".agents/skills" "$($row.Id) Active path"
        if ($activeFull) {
            $managedSkillActive[$activeFull.ToLowerInvariant()]=$row.Id
            $managedSkillNames[$row.Name.ToLowerInvariant()]=$row.Id
            if ($needsActive -and -not (Test-Path -LiteralPath $activeFull -PathType Container)) { Add-ValidationError "AZ-MEMORY-SKILL" "$($row.Id) active directory is missing: $($row.Active)" }
            elseif (Test-Path -LiteralPath $activeFull -PathType Container) {
                Test-ReparseFreePath $activeFull "$($row.Id) active skill"
                try {
                    $args=@{SkillPath=$activeFull;Mode="Active";ProjectRoot=$projectFullPath}
                    if ($skillsSchema -in @("2", "3")) { $args.ExpectedRegistryId=$row.Id; $args.ExpectedProviderId=$row.ProviderId; $args.ExpectedCapabilityKey=$row.Key; $args.ExpectedName=$row.Name; $args.ExpectedLifecycleStatus=$row.Status;$args.ApprovalEvalsPath=$row.Evals;if($row.EvalsHash -ne "UNKNOWN"){$args.ExpectedEvalsSha256=$row.EvalsHash};if($row.CandidateHash -ne "UNKNOWN"){$args.ExpectedCandidateSha256=$row.CandidateHash};if($row.ActiveHash -ne "UNKNOWN"){$args.ExpectedActiveSha256=$row.ActiveHash};if($row.Status -in @("APPROVED","ENABLED")){$args.ExpectedApprovedBy=$row.ApprovedBy;$args.ExpectedApprovalReference=$row.Approval;$args.ExpectedRollbackPath=$row.Rollback} }
                    & $skillValidator @args | Out-Null
                } catch { Add-ValidationError "AZ-MEMORY-SKILL" $_.Exception.Message }
            }
        }
    }
}
if ($skillsSchema -in @("2", "3") -and (Test-Path -LiteralPath $candidateSkillsRoot -PathType Container)) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $candidateSkillsRoot -Directory -Force)) {
        if (-not $managedSkillCandidates.ContainsKey($directory.FullName.ToLowerInvariant())) { Add-ValidationError "AZ-MEMORY-SKILL" "Unregistered Agent Zero skill candidate: $($directory.FullName)" }
    }
}
$activeSkillsRoot = Join-Path $projectFullPath ".agents/skills"
if (Test-Path -LiteralPath $activeSkillsRoot -PathType Container) {
    $skillNamePaths = @{}
    foreach ($directory in @(Get-ChildItem -LiteralPath $activeSkillsRoot -Directory -Force)) {
        $skillFile=Join-Path $directory.FullName "SKILL.md"
        if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) { continue }
        $nameMatch=[regex]::Match((Read-Utf8Text $skillFile),'(?m)^name:\s*(?<value>.+?)\s*$')
        if (-not $nameMatch.Success) { continue }
        $name=$nameMatch.Groups['value'].Value.Trim().Trim('"').Trim("'").ToLowerInvariant()
        if (-not $skillNamePaths.ContainsKey($name)) { $skillNamePaths[$name]=[System.Collections.Generic.List[string]]::new() }
        $skillNamePaths[$name].Add($directory.FullName)
    }
    foreach ($name in $skillNamePaths.Keys) {
        if (-not $managedSkillRegistryNames.ContainsKey($name)) { continue }
        $managedPaths=@($skillNamePaths[$name] | Where-Object { $managedSkillActive.ContainsKey($_.ToLowerInvariant()) })
        if ($managedPaths.Count -eq 0 -or $skillNamePaths[$name].Count -gt $managedPaths.Count) { Add-ValidationError "AZ-MEMORY-SKILL" "Managed skill name collides with another visible repo skill: $name" }
    }
}

if ($vNextMemory) {
    $subagentText = Read-Utf8Text $subagentsPath
    $subagentSchema = Require-Field $subagentText "Schema" ".agent/SUBAGENTS.md"
    if ($subagentSchema -notin @("1", "2")) { Add-ValidationError "AZ-MEMORY-SUBAGENT" ".agent/SUBAGENTS.md Schema must be 1 or 2." }
    $managedNamespace = Require-Field $subagentText "Managed namespace" ".agent/SUBAGENTS.md"
    Check-DuplicateIds $subagentText '(?m)^\|\s*`(SA-\d{3,})`\s*\|' ".agent/SUBAGENTS.md" "sub-agent"
    $subagentValidator=Join-Path $scriptRoot "validate-subagent.ps1"
    $managedAgentNames=@{}
    $managedAgentRegistryNames=@{}
    $managedAgentCandidateDirs=@{}
    $subagentRowCount=0
    $expectedSubagentHeader = if ($subagentSchema -eq "1") { '| ID | Provider ID | Capability key | Agent name | Status | Ownership | Candidate config | Active config | Evals | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |' } else { '| ID | Provider ID | Capability key | Agent name | Status | Ownership | Candidate config | Active config | Evals | Evals SHA256 | Candidate SHA256 | Active SHA256 | Approved by | Approval reference | Rollback | Last verified |' }
    $expectedSubagentSeparator = if ($subagentSchema -eq "1") { '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|' } else { '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|' }
    $subagentLines = [System.IO.File]::ReadAllLines($subagentsPath)
    if ($expectedSubagentHeader -notin $subagentLines -or $expectedSubagentSeparator -notin $subagentLines) { Add-ValidationError "AZ-MEMORY-SUBAGENT" ".agent/SUBAGENTS.md is missing the exact registry header/separator." }
    $subagentSection = "NONE"
    foreach ($line in $subagentLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "## Registry") { $subagentSection = "REGISTRY"; continue }
        if ($trimmed -match '^##\s') { $subagentSection = "NONE"; continue }
        if ($subagentSection -ne "REGISTRY" -or -not $trimmed.StartsWith('|')) { continue }
        if ($trimmed -match '^\|\s*ID\s*\|' -or $trimmed -match '^\|\s*:?-{3,}') { continue }
        if ($line -notmatch '^\|\s*`(?<id>SA-\d{3,})`\s*\|') { Add-ValidationError "AZ-MEMORY-SUBAGENT" ".agent/SUBAGENTS.md registry contains an unparseable data row: $trimmed"; continue }
        $cells=@($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
        $expectedSubagentCellCount = if ($subagentSchema -eq "1") { 15 } else { 16 }
        if ($cells.Count -ne $expectedSubagentCellCount) { Add-ValidationError "AZ-MEMORY-SUBAGENT" "Malformed sub-agent row $($matches['id']); expected $expectedSubagentCellCount cells."; continue }
        $subagentRowCount++
        $id=$cells[0];$providerId=$cells[1];$key=$cells[2];$name=$cells[3];$status=$cells[4];$ownership=$cells[5];$candidate=$cells[6];$active=$cells[7];$evals=$cells[8]
        if ($subagentSchema -eq "1") { $evalsHash="UNKNOWN";$candidateHash=$cells[9];$activeHash=$cells[10];$approvedBy=$cells[11];$approvalReference=$cells[12];$rollback=$cells[13] }
        else { $evalsHash=$cells[9];$candidateHash=$cells[10];$activeHash=$cells[11];$approvedBy=$cells[12];$approvalReference=$cells[13];$rollback=$cells[14] }
        if ($status -notin @("OBSERVED","PROPOSED","DRAFT","EVALUATED","APPROVED","ENABLED","RETIRED")) { Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id has invalid Status: $status" }
        if ($ownership -ne "AGENT_ZERO_PROJECT") { Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id registry may manage only AGENT_ZERO_PROJECT profiles." }
        if ($managedNamespace -ne "UNKNOWN" -and -not $name.StartsWith($managedNamespace, [System.StringComparison]::Ordinal)) { Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id Agent name must start with managed namespace $managedNamespace." }
        $managedAgentRegistryNames[$name.ToLowerInvariant()]=$id
        if (-not $capabilityProviders.ContainsKey($providerId)) { Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id references unknown Provider ID: $providerId" }
        else { if($managedProviderLinks.ContainsKey($providerId)){Add-ValidationError "AZ-MEMORY-CAPABILITY" "$providerId is linked by more than one lifecycle registry row: $($managedProviderLinks[$providerId]), $id."}else{$managedProviderLinks[$providerId]=$id};$provider=$capabilityProviders[$providerId]; if($provider.Kind -ne "CUSTOM_AGENT" -or $provider.Ownership -ne "AGENT_ZERO_PROJECT" -or $key -notin @($provider.Keys) -or $provider.Name -ne $name){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id does not match its custom-agent provider metadata."};$expectedProviderState=if($status -eq "ENABLED"){"AVAILABLE"}elseif($status -eq "RETIRED"){"RETIRED"}else{"CANDIDATE"};if($provider.State -ne $expectedProviderState){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id Status $status requires provider State $expectedProviderState."};if($status -in @("DRAFT","EVALUATED","APPROVED") -and $candidate -notin @("NONE","UNKNOWN") -and $provider.SourceRef.Replace('\','/') -ne $candidate.Replace('\','/')){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id candidate provider Source ref must match Candidate config."};if($status -eq "ENABLED" -and $active -notin @("NONE","UNKNOWN") -and $provider.SourceRef.Replace('\','/') -ne $active.Replace('\','/')){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id enabled provider Source ref must match Active config."} }
        $needsCandidate=$status -in @("DRAFT","EVALUATED","APPROVED","ENABLED");$needsActive=$status -eq "ENABLED"
        if($status -in @("OBSERVED","PROPOSED") -and ($candidate -ne "NONE" -or $active -ne "NONE")){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id cannot have candidate or active paths before DRAFT."}
        if($status -eq "RETIRED" -and $active -ne "NONE"){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id RETIRED sub-agent cannot retain an active discovery path."}
        if($needsCandidate -and $candidate -in @("NONE","UNKNOWN")){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id $status requires Candidate config."}
        if($status -in @("DRAFT","EVALUATED","APPROVED") -and $active -ne "NONE"){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id cannot have Active config before ENABLED."}
        if($needsActive -and $active -in @("NONE","UNKNOWN")){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id ENABLED requires Active config."}
        if($status -in @("EVALUATED","APPROVED","ENABLED") -and $candidateHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$'){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id $status requires Candidate SHA256."}
        $requiresSubagentEvalsHash=$status -in @("EVALUATED","APPROVED","ENABLED") -or ($status -eq "RETIRED" -and $evals -notin @("NONE","UNKNOWN"))
        if($subagentSchema -eq "1" -and $requiresSubagentEvalsHash){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id $status requires SUBAGENTS.md Schema 2 with an Evals SHA256 anchor."}
        elseif($subagentSchema -eq "2"){if($requiresSubagentEvalsHash -and $evalsHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$'){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id $status requires Evals SHA256."}elseif($evalsHash -ne "UNKNOWN" -and $evalsHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$'){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id Evals SHA256 must be SHA256:<64 hex> or UNKNOWN."}}
        if($status -in @("APPROVED","ENABLED")){if($approvedBy -in @("NONE","UNKNOWN") -or $approvalReference -in @("NONE","UNKNOWN") -or $rollback -in @("NONE","UNKNOWN")){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id $status requires approval and rollback provenance."}}
        if($status -eq "ENABLED" -and $activeHash -notmatch '^SHA256:[A-Fa-f0-9]{64}$'){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id ENABLED requires Active SHA256."}
        $candidateFull=$null;$evalsFull=$null;$activeFull=$null
        if($candidate -notin @("NONE","UNKNOWN")){$candidateFull=Test-ContainedPath $candidate ".agent/subagent-candidates" "$id Candidate config";if($candidateFull){$managedAgentCandidateDirs[(Split-Path -Parent $candidateFull).ToLowerInvariant()]=$id}}
        if($evals -notin @("NONE","UNKNOWN")){$evalsFull=Test-ContainedPath $evals ".agent/subagent-candidates" "$id Evals"}
        if($candidateFull -and $evalsFull){$expectedEvalsFull=Join-Path (Split-Path -Parent $candidateFull) "EVALS.md";if(-not $evalsFull.Equals($expectedEvalsFull,[System.StringComparison]::OrdinalIgnoreCase)){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id Evals must point to EVALS.md beside its exact Candidate config."}}
        if($evalsFull -and (Test-Path -LiteralPath $evalsFull -PathType Leaf)){Test-ReparseFreePath $evalsFull "$id evals";if($evalsHash -match '^SHA256:[A-Fa-f0-9]{64}$'){$actualEvalsHash="SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $evalsFull).Hash)";if(-not $actualEvalsHash.Equals($evalsHash,[System.StringComparison]::OrdinalIgnoreCase)){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id Evals SHA256 does not match raw EVALS.md bytes."}}}
        if($active -notin @("NONE","UNKNOWN")){$activeFull=Test-ContainedPath $active ".codex/agents" "$id Active config"}
        if($candidateFull -and $evalsFull -and (Test-Path -LiteralPath $candidateFull -PathType Leaf) -and (Test-Path -LiteralPath $evalsFull -PathType Leaf)){
            Test-ReparseFreePath $candidateFull "$id candidate config"; Test-ReparseFreePath $evalsFull "$id evals"
            try { $args=@{ConfigPath=$candidateFull;EvalsPath=$evalsFull;Mode="Candidate";ManagedNamespace=$managedNamespace;ProjectRoot=$projectFullPath;ExpectedRegistryId=$id;ExpectedProviderId=$providerId;ExpectedCapabilityKey=$key;ExpectedName=$name;ExpectedLifecycleStatus=$status};if($evalsHash -ne "UNKNOWN"){$args.ExpectedEvalsSha256=$evalsHash};if($candidateHash -ne "UNKNOWN"){$args.ExpectedCandidateSha256=$candidateHash};if($status -in @("APPROVED","ENABLED")){$args.ExpectedApprovedBy=$approvedBy;$args.ExpectedApprovalReference=$approvalReference;$args.ExpectedRollbackPath=$rollback};& $subagentValidator @args | Out-Null } catch { Add-ValidationError "AZ-MEMORY-SUBAGENT" $_.Exception.Message }
        } elseif($needsCandidate){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id candidate config or evals file is missing."}
        if($activeFull){$managedAgentNames[$name.ToLowerInvariant()]=$activeFull;if($needsActive -and (Test-Path -LiteralPath $activeFull -PathType Leaf)){Test-ReparseFreePath $activeFull "$id active config";try{$args=@{ConfigPath=$activeFull;EvalsPath=$evalsFull;Mode="Active";ManagedNamespace=$managedNamespace;ProjectRoot=$projectFullPath;ExpectedRegistryId=$id;ExpectedProviderId=$providerId;ExpectedCapabilityKey=$key;ExpectedName=$name;ExpectedLifecycleStatus=$status};if($evalsHash -ne "UNKNOWN"){$args.ExpectedEvalsSha256=$evalsHash};if($candidateHash -ne "UNKNOWN"){$args.ExpectedCandidateSha256=$candidateHash};if($activeHash -ne "UNKNOWN"){$args.ExpectedActiveSha256=$activeHash};if($status -in @("APPROVED","ENABLED")){$args.ExpectedApprovedBy=$approvedBy;$args.ExpectedApprovalReference=$approvalReference;$args.ExpectedRollbackPath=$rollback};& $subagentValidator @args | Out-Null}catch{Add-ValidationError "AZ-MEMORY-SUBAGENT" $_.Exception.Message}}elseif($needsActive){Add-ValidationError "AZ-MEMORY-SUBAGENT" "$id active config is missing."}}
    }
    if($subagentRowCount -gt 0 -and ($managedNamespace -eq "UNKNOWN" -or $managedNamespace -notmatch '^az_[a-z0-9]+(?:_[a-z0-9]+)*_$')){Add-ValidationError "AZ-MEMORY-SUBAGENT" ".agent/SUBAGENTS.md Managed namespace must be a stable az_<project>_ prefix when managed rows exist."}
    $candidateAgentsRoot=Join-Path $memoryRoot "subagent-candidates"
    if(Test-Path -LiteralPath $candidateAgentsRoot -PathType Container){foreach($directory in @(Get-ChildItem -LiteralPath $candidateAgentsRoot -Directory -Force)){if(-not $managedAgentCandidateDirs.ContainsKey($directory.FullName.ToLowerInvariant())){Add-ValidationError "AZ-MEMORY-SUBAGENT" "Unregistered Agent Zero sub-agent candidate: $($directory.FullName)"}}}
    $activeAgentsRoot=Join-Path $projectFullPath ".codex/agents"
    if(Test-Path -LiteralPath $activeAgentsRoot -PathType Container){
        $seenAgentNames=@{}
        foreach($file in @(Get-ChildItem -LiteralPath $activeAgentsRoot -File -Filter "*.toml" -Force)){
            $match=[regex]::Match((Read-Utf8Text $file.FullName),'(?m)^\s*name\s*=\s*"(?<value>[^"\r\n]+)"\s*$');if(-not $match.Success){continue};$name=$match.Groups['value'].Value.ToLowerInvariant()
            if(-not $seenAgentNames.ContainsKey($name)){$seenAgentNames[$name]=[System.Collections.Generic.List[string]]::new()};$seenAgentNames[$name].Add($file.FullName)
        }
        foreach($name in $seenAgentNames.Keys){if(-not $managedAgentRegistryNames.ContainsKey($name)){continue};$managedPaths=@($seenAgentNames[$name] | Where-Object {$managedAgentNames.ContainsKey($name) -and $_ -eq $managedAgentNames[$name]});if($managedPaths.Count -eq 0 -or $seenAgentNames[$name].Count -gt $managedPaths.Count){Add-ValidationError "AZ-MEMORY-SUBAGENT" "Managed custom-agent name collides with another project agent: $name"}}
    }
}

if ($vNextMemory) {
    foreach ($provider in @($capabilityProviders.Values)) {
        if ($provider.Ownership -eq "AGENT_ZERO_PROJECT") {
            if ($provider.Kind -notin @("SKILL", "CUSTOM_AGENT")) {
                Add-ValidationError "AZ-MEMORY-CAPABILITY" "$($provider.Id) Agent Zero-managed providers must use Kind SKILL or CUSTOM_AGENT."
            }
            elseif (-not $managedProviderLinks.ContainsKey($provider.Id)) {
                Add-ValidationError "AZ-MEMORY-CAPABILITY" "$($provider.Id) is an Agent Zero-managed $($provider.Kind) provider without a lifecycle registry link."
            }
        }
    }
}

foreach ($warning in $warnings) { Write-Warning $warning }
if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Agent Zero memory validation failed:$([Environment]::NewLine)$details"
}

Write-Host "Agent Zero memory validation passed." -ForegroundColor Green
Write-Host "Project status: $projectStatus"
Write-Host "Default hot control plane: $defaultHotBytes / 65536 bytes"
Write-Host "Indexed context records: $($allRows.Count)"
Write-Host "Project root: $projectFullPath"
