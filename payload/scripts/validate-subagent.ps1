param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$EvalsPath,

    [ValidateSet("Candidate", "Active")]
    [string]$Mode = "Candidate",

    [Parameter(Mandatory = $true)]
    [string]$ManagedNamespace,

    [string]$ProjectRoot,
    [string]$ExpectedRegistryId,
    [string]$ExpectedProviderId,
    [string]$ExpectedCapabilityKey,
    [string]$ExpectedName,
    [string]$ExpectedLifecycleStatus,
    [string]$ExpectedEvalsSha256,
    [string]$ExpectedCandidateSha256,
    [string]$ExpectedActiveSha256,
    [string]$ExpectedApprovedBy,
    [string]$ExpectedApprovalReference,
    [string]$ExpectedRollbackPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$configFullPath = [System.IO.Path]::GetFullPath($ConfigPath)
$evalsFullPath = [System.IO.Path]::GetFullPath($EvalsPath)
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError { param([string]$Message) $errors.Add($Message) }
function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}
function Get-MarkdownField {
    param([string]$Text, [string]$Label)
    $match = [regex]::Match($Text, '(?m)^\s*-\s*' + [regex]::Escape($Label) + ':\s*`(?<value>[^`]+)`\s*$')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return $null
}
function Test-ExpectedField {
    param([string]$Actual, [string]$Expected, [string]$Label)
    if (-not [string]::IsNullOrWhiteSpace($Expected) -and $Actual -ne $Expected) { Add-ValidationError "$Label must be $Expected, found: $Actual" }
}
function Test-HashEqual {
    param([string]$Actual, [string]$Expected)
    return -not [string]::IsNullOrWhiteSpace($Actual) -and
        -not [string]::IsNullOrWhiteSpace($Expected) -and
        $Actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)
}
function Test-ExpectedHashField {
    param([string]$Actual, [string]$Expected, [string]$Label)
    if (-not [string]::IsNullOrWhiteSpace($Expected) -and -not (Test-HashEqual $Actual $Expected)) { Add-ValidationError "$Label must be $Expected, found: $Actual" }
}
function Test-SamePath {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $actualFullPath = [System.IO.Path]::GetFullPath($Actual).TrimEnd('\', '/')
    $expectedFullPath = [System.IO.Path]::GetFullPath($Expected).TrimEnd('\', '/')
    return $actualFullPath.Equals($expectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)
}
function Get-ConfigHash {
    param([string]$Path)
    return "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash)"
}
function Test-ShaValue {
    param([string]$Value, [string]$Label, [switch]$AllowUnknown)
    if ($AllowUnknown -and $Value -eq "UNKNOWN") { return }
    if ($Value -notmatch '^SHA256:[A-Fa-f0-9]{64}$') { Add-ValidationError "$Label must be SHA256:<64 hex>$(if($AllowUnknown){' or UNKNOWN'}): $Value" }
}

function ConvertFrom-CanonicalSubagentToml {
    param([string]$Text)

    $allowedKeys = @("name", "description", "developer_instructions", "model", "model_reasoning_effort", "sandbox_mode")
    $values = @{}
    $instructionLines = [System.Collections.Generic.List[string]]::new()
    $insideInstructions = $false
    $lines = [regex]::Split($Text, '\r?\n')
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($insideInstructions) {
            if ($line -match '^\s*"""\s*$') {
                $values["developer_instructions"] = $instructionLines -join [Environment]::NewLine
                $insideInstructions = $false
            }
            elseif ($line.Contains('"""')) {
                Add-ValidationError "developer_instructions closing delimiter must appear alone on its line without comments or trailing content."
                $insideInstructions = $false
            }
            else {
                $instructionLines.Add($line)
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
        if ($line -match '^\s*developer_instructions\s*=\s*"""\s*$') {
            if ($values.ContainsKey("developer_instructions") -or $insideInstructions) {
                Add-ValidationError "Custom-agent config contains duplicate top-level key: developer_instructions"
            }
            $insideInstructions = $true
            continue
        }
        $assignment = [regex]::Match($line, '^\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"(?<value>[^"\\\r\n]*)"\s*$')
        if (-not $assignment.Success) {
            Add-ValidationError "Custom-agent schema v1 accepts only canonical bare-key double-quoted assignments and one multiline developer_instructions block; invalid line $($index + 1)."
            continue
        }
        $key = $assignment.Groups['key'].Value
        if ($key -notin $allowedKeys) {
            Add-ValidationError "Custom-agent schema v1 does not allow top-level key: $key"
            continue
        }
        if ($key -eq "developer_instructions") {
            Add-ValidationError "developer_instructions must be a multiline triple-quoted TOML string."
            continue
        }
        if ($values.ContainsKey($key)) {
            Add-ValidationError "Custom-agent config contains duplicate top-level key: $key"
            continue
        }
        $values[$key] = $assignment.Groups['value'].Value
    }
    if ($insideInstructions) { Add-ValidationError "developer_instructions multiline string is not terminated." }
    foreach ($requiredKey in @("name", "description", "developer_instructions")) {
        if (-not $values.ContainsKey($requiredKey)) { Add-ValidationError "Custom-agent config requires exactly one $requiredKey field." }
    }
    return $values
}

function Resolve-ValidationProjectRoot {
    param([string]$ExplicitRoot, [string]$StartPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        return [System.IO.Path]::GetFullPath($ExplicitRoot).TrimEnd('\', '/')
    }
    $cursor = Get-Item -LiteralPath $StartPath -Force
    if ($cursor -isnot [System.IO.DirectoryInfo]) { $cursor = $cursor.Directory }
    while ($null -ne $cursor) {
        if (Test-Path -LiteralPath (Join-Path $cursor.FullName ".agent") -PathType Container) {
            return $cursor.FullName.TrimEnd('\', '/')
        }
        $cursor = $cursor.Parent
    }
    return $null
}

function Test-SensitiveFile {
    param([string]$Path, [string]$Label)

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Add-ValidationError "$Label cannot be a reparse point: $Path"
        return
    }
    if ($item.Length -gt 8MB) {
        Add-ValidationError "$Label exceeds the 8 MiB bounded security-scan limit: $Path"
        return
    }
    $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($item.FullName))
    if ($text -match '(?i)(?:[A-Z]:[\\/]+Users[\\/]+|/Users/|/home/|\\\\)') { Add-ValidationError "$Label contains an absolute personal or UNC path." }
    if ($text -match '(?i)(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|authorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{12,}|["'']?(?:api[_-]?key|token|password|secret)["'']?\s*[:=]\s*["'']?[A-Za-z0-9._~+/=-]{8,})') { Add-ValidationError "$Label may contain a secret or credential." }
}

function Test-EvaluationArtifact {
    param([string]$Root, [string]$RelativePath, [string]$ExpectedHash, [string]$EvaluatedBy, [string]$EvaluatorRun, [string]$ExpectedCandidateHash)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        Add-ValidationError "Evaluated/approved sub-agent requires ProjectRoot so its evaluation artifact can be verified."
        return
    }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq "NONE" -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        Add-ValidationError "Evaluated/approved sub-agent requires a contained project-relative evaluation artifact."
        return
    }
    $rootFullPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootBoundary = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    $artifactFullPath = [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $RelativePath))
    if (-not $artifactFullPath.StartsWith($rootBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError "Evaluation artifact resolves outside ProjectRoot: $RelativePath"
        return
    }
    if (-not (Test-Path -LiteralPath $artifactFullPath -PathType Leaf)) {
        Add-ValidationError "Evaluation artifact does not exist: $RelativePath"
        return
    }
    $cursor = Get-Item -LiteralPath $artifactFullPath -Force
    while ($null -ne $cursor -and $cursor.FullName.StartsWith($rootBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-ValidationError "Evaluation artifact traverses a reparse point: $RelativePath"
            return
        }
        $cursor = if ($cursor -is [System.IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    Test-ShaValue $ExpectedHash "Evaluation SHA256"
    if ($ExpectedHash -match '^SHA256:') {
        $actualHash = "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $artifactFullPath).Hash)"
        if (-not $actualHash.Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-ValidationError "Evaluation SHA256 does not match the artifact: $RelativePath"
        }
    }
    Test-SensitiveFile -Path $artifactFullPath -Label "Evaluation artifact"
    $artifactText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($artifactFullPath))
    if (-not [string]::IsNullOrWhiteSpace($EvaluatedBy) -and -not $artifactText.Contains($EvaluatedBy)) {
        Add-ValidationError "Evaluation artifact does not identify its evaluator: $EvaluatedBy"
    }
    if (-not [string]::IsNullOrWhiteSpace($EvaluatorRun) -and -not $artifactText.Contains($EvaluatorRun)) {
        Add-ValidationError "Evaluation artifact does not identify its evaluator run: $EvaluatorRun"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCandidateHash) -and $artifactText.IndexOf($ExpectedCandidateHash, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Add-ValidationError "Evaluation artifact does not identify the evaluated candidate SHA256: $ExpectedCandidateHash"
    }
}

function Test-EvaluationSections {
    param([string]$Text, [string[]]$Headings)

    foreach ($heading in $Headings) {
        $match = [regex]::Match($Text, '(?ms)^' + [regex]::Escape($heading) + '\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
        if (-not $match.Success) {
            Add-ValidationError "Evals are missing evaluable section: $heading"
            continue
        }
        $tableLines = @($match.Groups['body'].Value -split '\r?\n' | Where-Object { $_.Trim().StartsWith('|') })
        if ($tableLines.Count -lt 3) {
            Add-ValidationError "$heading must contain at least one evaluation row."
            continue
        }
        $expectedHeader = switch ($heading) {
            "## Positive delegation triggers" { '| Prompt/case | Expected routing | Result | Evidence |' }
            "## Negative delegation triggers" { '| Prompt/case | Expected routing | Result | Evidence |' }
            "## Workflow verification" { '| Scenario | Expected output/check | Result | Evidence |' }
            "## Authority and isolation verification" { '| Check | Expected behavior | Result | Evidence |' }
            "## Collision and compatibility verification" { '| Check | Expected behavior | Result | Evidence |' }
            default { $null }
        }
        if ($null -eq $expectedHeader -or $tableLines[0].Trim() -ne $expectedHeader -or $tableLines[1].Trim() -ne '|---|---|---|---|') {
            Add-ValidationError "$heading must use its exact four-column evaluation header and separator."
            continue
        }
        foreach ($line in @($tableLines | Select-Object -Skip 2)) {
            $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim().Trim('`').Trim() })
            if ($cells.Count -ne 4) {
                Add-ValidationError "$heading contains a malformed evaluation row."
                continue
            }
            if ($cells[2] -ne "PASS") { Add-ValidationError "$heading requires PASS for every evaluation row; found: $($cells[2])" }
            foreach ($cellIndex in @(0, 1, 3)) {
                if ([string]::IsNullOrWhiteSpace($cells[$cellIndex]) -or $cells[$cellIndex] -in @("NONE", "UNKNOWN", "NOT_RUN") -or $cells[$cellIndex].Length -gt 512 -or $cells[$cellIndex] -match '[\x00-\x1F]') {
                    Add-ValidationError "$heading requires substantive bounded case, expected behavior, and evidence cells."
                    break
                }
            }
        }
    }
}

function Resolve-ContainedExistingPath {
    param([string]$Root, [string]$RelativePath, [string]$ExpectedRoot, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -in @("NONE", "UNKNOWN") -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        Add-ValidationError "$Label must be a contained project-relative path."
        return $null
    }
    $rootFullPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootBoundary = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
    $expectedFullRoot = [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $ExpectedRoot)).TrimEnd('\', '/')
    $expectedBoundary = $expectedFullRoot + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootFullPath $RelativePath))
    if (-not $fullPath.StartsWith($rootBoundary, [System.StringComparison]::OrdinalIgnoreCase) -or
        (-not $fullPath.Equals($expectedFullRoot, [System.StringComparison]::OrdinalIgnoreCase) -and -not $fullPath.StartsWith($expectedBoundary, [System.StringComparison]::OrdinalIgnoreCase))) {
        Add-ValidationError "$Label resolves outside $ExpectedRoot`: $RelativePath"
        return $null
    }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        Add-ValidationError "$Label does not exist: $RelativePath"
        return $null
    }
    $cursor = Get-Item -LiteralPath $fullPath -Force
    while ($null -ne $cursor -and $cursor.FullName.StartsWith($rootBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-ValidationError "$Label traverses a reparse point: $RelativePath"
            return $null
        }
        $cursor = if ($cursor -is [System.IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    return $fullPath
}

if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) { throw "Sub-agent validation failed: config does not exist: $configFullPath" }
if (-not (Test-Path -LiteralPath $evalsFullPath -PathType Leaf)) { throw "Sub-agent validation failed: evals do not exist: $evalsFullPath" }
if ($ManagedNamespace -eq "UNKNOWN" -or $ManagedNamespace -notmatch '^az_[a-z0-9]+(?:_[a-z0-9]+)*_$') {
    Add-ValidationError "ManagedNamespace must be a stable lowercase az_<project>_ prefix."
}

$configText = Read-Utf8Text $configFullPath
if ($configText -match 'REPLACE_ME|replace_project|replace_role') { Add-ValidationError "Custom-agent config still contains template placeholders." }
Test-SensitiveFile -Path $configFullPath -Label "Custom-agent config"
$configValues = ConvertFrom-CanonicalSubagentToml -Text $configText
$agentName = if ($configValues.ContainsKey("name")) { [string]$configValues["name"] } else { "UNKNOWN" }
$description = if ($configValues.ContainsKey("description")) { [string]$configValues["description"] } else { "" }
$instructions = if ($configValues.ContainsKey("developer_instructions")) { [string]$configValues["developer_instructions"] } else { "" }
if ($agentName -notmatch '^[a-z][a-z0-9_-]{2,63}$') { Add-ValidationError "Agent name is invalid: $agentName" }
if ($agentName -in @("default", "worker", "explorer")) { Add-ValidationError "Agent name cannot shadow a built-in agent: $agentName" }
if ($ManagedNamespace -ne "UNKNOWN" -and -not $agentName.StartsWith($ManagedNamespace, [System.StringComparison]::Ordinal)) { Add-ValidationError "Agent name must start with managed namespace $ManagedNamespace." }
if ($description.Length -lt 20 -or $description -notmatch '(?i)\buse when\b|\bd\u00F9ng khi\b' -or $description -notmatch '(?i)\bdo not use\b|\bkh\u00F4ng d\u00F9ng\b') {
    Add-ValidationError "Agent description must define both use and non-use trigger boundaries."
}
foreach ($marker in @("Role outcome:", "Input contract:", "Authority:", "Delegation:", "Memory ownership:", "Verification:", "Return contract:")) {
    if (-not $instructions.Contains($marker)) { Add-ValidationError "developer_instructions is missing contract marker: $marker" }
}
if ($instructions -notmatch '(?i)do not spawn|do not delegate' -or $instructions -notmatch '(?i)inherit the parent|parent task scope') {
    Add-ValidationError "developer_instructions must preserve parent authority and default no-nested-delegation."
}
$sandboxMode = if ($configValues.ContainsKey("sandbox_mode")) { [string]$configValues["sandbox_mode"] } else { $null }
if (-not [string]::IsNullOrWhiteSpace($sandboxMode) -and $sandboxMode -ne "read-only") { Add-ValidationError "Custom-agent schema v1 permits only sandbox_mode=read-only when explicitly set." }

$evalsText = Read-Utf8Text $evalsFullPath
$actualEvalsHash = "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $evalsFullPath).Hash)"
Test-ExpectedHashField $actualEvalsHash $ExpectedEvalsSha256 "Evals SHA256"
if ($ExpectedLifecycleStatus -in @("EVALUATED", "APPROVED", "ENABLED", "RETIRED") -and $ExpectedEvalsSha256 -notmatch '^SHA256:[A-Fa-f0-9]{64}$') {
    Add-ValidationError "Registry lifecycle $ExpectedLifecycleStatus requires ExpectedEvalsSha256."
}
Test-SensitiveFile -Path $evalsFullPath -Label "Sub-agent evals"
$validationProjectRoot = Resolve-ValidationProjectRoot -ExplicitRoot $ProjectRoot -StartPath $configFullPath
$expectedCandidateConfigFullPath = $null
if ($Mode -eq "Candidate") {
    $expectedCandidateConfigFullPath = $configFullPath
    $expectedEvalsFullPath = Join-Path (Split-Path -Parent $configFullPath) "EVALS.md"
    if (-not (Test-SamePath $evalsFullPath $expectedEvalsFullPath)) {
        Add-ValidationError "Candidate EvalsPath must be the EVALS.md beside this exact candidate config."
    }
}
else {
    $expectedEvalsFullPath = Join-Path (Split-Path -Parent $evalsFullPath) "EVALS.md"
    if (-not (Test-SamePath $evalsFullPath $expectedEvalsFullPath)) {
        Add-ValidationError "Active custom-agent EvalsPath must identify the canonical EVALS.md in its candidate directory."
    }
    $expectedCandidateConfigFullPath = Join-Path (Split-Path -Parent $evalsFullPath) "SUBAGENT.toml"
}
if (-not [string]::IsNullOrWhiteSpace($validationProjectRoot)) {
    $candidateRootFullPath = [System.IO.Path]::GetFullPath((Join-Path $validationProjectRoot ".agent/subagent-candidates")).TrimEnd('\', '/')
    $candidateRootBoundary = $candidateRootFullPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $evalsFullPath.StartsWith($candidateRootBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-ValidationError "EvalsPath must stay inside .agent/subagent-candidates."
    }
}
foreach ($heading in @("## Positive delegation triggers", "## Negative delegation triggers", "## Workflow verification", "## Authority and isolation verification", "## Collision and compatibility verification", "## Promotion record")) {
    if (-not $evalsText.Contains($heading)) { Add-ValidationError "Evals are missing heading: $heading" }
}
$status = Get-MarkdownField $evalsText "Status"
if ($status -notin @("DRAFT", "EVALUATED", "APPROVED")) { Add-ValidationError "Evals Status must be DRAFT, EVALUATED, or APPROVED." }
if (-not [string]::IsNullOrWhiteSpace($ExpectedLifecycleStatus)) {
    if ($ExpectedLifecycleStatus -notin @("DRAFT", "EVALUATED", "APPROVED", "ENABLED", "RETIRED")) {
        Add-ValidationError "ExpectedLifecycleStatus is invalid: $ExpectedLifecycleStatus"
    }
    elseif ($ExpectedLifecycleStatus -ne "RETIRED") {
        $expectedEvalStatus = if ($ExpectedLifecycleStatus -eq "ENABLED") { "APPROVED" } else { $ExpectedLifecycleStatus }
        if ($status -ne $expectedEvalStatus) { Add-ValidationError "Registry lifecycle $ExpectedLifecycleStatus requires Evals status $expectedEvalStatus; found: $status" }
    }
}
$registryId = Get-MarkdownField $evalsText "Registry ID"
$providerId = Get-MarkdownField $evalsText "Provider ID"
$capabilityKey = Get-MarkdownField $evalsText "Capability key"
$evalAgentName = Get-MarkdownField $evalsText "Agent name"
$createdByRun = Get-MarkdownField $evalsText "Created by run"
$evaluatedBy = Get-MarkdownField $evalsText "Evaluated by"
$evaluatorRun = Get-MarkdownField $evalsText "Evaluator run"
$lastRun = Get-MarkdownField $evalsText "Last run"
$evaluationArtifact = Get-MarkdownField $evalsText "Evaluation artifact"
$evaluationHash = Get-MarkdownField $evalsText "Evaluation SHA256"
$approvedBy = Get-MarkdownField $evalsText "Approved by"
$candidateHash = Get-MarkdownField $evalsText "Candidate config SHA256"
$approvalReference = Get-MarkdownField $evalsText "Approval reference"
$destination = Get-MarkdownField $evalsText "Destination"
$expectedActiveHash = Get-MarkdownField $evalsText "Expected active SHA256"
$rollbackPath = Get-MarkdownField $evalsText "Rollback path"
$discovery = Get-MarkdownField $evalsText "Discovery verification"

if ($registryId -notmatch '^SA-\d{3,}$') { Add-ValidationError "Evals Registry ID is invalid: $registryId" }
if ($providerId -notmatch '^CP-\d{3,}$') { Add-ValidationError "Evals Provider ID is invalid: $providerId" }
if ($capabilityKey -notmatch '^[a-z0-9]+(?:\.[a-z0-9]+)*$') { Add-ValidationError "Evals Capability key is invalid: $capabilityKey" }
if ($evalAgentName -ne $agentName) { Add-ValidationError "Evals Agent name does not match TOML name." }
Test-ExpectedField $registryId $ExpectedRegistryId "Registry ID"
Test-ExpectedField $providerId $ExpectedProviderId "Provider ID"
Test-ExpectedField $capabilityKey $ExpectedCapabilityKey "Capability key"
Test-ExpectedField $agentName $ExpectedName "Agent name"

$actualHash = Get-ConfigHash $configFullPath
$expectedDestination = ".codex/agents/$agentName.toml"
if ($destination -ne $expectedDestination) { Add-ValidationError "Destination must match agent name: $expectedDestination" }
if ($status -in @("EVALUATED", "APPROVED")) {
    if ($evalsText -match 'REPLACE_ME|replace_project|replace_role') { Add-ValidationError "$status evals cannot contain placeholders." }
    if ([string]::IsNullOrWhiteSpace($lastRun) -or $lastRun -in @("NOT_RUN", "NONE", "UNKNOWN")) { Add-ValidationError "$status evals require a completed Last run." }
    if ([string]::IsNullOrWhiteSpace($createdByRun) -or $createdByRun -in @("NONE", "UNKNOWN")) { Add-ValidationError "$status evals require creator provenance." }
    if ([string]::IsNullOrWhiteSpace($evaluatedBy) -or $evaluatedBy -in @("NONE", "UNKNOWN") -or [string]::IsNullOrWhiteSpace($evaluatorRun) -or $evaluatorRun -in @("NONE", "UNKNOWN")) { Add-ValidationError "$status evals require evaluator provenance." }
    if ($evaluatorRun -eq $createdByRun) { Add-ValidationError "Evaluator run must differ from creator run." }
    Test-ShaValue $candidateHash "Candidate config SHA256"
    if ($candidateHash -match '^SHA256:' -and -not (Test-HashEqual $candidateHash $actualHash)) { Add-ValidationError "Candidate config SHA256 does not match the evaluated config." }
    Test-EvaluationSections -Text $evalsText -Headings @("## Positive delegation triggers", "## Negative delegation triggers", "## Workflow verification", "## Authority and isolation verification", "## Collision and compatibility verification")
    Test-EvaluationArtifact -Root $validationProjectRoot -RelativePath $evaluationArtifact -ExpectedHash $evaluationHash -EvaluatedBy $evaluatedBy -EvaluatorRun $evaluatorRun -ExpectedCandidateHash $candidateHash
}
if ($status -eq "APPROVED" -or $Mode -eq "Active") {
    if ([string]::IsNullOrWhiteSpace($approvedBy) -or $approvedBy -in @("NONE", "UNKNOWN")) { Add-ValidationError "Approved/active profile requires Approved by." }
    if ([string]::IsNullOrWhiteSpace($approvalReference) -or $approvalReference -in @("NONE", "UNKNOWN")) { Add-ValidationError "Approved/active profile requires Approval reference." }
    if ([string]::IsNullOrWhiteSpace($rollbackPath) -or $rollbackPath -in @("NONE", "UNKNOWN")) { Add-ValidationError "Approved/active profile requires Rollback path." }
    else {
        $resolvedRollbackPath = Resolve-ContainedExistingPath -Root $validationProjectRoot -RelativePath $rollbackPath -ExpectedRoot ".agent/subagent-candidates" -Label "Rollback path"
        if ($null -ne $resolvedRollbackPath -and -not (Test-SamePath $resolvedRollbackPath $expectedCandidateConfigFullPath)) {
            Add-ValidationError "Rollback path must identify the exact candidate config associated with these evals."
        }
    }
    Test-ShaValue $candidateHash "Candidate config SHA256"
    Test-ShaValue $expectedActiveHash "Expected active SHA256"
    if ($candidateHash -match '^SHA256:' -and -not (Test-HashEqual $candidateHash $actualHash)) { Add-ValidationError "Config hash does not match approved candidate hash." }
    if ($expectedActiveHash -match '^SHA256:' -and -not (Test-HashEqual $expectedActiveHash $candidateHash)) { Add-ValidationError "Expected active hash must match candidate hash." }
}
Test-ExpectedHashField $actualHash $ExpectedCandidateSha256 "Actual candidate SHA256"
Test-ExpectedField $approvedBy $ExpectedApprovedBy "Approved by"
Test-ExpectedField $approvalReference $ExpectedApprovalReference "Approval reference"
Test-ExpectedField $rollbackPath $ExpectedRollbackPath "Rollback path"
if ($Mode -eq "Active") {
    if ($status -ne "APPROVED") { Add-ValidationError "Active custom agent requires APPROVED evals." }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLifecycleStatus) -and $ExpectedLifecycleStatus -ne "ENABLED") { Add-ValidationError "Active custom agent requires registry lifecycle ENABLED; found: $ExpectedLifecycleStatus" }
    if ($discovery -ne "PASS") { Add-ValidationError "Active custom agent requires fresh-session Discovery verification PASS." }
    Test-ExpectedHashField $actualHash $ExpectedActiveSha256 "Actual active SHA256"
    if ([string]::IsNullOrWhiteSpace($validationProjectRoot)) {
        Add-ValidationError "Active custom-agent validation requires ProjectRoot so Destination can be bound to ConfigPath."
    }
    else {
        $expectedConfigPath = [System.IO.Path]::GetFullPath((Join-Path $validationProjectRoot $expectedDestination))
        if (-not $configFullPath.Equals($expectedConfigPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-ValidationError "Active ConfigPath must match the approved Destination: $expectedDestination"
        }
    }
}

if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Sub-agent validation failed ($Mode):$([Environment]::NewLine)$details"
}

Write-Host "Sub-agent validation passed." -ForegroundColor Green
Write-Host "Mode: $Mode"
Write-Host "Agent name: $agentName"
Write-Host "Config SHA256: $actualHash"
