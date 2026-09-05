param(
    [Parameter(Mandatory = $true)]
    [string]$SkillPath,

    [ValidateSet("Candidate", "Active")]
    [string]$Mode = "Candidate"
)

$ErrorActionPreference = "Stop"

$skillFullPath = [System.IO.Path]::GetFullPath($SkillPath)
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError {
    param([string]$Message)
    $errors.Add($Message)
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

if (-not (Test-Path -LiteralPath $skillFullPath -PathType Container)) {
    throw "Skill validation failed: directory does not exist: $skillFullPath"
}

$skillFile = Join-Path $skillFullPath "SKILL.md"
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    Add-ValidationError "Missing SKILL.md: $skillFile"
}
else {
    $skillText = Get-Content -Raw -LiteralPath $skillFile
    $frontmatterMatch = [regex]::Match($skillText, '(?s)\A---\s*\r?\n(?<frontmatter>.*?)\r?\n---\s*\r?\n')
    if (-not $frontmatterMatch.Success) {
        Add-ValidationError "SKILL.md must begin with YAML frontmatter delimited by --- lines."
    }
    else {
        $frontmatter = $frontmatterMatch.Groups["frontmatter"].Value
        $nameMatch = [regex]::Match($frontmatter, '(?m)^name:\s*(?<value>.+?)\s*$')
        $descriptionMatch = [regex]::Match($frontmatter, '(?m)^description:\s*(?<value>.+?)\s*$')

        if (-not $nameMatch.Success) {
            Add-ValidationError "SKILL.md frontmatter is missing name."
        }
        else {
            $skillName = $nameMatch.Groups["value"].Value.Trim().Trim('"').Trim("'")
            if ($skillName.Length -gt 64 -or $skillName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                Add-ValidationError "Skill name must be 1-64 lowercase letters/digits with single hyphen separators: $skillName"
            }
        }

        if (-not $descriptionMatch.Success) {
            Add-ValidationError "SKILL.md frontmatter is missing description."
        }
        else {
            $description = $descriptionMatch.Groups["value"].Value.Trim().Trim('"').Trim("'")
            if ($description.Length -lt 20) {
                Add-ValidationError "Skill description is too short to define a reliable trigger boundary."
            }
            if ($description -notmatch '(?i)\buse when\b|\bdùng khi\b') {
                Add-ValidationError "Skill description must state when to use the skill."
            }
            if ($description -notmatch '(?i)\bdo not use\b|\bkhông dùng\b') {
                Add-ValidationError "Skill description must state when not to use the skill."
            }
        }
    }

    if ($skillText -match 'REPLACE_ME|replace-with-skill-name') {
        Add-ValidationError "SKILL.md still contains template placeholders."
    }
}

$evalsFile = Join-Path $skillFullPath "EVALS.md"
if ($Mode -eq "Candidate") {
    if (-not (Test-Path -LiteralPath $evalsFile -PathType Leaf)) {
        Add-ValidationError "Candidate skill is missing EVALS.md."
    }
    else {
        $evalsText = Get-Content -Raw -LiteralPath $evalsFile
        $evalStatus = Get-MarkdownField -Text $evalsText -Label "Status"
        if ($evalStatus -notin @("DRAFT", "EVALUATED", "APPROVED")) {
            Add-ValidationError "EVALS.md Status must be DRAFT, EVALUATED, or APPROVED."
        }

        foreach ($heading in @("## Positive triggers", "## Negative triggers", "## Workflow verification", "## Promotion record")) {
            if (-not $evalsText.Contains($heading)) {
                Add-ValidationError "EVALS.md is missing heading: $heading"
            }
        }

        if ($evalsText -match 'REPLACE_ME|replace-with-skill-name') {
            Add-ValidationError "EVALS.md still contains template placeholders."
        }

        if ($evalStatus -in @("EVALUATED", "APPROVED") -and $evalsText -match '`NOT_RUN`') {
            Add-ValidationError "$evalStatus candidate cannot contain NOT_RUN eval results."
        }

        if ($evalStatus -eq "APPROVED") {
            $approvedBy = Get-MarkdownField -Text $evalsText -Label "Approved by"
            $candidateHash = Get-MarkdownField -Text $evalsText -Label "Candidate hash"
            $rollbackPath = Get-MarkdownField -Text $evalsText -Label "Rollback path"
            if ([string]::IsNullOrWhiteSpace($approvedBy) -or $approvedBy -eq "NONE") {
                Add-ValidationError "APPROVED candidate must record Approved by."
            }
            if ([string]::IsNullOrWhiteSpace($candidateHash) -or $candidateHash -eq "UNKNOWN") {
                Add-ValidationError "APPROVED candidate must record Candidate hash."
            }
            if ([string]::IsNullOrWhiteSpace($rollbackPath) -or $rollbackPath -eq "UNKNOWN") {
                Add-ValidationError "APPROVED candidate must record Rollback path."
            }
        }
    }
}
else {
    if (-not (Test-Path -LiteralPath $evalsFile -PathType Leaf)) {
        Add-ValidationError "Active Agent Zero skill is missing approval evidence in EVALS.md."
    }
    else {
        $evalsText = Get-Content -Raw -LiteralPath $evalsFile
        $evalStatus = Get-MarkdownField -Text $evalsText -Label "Status"
        $approvedBy = Get-MarkdownField -Text $evalsText -Label "Approved by"
        $candidateHash = Get-MarkdownField -Text $evalsText -Label "Candidate hash"
        $rollbackPath = Get-MarkdownField -Text $evalsText -Label "Rollback path"
        if ($evalStatus -ne "APPROVED") {
            Add-ValidationError "Active skill EVALS.md must have APPROVED status, found: $evalStatus"
        }
        if ($evalsText -match '`NOT_RUN`|REPLACE_ME|replace-with-skill-name') {
            Add-ValidationError "Active skill EVALS.md contains incomplete evals or placeholders."
        }
        if ([string]::IsNullOrWhiteSpace($approvedBy) -or $approvedBy -eq "NONE") {
            Add-ValidationError "Active skill must record Approved by."
        }
        if ([string]::IsNullOrWhiteSpace($candidateHash) -or $candidateHash -eq "UNKNOWN") {
            Add-ValidationError "Active skill must record Candidate hash."
        }
        if ([string]::IsNullOrWhiteSpace($rollbackPath) -or $rollbackPath -eq "UNKNOWN") {
            Add-ValidationError "Active skill must record Rollback path."
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
