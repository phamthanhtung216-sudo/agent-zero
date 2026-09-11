param(
    [Parameter(Mandatory = $true)]
    [string]$SkillPath,

    [ValidateSet("Candidate", "Active")]
    [string]$Mode = "Candidate",

    [string]$ProjectRoot,
    [string]$ExpectedRegistryId,
    [string]$ExpectedProviderId,
    [string]$ExpectedCapabilityKey,
    [string]$ExpectedName,
    [string]$ExpectedLifecycleStatus,
    [string]$ExpectedEvalsSha256,
    [string]$ExpectedCandidateSha256,
    [string]$ExpectedActiveSha256,
    [string]$ApprovalEvalsPath,
    [string]$ExpectedApprovedBy,
    [string]$ExpectedApprovalReference,
    [string]$ExpectedRollbackPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$skillFullPath = [System.IO.Path]::GetFullPath($SkillPath)
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError {
    param([string]$Message)
    $errors.Add($Message)
}
function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}

function Get-MarkdownField {
    param(
        [string]$Text,
        [string]$Label
    )

    $pattern = '(?m)^\s*-\s*' + [regex]::Escape($Label) + ':\s*`(?<value>[^`]+)`\s*$'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        return $match.Groups["value"].Value.Trim()
    }
    return $null
}

function Get-FirstMarkdownField {
    param([string]$Text, [string[]]$Labels)
    foreach ($label in $Labels) {
        $value = Get-MarkdownField -Text $Text -Label $label
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}

function Get-CanonicalPayloadHash {
    param([string]$Root, [object[]]$Files, [switch]$ExcludeRootEvals)

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $boundary = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    $lines = @(
        $Files |
            Sort-Object FullName |
            ForEach-Object {
                $relative = $_.FullName.Substring($boundary.Length).Replace('\', '/')
                if (-not ($ExcludeRootEvals -and $relative -eq "EVALS.md")) {
                    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
                    "$relative|$hash"
                }
            }
    )
    if ($lines.Count -eq 0) { return $null }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return "SHA256:$([System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', ''))" }
    finally { $sha.Dispose() }
}

function Get-SafePayloadFiles {
    param([string]$Root)

    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Add-ValidationError "Skill payload root cannot be a reparse point: $($rootItem.FullName)"
        return @()
    }

    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $pending.Push([System.IO.DirectoryInfo]$rootItem)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in $directory.GetFileSystemInfos()) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-ValidationError "Skill payload cannot contain a reparse point: $($entry.FullName)"
                continue
            }
            if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $pending.Push([System.IO.DirectoryInfo]$entry)
            }
            else {
                $files.Add([System.IO.FileInfo]$entry)
            }
        }
    }
    return @($files)
}

function Test-SensitiveFile {
    param([System.IO.FileInfo]$File, [string]$Label)

    $maxScannableBytes = 8MB
    if ($File.Length -gt $maxScannableBytes) {
        Add-ValidationError "$Label exceeds the 8 MiB bounded security-scan limit: $($File.FullName)"
        return
    }
    $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($File.FullName))
    if ($text -match '(?i)(?:[A-Z]:[\\/]+Users[\\/]+|/Users/|/home/|\\\\)') {
        Add-ValidationError "$Label contains an absolute personal or UNC path: $($File.FullName)"
    }
    if ($text -match '(?i)(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|authorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{12,}|["'']?(?:api[_-]?key|token|password|secret)["'']?\s*[:=]\s*["'']?[A-Za-z0-9._~+/=-]{8,})') {
        Add-ValidationError "$Label may contain a secret or credential: $($File.FullName)"
    }
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

function Test-EvaluationArtifact {
    param([string]$Root, [string]$RelativePath, [string]$ExpectedHash, [string]$EvaluatedBy, [string]$EvaluatorRun, [string]$ExpectedCandidateHash)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        Add-ValidationError "Evaluated/approved skill requires ProjectRoot so its evaluation artifact can be verified."
        return
    }
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq "NONE" -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        Add-ValidationError "Evaluated/approved skill requires a contained project-relative evaluation artifact."
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
    Test-StrictSha $ExpectedHash "Evaluation SHA256"
    if ($ExpectedHash -match '^SHA256:' ) {
        $actualHash = "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $artifactFullPath).Hash)"
        if (-not $actualHash.Equals($ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-ValidationError "Evaluation SHA256 does not match the artifact: $RelativePath"
        }
    }
    Test-SensitiveFile -File ([System.IO.FileInfo](Get-Item -LiteralPath $artifactFullPath -Force)) -Label "Evaluation artifact"
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
            Add-ValidationError "EVALS.md is missing evaluable section: $heading"
            continue
        }
        $tableLines = @($match.Groups['body'].Value -split '\r?\n' | Where-Object { $_.Trim().StartsWith('|') })
        if ($tableLines.Count -lt 3) {
            Add-ValidationError "$heading must contain at least one evaluation row."
            continue
        }
        $expectedHeader = switch ($heading) {
            "## Positive triggers" { '| Prompt/case | Expected behavior | Result | Evidence |' }
            "## Negative triggers" { '| Prompt/case | Expected behavior | Result | Evidence |' }
            "## Workflow verification" { '| Scenario | Expected output/check | Result | Evidence |' }
            default { $null }
        }
        if ($null -eq $expectedHeader -or $tableLines[0].Trim() -ne $expectedHeader -or $tableLines[1].Trim() -ne '|---|---|---|---|') {
            Add-ValidationError "$heading must use its exact four-column evaluation header and separator."
            continue
        }
        $dataRows = @($tableLines | Select-Object -Skip 2)
        if ($dataRows.Count -eq 0) {
            Add-ValidationError "$heading must contain at least one evaluation row."
            continue
        }
        foreach ($line in $dataRows) {
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
    param([string]$Root, [string]$RelativePath, [string]$ExpectedRoot, [string]$Label, [switch]$RequireLeaf)

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
    $exists = if ($RequireLeaf) { Test-Path -LiteralPath $fullPath -PathType Leaf } else { Test-Path -LiteralPath $fullPath }
    if (-not $exists) {
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

function Test-ExpectedField {
    param([string]$Actual, [string]$Expected, [string]$Label)
    if (-not [string]::IsNullOrWhiteSpace($Expected) -and $Expected -ne "UNKNOWN" -and $Actual -ne $Expected) {
        Add-ValidationError "$Label must be $Expected, found: $Actual"
    }
}

function Test-HashEqual {
    param([string]$Actual, [string]$Expected)
    return -not [string]::IsNullOrWhiteSpace($Actual) -and
        -not [string]::IsNullOrWhiteSpace($Expected) -and
        $Actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ExpectedHashField {
    param([string]$Actual, [string]$Expected, [string]$Label)
    if (-not [string]::IsNullOrWhiteSpace($Expected) -and $Expected -ne "UNKNOWN" -and -not (Test-HashEqual $Actual $Expected)) {
        Add-ValidationError "$Label must be $Expected, found: $Actual"
    }
}

function Test-SamePath {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $actualFullPath = [System.IO.Path]::GetFullPath($Actual).TrimEnd('\', '/')
    $expectedFullPath = [System.IO.Path]::GetFullPath($Expected).TrimEnd('\', '/')
    return $actualFullPath.Equals($expectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-StrictSha {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^SHA256:[A-Fa-f0-9]{64}$') { Add-ValidationError "$Label must be SHA256:<64 hex>: $Value" }
}

if (-not (Test-Path -LiteralPath $skillFullPath -PathType Container)) {
    throw "Skill validation failed: directory does not exist: $skillFullPath"
}

$payloadFiles = @(Get-SafePayloadFiles -Root $skillFullPath)
foreach ($payloadFile in $payloadFiles) { Test-SensitiveFile -File $payloadFile -Label "Skill payload" }

$skillFile = Join-Path $skillFullPath "SKILL.md"
$skillName = $null
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    Add-ValidationError "Missing SKILL.md: $skillFile"
}
else {
    $skillText = Read-Utf8Text $skillFile
    $frontmatterMatch = [regex]::Match($skillText, '(?s)\A---\s*\r?\n(?<frontmatter>.*?)\r?\n---\s*\r?\n')
    if (-not $frontmatterMatch.Success) {
        Add-ValidationError "SKILL.md must begin with YAML frontmatter delimited by --- lines."
    }
    else {
        $frontmatter = $frontmatterMatch.Groups["frontmatter"].Value
        $nameMatches = [regex]::Matches($frontmatter, '(?m)^name:\s*(?<value>.+?)\s*$')
        $descriptionMatches = [regex]::Matches($frontmatter, '(?m)^description:\s*(?<value>.+?)\s*$')
        $nameMatch = if ($nameMatches.Count -gt 0) { $nameMatches[0] } else { $null }
        $descriptionMatch = if ($descriptionMatches.Count -gt 0) { $descriptionMatches[0] } else { $null }

        if ($nameMatches.Count -ne 1) {
            Add-ValidationError "SKILL.md frontmatter must contain exactly one top-level name field; found $($nameMatches.Count)."
        }
        if ($null -ne $nameMatch) {
            $skillName = $nameMatch.Groups["value"].Value.Trim().Trim('"').Trim("'")
            if ($skillName.Length -gt 64 -or $skillName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                Add-ValidationError "Skill name must be 1-64 lowercase letters/digits with single hyphen separators: $skillName"
            }
        }

        if ($descriptionMatches.Count -ne 1) {
            Add-ValidationError "SKILL.md frontmatter must contain exactly one top-level description field; found $($descriptionMatches.Count)."
        }
        if ($null -ne $descriptionMatch) {
            $description = $descriptionMatch.Groups["value"].Value.Trim().Trim('"').Trim("'")
            if ($description.Length -lt 20) {
                Add-ValidationError "Skill description is too short to define a reliable trigger boundary."
            }
            if ($description -notmatch '(?i)\buse when\b|\bd\u00F9ng khi\b') {
                Add-ValidationError "Skill description must state when to use the skill."
            }
            if ($description -notmatch '(?i)\bdo not use\b|\bkh\u00F4ng d\u00F9ng\b') {
                Add-ValidationError "Skill description must state when not to use the skill."
            }
        }
    }

    if ($skillText -match 'REPLACE_ME|replace-with-skill-name') {
        Add-ValidationError "SKILL.md still contains template placeholders."
    }
}

$validationProjectRoot = Resolve-ValidationProjectRoot -ExplicitRoot $ProjectRoot -StartPath $skillFullPath
$embeddedEvalsFile = Join-Path $skillFullPath "EVALS.md"
$managedActiveEvidence = $Mode -eq "Active" -and -not [string]::IsNullOrWhiteSpace($ApprovalEvalsPath)
$strictContract = -not [string]::IsNullOrWhiteSpace($ExpectedRegistryId) -or -not [string]::IsNullOrWhiteSpace($ExpectedProviderId) -or -not [string]::IsNullOrWhiteSpace($ExpectedCapabilityKey) -or -not [string]::IsNullOrWhiteSpace($ExpectedName) -or -not [string]::IsNullOrWhiteSpace($ExpectedEvalsSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedCandidateSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedActiveSha256) -or -not [string]::IsNullOrWhiteSpace($ExpectedApprovedBy) -or -not [string]::IsNullOrWhiteSpace($ExpectedApprovalReference) -or -not [string]::IsNullOrWhiteSpace($ExpectedRollbackPath)
if ($ExpectedLifecycleStatus -in @("EVALUATED", "APPROVED", "ENABLED", "RETIRED") -and $ExpectedEvalsSha256 -notmatch '^SHA256:[A-Fa-f0-9]{64}$') {
    Add-ValidationError "Registry lifecycle $ExpectedLifecycleStatus requires ExpectedEvalsSha256."
}
$actualPayloadHash = Get-CanonicalPayloadHash -Root $skillFullPath -Files $payloadFiles -ExcludeRootEvals:($Mode -eq "Candidate" -or -not $managedActiveEvidence)
$evalsFile = $embeddedEvalsFile
$managedCandidateFullPath = $null
if ($managedActiveEvidence) {
    if (Test-Path -LiteralPath $embeddedEvalsFile -PathType Leaf) {
        Add-ValidationError "Managed active skill payload must not contain embedded EVALS.md; approval evidence stays in the candidate registry path."
    }
    $resolvedApprovalEvals = Resolve-ContainedExistingPath -Root $validationProjectRoot -RelativePath $ApprovalEvalsPath -ExpectedRoot ".agent/skill-candidates" -Label "Approval EVALS.md" -RequireLeaf
    if ($null -ne $resolvedApprovalEvals) {
        $evalsFile = $resolvedApprovalEvals
        $expectedApprovalEvals = Join-Path (Split-Path -Parent $resolvedApprovalEvals) "EVALS.md"
        if (-not (Test-SamePath $resolvedApprovalEvals $expectedApprovalEvals)) {
            Add-ValidationError "Approval EVALS.md must be the canonical EVALS.md file in its candidate directory."
        }
        $managedCandidateFullPath = Split-Path -Parent $resolvedApprovalEvals
        Test-SensitiveFile -File ([System.IO.FileInfo](Get-Item -LiteralPath $evalsFile -Force)) -Label "Approval evidence"
    }
}

$expectedDestination = if ([string]::IsNullOrWhiteSpace($skillName)) { $null } else { ".agents/skills/$skillName" }
if ($Mode -eq "Candidate") {
    if (-not (Test-Path -LiteralPath $evalsFile -PathType Leaf)) {
        Add-ValidationError "Candidate skill is missing EVALS.md."
    }
    else {
        $evalsText = Read-Utf8Text $evalsFile
        $actualEvalsHash = "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $evalsFile).Hash)"
        Test-ExpectedHashField $actualEvalsHash $ExpectedEvalsSha256 "Evals SHA256"
        $evalStatus = Get-MarkdownField -Text $evalsText -Label "Status"
        $candidateHash = Get-FirstMarkdownField -Text $evalsText -Labels @("Candidate SHA256", "Candidate hash")
        $approvedBy = Get-MarkdownField -Text $evalsText -Label "Approved by"
        $approvalReference = Get-MarkdownField -Text $evalsText -Label "Approval reference"
        $destination = Get-MarkdownField -Text $evalsText -Label "Destination"
        $rollbackPath = Get-MarkdownField -Text $evalsText -Label "Rollback path"
        if ($evalStatus -notin @("DRAFT", "EVALUATED", "APPROVED")) {
            Add-ValidationError "EVALS.md Status must be DRAFT, EVALUATED, or APPROVED."
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedLifecycleStatus)) {
            if ($ExpectedLifecycleStatus -notin @("DRAFT", "EVALUATED", "APPROVED", "ENABLED", "RETIRED")) {
                Add-ValidationError "ExpectedLifecycleStatus is invalid: $ExpectedLifecycleStatus"
            }
            elseif ($ExpectedLifecycleStatus -ne "RETIRED") {
                $expectedEvalStatus = if ($ExpectedLifecycleStatus -eq "ENABLED") { "APPROVED" } else { $ExpectedLifecycleStatus }
                if ($evalStatus -ne $expectedEvalStatus) { Add-ValidationError "Registry lifecycle $ExpectedLifecycleStatus requires EVALS status $expectedEvalStatus; found: $evalStatus" }
            }
        }

        foreach ($heading in @("## Positive triggers", "## Negative triggers", "## Workflow verification", "## Promotion record")) {
            if (-not $evalsText.Contains($heading)) {
                Add-ValidationError "EVALS.md is missing heading: $heading"
            }
        }

        if ($evalsText -match 'REPLACE_ME|replace-with-skill-name') {
            Add-ValidationError "EVALS.md still contains template placeholders."
        }
        if ($null -ne $expectedDestination -and $destination -ne $expectedDestination) {
            Add-ValidationError "Skill Destination must match its discovery name: $expectedDestination"
        }

        if ($evalStatus -in @("EVALUATED", "APPROVED")) {
            $createdByRun = Get-MarkdownField -Text $evalsText -Label "Created by run"
            $evaluatedBy = Get-MarkdownField -Text $evalsText -Label "Evaluated by"
            $evaluatorRun = Get-MarkdownField -Text $evalsText -Label "Evaluator run"
            $lastRun = Get-MarkdownField -Text $evalsText -Label "Last run"
            $evaluationArtifact = Get-MarkdownField -Text $evalsText -Label "Evaluation artifact"
            $evaluationHash = Get-MarkdownField -Text $evalsText -Label "Evaluation SHA256"
            if ($evalsText -match 'REPLACE_ME|replace-with-skill-name') { Add-ValidationError "$evalStatus candidate cannot contain placeholders." }
            if ([string]::IsNullOrWhiteSpace($lastRun) -or $lastRun -in @("NOT_RUN", "NONE", "UNKNOWN")) { Add-ValidationError "$evalStatus candidate requires a completed Last run." }
            if ([string]::IsNullOrWhiteSpace($createdByRun) -or $createdByRun -in @("NONE", "UNKNOWN")) { Add-ValidationError "$evalStatus candidate requires creator provenance." }
            if ([string]::IsNullOrWhiteSpace($evaluatedBy) -or $evaluatedBy -in @("NONE", "UNKNOWN") -or [string]::IsNullOrWhiteSpace($evaluatorRun) -or $evaluatorRun -in @("NONE", "UNKNOWN")) { Add-ValidationError "$evalStatus candidate requires evaluator provenance." }
            if ($evaluatorRun -eq $createdByRun) { Add-ValidationError "Evaluator run must differ from creator run." }
            Test-StrictSha $candidateHash "Candidate SHA256"
            if ($candidateHash -match '^SHA256:' -and -not (Test-HashEqual $candidateHash $actualPayloadHash)) { Add-ValidationError "Candidate SHA256 does not match the evaluated payload." }
            Test-EvaluationSections -Text $evalsText -Headings @("## Positive triggers", "## Negative triggers", "## Workflow verification")
            Test-EvaluationArtifact -Root $validationProjectRoot -RelativePath $evaluationArtifact -ExpectedHash $evaluationHash -EvaluatedBy $evaluatedBy -EvaluatorRun $evaluatorRun -ExpectedCandidateHash $candidateHash
        }

        if ($evalStatus -eq "APPROVED") {
            if ([string]::IsNullOrWhiteSpace($approvedBy) -or $approvedBy -in @("NONE", "UNKNOWN")) {
                Add-ValidationError "APPROVED candidate must record Approved by."
            }
            if ([string]::IsNullOrWhiteSpace($approvalReference) -or $approvalReference -in @("NONE", "UNKNOWN")) { Add-ValidationError "APPROVED candidate must record Approval reference." }
            if ([string]::IsNullOrWhiteSpace($rollbackPath) -or $rollbackPath -in @("NONE", "UNKNOWN")) {
                Add-ValidationError "APPROVED candidate must record Rollback path."
            }
            else {
                $resolvedRollbackPath = Resolve-ContainedExistingPath -Root $validationProjectRoot -RelativePath $rollbackPath -ExpectedRoot ".agent/skill-candidates" -Label "Rollback path"
                if ($null -ne $resolvedRollbackPath -and -not (Test-SamePath $resolvedRollbackPath $skillFullPath)) {
                    Add-ValidationError "Candidate Rollback path must identify this exact candidate directory."
                }
            }
        }

        if ($strictContract) {
            $registryId = Get-MarkdownField -Text $evalsText -Label "Registry ID"
            $providerId = Get-MarkdownField -Text $evalsText -Label "Provider ID"
            $capabilityKey = Get-MarkdownField -Text $evalsText -Label "Capability key"
            $evalSkillName = Get-MarkdownField -Text $evalsText -Label "Skill name"
            Test-ExpectedField $registryId $ExpectedRegistryId "Registry ID"
            Test-ExpectedField $providerId $ExpectedProviderId "Provider ID"
            Test-ExpectedField $capabilityKey $ExpectedCapabilityKey "Capability key"
            Test-ExpectedField $evalSkillName $ExpectedName "Evals Skill name"
            Test-ExpectedField $skillName $ExpectedName "SKILL.md name"
            Test-ExpectedHashField $actualPayloadHash $ExpectedCandidateSha256 "Candidate payload SHA256"
            Test-ExpectedField $approvedBy $ExpectedApprovedBy "Approved by"
            Test-ExpectedField $approvalReference $ExpectedApprovalReference "Approval reference"
            Test-ExpectedField $rollbackPath $ExpectedRollbackPath "Rollback path"
            if ($evalStatus -eq "APPROVED") {
                $expectedActiveHash = Get-MarkdownField -Text $evalsText -Label "Expected active SHA256"
                Test-StrictSha $expectedActiveHash "Expected active SHA256"
                if ($expectedActiveHash -match '^SHA256:' -and -not (Test-HashEqual $expectedActiveHash $candidateHash)) { Add-ValidationError "Expected active SHA256 must match Candidate SHA256." }
            }
        }
    }
}
else {
    if (-not (Test-Path -LiteralPath $evalsFile -PathType Leaf)) {
        Add-ValidationError "Active Agent Zero skill is missing approval evidence."
    }
    else {
        $evalsText = Read-Utf8Text $evalsFile
        $actualEvalsHash = "SHA256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $evalsFile).Hash)"
        Test-ExpectedHashField $actualEvalsHash $ExpectedEvalsSha256 "Evals SHA256"
        $evalStatus = Get-MarkdownField -Text $evalsText -Label "Status"
        $approvedBy = Get-MarkdownField -Text $evalsText -Label "Approved by"
        $candidateHash = Get-FirstMarkdownField -Text $evalsText -Labels @("Candidate SHA256", "Candidate hash")
        $approvalReference = Get-MarkdownField -Text $evalsText -Label "Approval reference"
        $destination = Get-MarkdownField -Text $evalsText -Label "Destination"
        $rollbackPath = Get-MarkdownField -Text $evalsText -Label "Rollback path"
        if ($evalStatus -ne "APPROVED") {
            Add-ValidationError "Active skill EVALS.md must have APPROVED status, found: $evalStatus"
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedLifecycleStatus) -and $ExpectedLifecycleStatus -ne "ENABLED") {
            Add-ValidationError "Active skill requires registry lifecycle ENABLED; found: $ExpectedLifecycleStatus"
        }
        if ($evalsText -match 'REPLACE_ME|replace-with-skill-name') {
            Add-ValidationError "Active skill EVALS.md contains placeholders."
        }
        if ([string]::IsNullOrWhiteSpace($approvedBy) -or $approvedBy -in @("NONE", "UNKNOWN")) {
            Add-ValidationError "Active skill must record Approved by."
        }
        if ([string]::IsNullOrWhiteSpace($approvalReference) -or $approvalReference -in @("NONE", "UNKNOWN")) { Add-ValidationError "Active skill must record Approval reference." }
        if ([string]::IsNullOrWhiteSpace($candidateHash) -or $candidateHash -in @("NONE", "UNKNOWN")) {
            Add-ValidationError "Active skill must record Candidate hash."
        }
        else { Test-StrictSha $candidateHash "Candidate SHA256" }
        if ([string]::IsNullOrWhiteSpace($rollbackPath) -or $rollbackPath -in @("NONE", "UNKNOWN")) {
            Add-ValidationError "Active skill must record Rollback path."
        }
        else {
            $resolvedRollbackPath = Resolve-ContainedExistingPath -Root $validationProjectRoot -RelativePath $rollbackPath -ExpectedRoot ".agent/skill-candidates" -Label "Rollback path"
            if ($managedActiveEvidence -and $null -ne $resolvedRollbackPath -and $null -ne $managedCandidateFullPath -and -not (Test-SamePath $resolvedRollbackPath $managedCandidateFullPath)) {
                Add-ValidationError "Managed active skill Rollback path must identify the candidate directory that owns ApprovalEvalsPath."
            }
        }
        if ($null -ne $expectedDestination -and $destination -ne $expectedDestination) {
            Add-ValidationError "Active skill Destination must match its discovery name: $expectedDestination"
        }
        elseif ($null -ne $expectedDestination -and -not [string]::IsNullOrWhiteSpace($validationProjectRoot)) {
            $expectedSkillPath = [System.IO.Path]::GetFullPath((Join-Path $validationProjectRoot $expectedDestination))
            if (-not $skillFullPath.Equals($expectedSkillPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-ValidationError "Active SkillPath must match the approved Destination: $expectedDestination"
            }
        }
        $createdByRun = Get-MarkdownField -Text $evalsText -Label "Created by run"
        $evaluatedBy = Get-MarkdownField -Text $evalsText -Label "Evaluated by"
        $evaluatorRun = Get-MarkdownField -Text $evalsText -Label "Evaluator run"
        $lastRun = Get-MarkdownField -Text $evalsText -Label "Last run"
        $evaluationArtifact = Get-MarkdownField -Text $evalsText -Label "Evaluation artifact"
        $evaluationHash = Get-MarkdownField -Text $evalsText -Label "Evaluation SHA256"
        if ([string]::IsNullOrWhiteSpace($createdByRun) -or $createdByRun -in @("NONE", "UNKNOWN")) { Add-ValidationError "Active skill requires creator provenance." }
        if ([string]::IsNullOrWhiteSpace($lastRun) -or $lastRun -in @("NOT_RUN", "NONE", "UNKNOWN")) { Add-ValidationError "Active skill requires a completed Last run." }
        if ([string]::IsNullOrWhiteSpace($evaluatedBy) -or $evaluatedBy -in @("NONE", "UNKNOWN") -or [string]::IsNullOrWhiteSpace($evaluatorRun) -or $evaluatorRun -in @("NONE", "UNKNOWN")) { Add-ValidationError "Active skill requires evaluator provenance." }
        if ($evaluatorRun -eq $createdByRun) { Add-ValidationError "Evaluator run must differ from creator run." }
        Test-EvaluationSections -Text $evalsText -Headings @("## Positive triggers", "## Negative triggers", "## Workflow verification")
        Test-EvaluationArtifact -Root $validationProjectRoot -RelativePath $evaluationArtifact -ExpectedHash $evaluationHash -EvaluatedBy $evaluatedBy -EvaluatorRun $evaluatorRun -ExpectedCandidateHash $candidateHash
        if ($strictContract) {
            $registryId = Get-MarkdownField -Text $evalsText -Label "Registry ID"
            $providerId = Get-MarkdownField -Text $evalsText -Label "Provider ID"
            $capabilityKey = Get-MarkdownField -Text $evalsText -Label "Capability key"
            $evalSkillName = Get-MarkdownField -Text $evalsText -Label "Skill name"
            $expectedActiveHash = Get-MarkdownField -Text $evalsText -Label "Expected active SHA256"
            Test-ExpectedField $registryId $ExpectedRegistryId "Registry ID"
            Test-ExpectedField $providerId $ExpectedProviderId "Provider ID"
            Test-ExpectedField $capabilityKey $ExpectedCapabilityKey "Capability key"
            Test-ExpectedField $evalSkillName $ExpectedName "Evals Skill name"
            Test-ExpectedField $skillName $ExpectedName "SKILL.md name"
            Test-ExpectedHashField $candidateHash $ExpectedCandidateSha256 "Approved Candidate SHA256"
            Test-ExpectedHashField $actualPayloadHash $ExpectedActiveSha256 "Active payload SHA256"
            Test-ExpectedField $approvedBy $ExpectedApprovedBy "Approved by"
            Test-ExpectedField $approvalReference $ExpectedApprovalReference "Approval reference"
            Test-ExpectedField $rollbackPath $ExpectedRollbackPath "Rollback path"
            Test-StrictSha $candidateHash "Candidate SHA256"
            Test-StrictSha $expectedActiveHash "Expected active SHA256"
            if ($candidateHash -match '^SHA256:' -and -not (Test-HashEqual $candidateHash $actualPayloadHash)) { Add-ValidationError "Active payload does not match approved Candidate SHA256." }
            if ($expectedActiveHash -match '^SHA256:' -and -not (Test-HashEqual $expectedActiveHash $actualPayloadHash)) { Add-ValidationError "Active payload does not match Expected active SHA256." }
        }
    }
}

if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Skill validation failed ($Mode):$([Environment]::NewLine)$details"
}

Write-Host "Skill validation passed." -ForegroundColor Green
Write-Host "Mode: $Mode"
Write-Host "Skill path: $skillFullPath"
Write-Host "Payload SHA256: $actualPayloadHash"
