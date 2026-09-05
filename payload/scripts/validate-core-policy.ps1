param(
    [Parameter(Mandatory = $true)]
    [string]$CorePath,
    [string]$ReferenceRoot,
    [string]$ExpectedVersion = "0.10.0",
    [int]$WarningBytes = 26624,
    [int]$HardBytes = 28672,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$errors = [System.Collections.Generic.List[string]]::new()

function Add-CoreError {
    param([string]$Code, [string]$Message)
    $errors.Add("$Code`: $Message")
}

if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
    throw "AZ-CORE-MISSING: Core policy does not exist: $CorePath"
}

$coreText = Get-Content -Raw -LiteralPath $CorePath
$coreBytes = (Get-Item -LiteralPath $CorePath).Length
if ($coreBytes -gt $HardBytes) {
    Add-CoreError "AZ-CORE-QUOTA" "Core is $coreBytes bytes; hard limit is $HardBytes"
}
elseif ($coreBytes -ge $WarningBytes -and -not $Quiet) {
    Write-Warning "AZ-CORE-QUOTA-WARN: Core is $coreBytes / $HardBytes bytes; target is below $WarningBytes"
}

$requiredMarkers = @(
    ("# Agent Zero v{0}" -f $ExpectedVersion),
    '## Stable core contract',
    'operating contract',
    'project context, lesson, convention',
    '## ADOPTION',
    '## BOOTSTRAP',
    '## Adaptive goal governance',
    '## ACTIVE',
    '## Meta-review',
    '## RECALIBRATION',
    '## Project memory',
    '## Learning loop',
    '## Skill lifecycle',
    '## Core update',
    '## Definition of done',
    'FACT',
    'USER_DECISION',
    'ASSUMPTION',
    'UNKNOWN',
    'CUTOVER -> VERIFYING -> AWAITING_USER_ACCEPTANCE -> VERIFIED',
    'Acceptance request: SENT',
    'HYPOTHESIS -> PROPOSED -> ACCEPTED -> SUPERSEDED',
    'ALIGNED|AT_RISK|OFF_GOAL|NEEDS_USER_DECISION|NOT_ASSESSED',
    'MAINTENANCE|INCIDENT',
    'UNDERSTAND',
    'DEFINE_DONE',
    'CHECKPOINT',
    'IMPLEMENT',
    'VERIFY',
    'REVIEW',
    'REPAIR',
    'LEARN',
    'SYNC',
    'REPORT',
    'governance fitness',
    'SELF_IMPROVEMENT_PROPOSAL',
    'PROJECT_SPECIFIC|FRAMEWORK_CORE',
    'SAFETY_INVARIANT|USER_BOUNDARY|PROCEDURAL_DEFAULT|CAPABILITY_ASSUMPTION',
    'FRICTION -> DIAGNOSED -> PROPOSED -> ACCEPTED|REJECTED -> IMPLEMENTED -> BEHAVIORALLY_VERIFIED',
    'IncludeProposed',
    'HARD_INVARIANT|REQUIRED_OUTCOME|PROCEDURAL_DEFAULT|CAPABILITY_ASSUMPTION',
    'TRIVIAL|STANDARD|HIGH_RISK|GOVERNANCE',
    'UNDERSTAND -> DIRECT_REPORT -> COMPLETE',
    'VERIFY_FAIL -> REPAIR -> VERIFY',
    'COMPLETE|BLOCKED|AWAITING_USER_DECISION',
    'new user input or external evidence',
    'repair<=2|review<=2|meta-review<=1|proposal<=1|memory-transaction<=1',
    'NO_DURABLE_LEARNING',
    'NO_MEMORY_DELTA',
    'internal phase',
    'fingerprint',
    'stage -> validate -> apply',
    'CANDIDATE -> VERIFIED -> ENFORCED -> RETIRED',
    'OBSERVED -> PROPOSED -> DRAFT -> EVALUATED -> APPROVED -> ENABLED -> RETIRED',
    '.agent/LESSONS.md',
    '.agent/lessons/',
    'Project learning',
    'append',
    'Project lesson',
    'Typo',
    'positive trigger cases',
    'negative trigger cases',
    'sub-agent',
    'write ownership',
    'integration check',
    'repair count',
    'explicit user approval',
    'source/dist hash checks'
)

foreach ($marker in $requiredMarkers) {
    if (-not $coreText.Contains($marker)) {
        Add-CoreError "AZ-CORE-INVARIANT" "Core is missing invariant marker: $marker"
    }
}

$forbiddenPatterns = @(
    @{ Pattern = '(?i)project lesson.{0,100}(append|promote).{0,100}AGENTS\.md'; Code = "AZ-CORE-LEARNING-BOUNDARY"; Reason = "project learning must not grow the core" },
    @{ Pattern = '(?i)lesson.{0,100}(automatic|auto).{0,100}(update|append|promote).{0,100}AGENTS\.md'; Code = "AZ-CORE-LEARNING-BOUNDARY"; Reason = "automatic lesson promotion to core is forbidden" },
    @{ Pattern = '(?i)(may|is allowed to).{0,80}automatically.{0,40}(update|mutate).{0,30}(AGENTS\.md|core)'; Code = "AZ-CORE-SELF-UPDATE-BOUNDARY"; Reason = "a self-improvement proposal must not authorize its own core mutation" },
    @{ Pattern = '(?i)META_REVIEW.{0,60}(may|can).{0,60}(call|invoke).{0,60}META_REVIEW'; Code = "AZ-CORE-LOOP-RECURSION"; Reason = "meta-review must not recursively invoke itself" },
    @{ Pattern = '(?i)PROCEDURAL_DEFAULT.{0,60}(may|can).{0,60}(override|weaken).{0,60}HARD_INVARIANT'; Code = "AZ-CORE-HARD-INVARIANT"; Reason = "a procedural default must not override a hard invariant" }
)

foreach ($item in $forbiddenPatterns) {
    if ([regex]::IsMatch($coreText, $item.Pattern)) {
        Add-CoreError $item.Code $item.Reason
    }
}

if (-not [string]::IsNullOrWhiteSpace($ReferenceRoot) -and
    -not (Test-Path -LiteralPath $ReferenceRoot -PathType Container)) {
    Add-CoreError "AZ-CORE-SUPPORT-REFERENCE-ROOT" "Optional supporting reference root does not exist: $ReferenceRoot"
}

if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Agent Zero core policy validation failed:$([Environment]::NewLine)$details"
}

if (-not $Quiet) {
    Write-Host "Agent Zero stable core policy validation passed." -ForegroundColor Green
    Write-Host "Core size: $coreBytes / $HardBytes bytes"
    Write-Host "Critical invariants: $($requiredMarkers.Count)"
}

[pscustomobject]@{
    CoreBytes = $coreBytes
    HardBytes = $HardBytes
    CriticalInvariants = $requiredMarkers.Count
    CoreMode = "STABLE_MONOLITHIC"
}
