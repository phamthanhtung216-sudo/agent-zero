param(
    [string]$ProjectRoot
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

$requiredMemoryFiles = @("PROJECT.md", "STATE.md", "CONTEXT_INDEX.md", "DECISIONS.md", "LESSONS.md", "SKILLS.md", "CHANGELOG.md")
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
    $contextText = Get-Content -Raw -LiteralPath $contextPath
    $expectedContextFields = [ordered]@{
        "Schema" = "1"; "Retrieval mode" = "DETERMINISTIC"; "Default hot byte limit" = "65536"
        "Retrieved detail byte limit" = "16384"; "Max retrieved records" = "8"; "Detail record byte limit" = "4096"
        "Changelog entry limit" = "30"; "Archive root" = ".agent/archive"
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
    $projectText = Get-Content -Raw -LiteralPath $projectPath
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
    $stateText = Get-Content -Raw -LiteralPath $statePath
    $stateSchema = Require-Field $stateText "Schema" ".agent/STATE.md"
    $projectPhase = Require-Field $stateText "Project phase" ".agent/STATE.md"
    $runId = Require-Field $stateText "Run ID" ".agent/STATE.md"
    $stateTaskStatus = Require-Field $stateText "Status" ".agent/STATE.md"
    $loopPhase = Require-Field $stateText "Loop phase" ".agent/STATE.md"
    $repairAttemptText = Require-Field $stateText "Repair attempt" ".agent/STATE.md"
    $repairLimitText = Require-Field $stateText "Repair limit" ".agent/STATE.md"
    $blockerFingerprint = Require-Field $stateText "Blocker fingerprint" ".agent/STATE.md"
    if ($stateSchema -ne "4") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Schema must be 4, found: $stateSchema" }
    if ($projectPhase -notin @("BOOTSTRAP", "ACTIVE", "RECALIBRATION")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Project phase is invalid: $projectPhase" }
    if ($projectStatus -and $projectPhase -ne $projectStatus) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Project phase ($projectPhase) must match PROJECT.md Status ($projectStatus)" }
    if ($stateTaskStatus -notin @("NOT_STARTED", "IN_PROGRESS", "BLOCKED", "COMPLETE")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md task Status is invalid: $stateTaskStatus" }
    if ($loopPhase -notin @("UNDERSTAND", "DEFINE_DONE", "PLAN", "CHECKPOINT", "IMPLEMENT", "VERIFY", "REVIEW", "REPAIR", "LEARN", "SYNC", "REPORT", "IDLE", "BLOCKED", "COMPLETE")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Loop phase is invalid: $loopPhase" }
    $repairAttempt = 0; $repairLimit = 0
    if (-not [int]::TryParse($repairAttemptText, [ref]$repairAttempt) -or $repairAttempt -lt 0) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Repair attempt must be a non-negative integer" }
    if (-not [int]::TryParse($repairLimitText, [ref]$repairLimit) -or $repairLimit -ne 2) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Repair limit must be 2" }
    if ($repairAttempt -gt $repairLimit) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md Repair attempt ($repairAttempt) exceeds Repair limit ($repairLimit)" }
    if ($loopPhase -eq "REPAIR" -and $repairAttempt -lt 1) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md REPAIR phase requires Repair attempt >= 1" }
    if ($stateTaskStatus -eq "BLOCKED" -and $blockerFingerprint -eq "NONE") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/STATE.md BLOCKED status requires a Blocker fingerprint" }

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
        $text = Get-Content -Raw -LiteralPath $schemaCheck.Path
        if ((Require-Field $text "Schema" $schemaCheck.Label) -ne $schemaCheck.Schema) { Add-ValidationError "AZ-MEMORY-INDEX" "$($schemaCheck.Label) has the wrong schema" }
    }
}

if (Test-Path -LiteralPath $activeLessonPath -PathType Leaf) {
    $learningIndexText = Get-Content -Raw -LiteralPath $activeLessonPath
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
            $cursor = $cursor.Parent
        }
        $detailBytes = (Get-Item -LiteralPath $detailFullPath).Length
        if ($detailBytes -gt 4096) { Add-ValidationError "AZ-MEMORY-QUOTA" "$($row.DetailPath) is $detailBytes bytes; detail limit is 4096" }
        elseif ($detailBytes -ge 3277) { Add-ValidationWarning "AZ-MEMORY-QUOTA-WARN" "$($row.DetailPath) is $detailBytes / 4096 bytes" }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $detailFullPath).Hash
        if (-not $actualHash.Equals($row.DetailHash, [System.StringComparison]::OrdinalIgnoreCase)) { Add-ValidationError "AZ-MEMORY-HASH" "$($row.Id) detail hash does not match $($row.DetailPath)" }
        $detailText = Get-Content -Raw -LiteralPath $detailFullPath
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
    $changelogText = Get-Content -Raw -LiteralPath $changelogPath
    if ((Require-Field $changelogText "Schema" ".agent/CHANGELOG.md") -ne "1") { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/CHANGELOG.md Schema must be 1" }
    if ((Require-Field $changelogText "Active entry limit" ".agent/CHANGELOG.md") -ne "30") { Add-ValidationError "AZ-MEMORY-QUOTA" ".agent/CHANGELOG.md Active entry limit must be 30" }
    $entryCount = [regex]::Matches($changelogText, '(?m)^##\s+\d{4}-\d{2}-\d{2}\b').Count
    if ($entryCount -gt 30) { Add-ValidationError "AZ-MEMORY-QUOTA" ".agent/CHANGELOG.md has $entryCount entries; maximum is 30" }
}

$skillsPath = Join-Path $memoryRoot "SKILLS.md"
if (Test-Path -LiteralPath $skillsPath -PathType Leaf) {
    $skillsText = Get-Content -Raw -LiteralPath $skillsPath
    Check-DuplicateIds $skillsText '(?m)^\|\s*`(S-\d{3,})`\s*\|' ".agent/SKILLS.md" "skill"
    foreach ($match in [regex]::Matches($skillsText, '(?m)^\|\s*`S-\d{3,}`\s*\|\s*`[^`]+`\s*\|\s*`(?<status>[^`]+)`')) {
        if ($match.Groups['status'].Value -notin @("OBSERVED", "PROPOSED", "DRAFT", "EVALUATED", "APPROVED", "ENABLED", "RETIRED")) { Add-ValidationError "AZ-MEMORY-SCHEMA" ".agent/SKILLS.md contains invalid lifecycle Status: $($match.Groups['status'].Value)" }
    }
}

$skillValidator = Join-Path $scriptRoot "validate-skill.ps1"
$candidateSkillsRoot = Join-Path $memoryRoot "skill-candidates"
if ((Test-Path -LiteralPath $skillValidator -PathType Leaf) -and (Test-Path -LiteralPath $candidateSkillsRoot -PathType Container)) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $candidateSkillsRoot -Directory -Force)) { try { & $skillValidator -SkillPath $directory.FullName -Mode Candidate | Out-Null } catch { Add-ValidationError "AZ-MEMORY-SKILL" $_.Exception.Message } }
}
$activeSkillsRoot = Join-Path $projectFullPath ".agents/skills"
if ((Test-Path -LiteralPath $skillValidator -PathType Leaf) -and (Test-Path -LiteralPath $activeSkillsRoot -PathType Container)) {
    $seenSkillNames = @{}
    foreach ($directory in @(Get-ChildItem -LiteralPath $activeSkillsRoot -Directory -Force)) {
        try {
            & $skillValidator -SkillPath $directory.FullName -Mode Active | Out-Null
            $skillText = Get-Content -Raw -LiteralPath (Join-Path $directory.FullName "SKILL.md")
            $match = [regex]::Match($skillText, '(?m)^name:\s*(?<value>.+?)\s*$')
            if ($match.Success) {
                $name = $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
                if ($seenSkillNames.ContainsKey($name)) { Add-ValidationError "AZ-MEMORY-SKILL" "Duplicate active repo skill name '$name'" }
                else { $seenSkillNames[$name] = $directory.FullName }
            }
        }
        catch { Add-ValidationError "AZ-MEMORY-SKILL" $_.Exception.Message }
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
