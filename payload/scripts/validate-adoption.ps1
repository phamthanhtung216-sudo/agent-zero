param(
    [Parameter(Mandatory = $true)]
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "Adoption report does not exist: $ReportPath"
}

$reportText = Get-Content -Raw -LiteralPath $ReportPath
$errors = [System.Collections.Generic.List[string]]::new()

function Get-AdoptionField {
    param(
        [string]$Name,
        [bool]$Required = $true
    )

    $pattern = '(?m)^-[ \t]+' + [regex]::Escape($Name) + ':[ \t]+`(?<value>[^`\r\n]+)`[ \t]*\r?$'
    $matches = [regex]::Matches($reportText, $pattern)
    if ($matches.Count -eq 0) {
        if ($Required) {
            $errors.Add("AZ-ADOPTION-FIELD: missing field: $Name")
        }
        return $null
    }
    if ($matches.Count -gt 1) {
        $errors.Add("AZ-ADOPTION-FIELD: duplicate field: $Name")
    }
    return $matches[0].Groups["value"].Value.Trim()
}

function Test-SubstantiveValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return $Value -notin @("NONE", "UNKNOWN", "NOT_PREPARED", "NOT_RUN", "NOT_SENT")
}

foreach ($heading in @(
    "# Agent Zero Adoption Report",
    "## Repository baseline",
    "## Existing context inventory",
    "## Goal reconstruction",
    "## Post-adoption opportunity candidates",
    "## Conflicts requiring authority",
    "## Snapshot and rollback manifest",
    "## Verification plan",
    "## Verification and final acceptance",
    "### Readiness report",
    "## Adoption log"
)) {
    if (-not $reportText.Contains($heading)) {
        $errors.Add("AZ-ADOPTION-STRUCTURE: missing heading: $heading")
    }
}

$requiredFlow = "DETECTED -> AUDITED -> PLAN_APPROVED -> CUTOVER -> VERIFYING -> AWAITING_USER_ACCEPTANCE -> VERIFIED"
if (-not $reportText.Contains($requiredFlow)) {
    $errors.Add("AZ-ADOPTION-LIFECYCLE: required status flow is missing or out of order")
}

$status = Get-AdoptionField -Name "Status"
$migrationApprovedBy = Get-AdoptionField -Name "Migration approved by"
$technicalVerification = Get-AdoptionField -Name "Technical verification"
$verificationEvidence = Get-AdoptionField -Name "Verification evidence"
$acceptanceRequest = Get-AdoptionField -Name "Acceptance request"
$acceptanceRequestedAt = Get-AdoptionField -Name "Acceptance requested at"
$acceptanceRequestEvidence = Get-AdoptionField -Name "Acceptance request evidence"
$finalAcceptance = Get-AdoptionField -Name "Final acceptance"
$acceptedBy = Get-AdoptionField -Name "Accepted by"
$acceptedAt = Get-AdoptionField -Name "Accepted at"
$acceptanceEvidence = Get-AdoptionField -Name "Acceptance evidence"
$rollbackResult = Get-AdoptionField -Name "Rollback result"
$rollbackEvidence = Get-AdoptionField -Name "Rollback evidence"
$migrationSummary = Get-AdoptionField -Name "Migration summary"
$checksSummary = Get-AdoptionField -Name "Checks summary"
$remainingRisks = Get-AdoptionField -Name "Remaining risks"
$rollbackReference = Get-AdoptionField -Name "Rollback reference"
$decisionRequested = Get-AdoptionField -Name "Decision requested"
$acceptanceOwner = Get-AdoptionField -Name "Acceptance owner"
$historicalGoal = Get-AdoptionField -Name "Historical goal"
$historicalGoalSource = Get-AdoptionField -Name "Historical goal source/owner"
$currentObservedOutcome = Get-AdoptionField -Name "Current observed outcome"
$currentDirectionConfidence = Get-AdoptionField -Name "Current direction confidence"
$futureDirection = Get-AdoptionField -Name "Future direction"
$goalConfirmationOwner = Get-AdoptionField -Name "Confirmation needed from"

$allowedStatuses = @(
    "DETECTED",
    "AUDITED",
    "PLAN_APPROVED",
    "CUTOVER",
    "VERIFYING",
    "AWAITING_USER_ACCEPTANCE",
    "VERIFIED",
    "ROLLED_BACK"
)
if ($null -ne $status -and $status -notin $allowedStatuses) {
    $errors.Add("AZ-ADOPTION-STATUS: invalid Status: $status")
}
if ($null -ne $technicalVerification -and $technicalVerification -notin @("NOT_RUN", "IN_PROGRESS", "PASS", "FAIL")) {
    $errors.Add("AZ-ADOPTION-VERIFY: invalid Technical verification: $technicalVerification")
}
if ($null -ne $acceptanceRequest -and $acceptanceRequest -notin @("NOT_SENT", "SENT")) {
    $errors.Add("AZ-ADOPTION-ACCEPTANCE: invalid Acceptance request: $acceptanceRequest")
}
if ($null -ne $finalAcceptance -and $finalAcceptance -notin @("PENDING", "ACCEPTED", "REJECTED")) {
    $errors.Add("AZ-ADOPTION-ACCEPTANCE: invalid Final acceptance: $finalAcceptance")
}
if ($null -ne $rollbackResult -and $rollbackResult -notin @("NOT_RUN", "IN_PROGRESS", "PASS", "FAIL")) {
    $errors.Add("AZ-ADOPTION-ROLLBACK: invalid Rollback result: $rollbackResult")
}

if ($status -in @("AUDITED", "PLAN_APPROVED", "CUTOVER", "VERIFYING", "AWAITING_USER_ACCEPTANCE", "VERIFIED", "ROLLED_BACK")) {
    foreach ($goalField in @(
        @{ Name = "Historical goal"; Value = $historicalGoal },
        @{ Name = "Historical goal source/owner"; Value = $historicalGoalSource },
        @{ Name = "Current observed outcome"; Value = $currentObservedOutcome },
        @{ Name = "Current direction confidence"; Value = $currentDirectionConfidence },
        @{ Name = "Future direction"; Value = $futureDirection },
        @{ Name = "Confirmation needed from"; Value = $goalConfirmationOwner }
    )) {
        if (-not (Test-SubstantiveValue -Value $goalField.Value) -or
            $goalField.Value -in @("UNKNOWN_OR_HYPOTHESIS", "USER_OR_OWNER")) {
            $errors.Add("AZ-ADOPTION-GOAL: Status $status requires audited $($goalField.Name)")
        }
    }
}

if ($status -in @("PLAN_APPROVED", "CUTOVER", "VERIFYING", "AWAITING_USER_ACCEPTANCE", "VERIFIED", "ROLLED_BACK") -and
    -not (Test-SubstantiveValue -Value $migrationApprovedBy)) {
    $errors.Add("AZ-ADOPTION-APPROVAL: Status $status requires Migration approved by")
}

if ($status -in @("AWAITING_USER_ACCEPTANCE", "VERIFIED")) {
    if ($technicalVerification -ne "PASS") {
        $errors.Add("AZ-ADOPTION-VERIFY: Status $status requires Technical verification PASS")
    }
    if (-not (Test-SubstantiveValue -Value $verificationEvidence)) {
        $errors.Add("AZ-ADOPTION-EVIDENCE: Status $status requires Verification evidence")
    }
    if ($acceptanceRequest -ne "SENT") {
        $errors.Add("AZ-ADOPTION-NOTIFY: Status $status requires Acceptance request SENT")
    }
    if (-not (Test-SubstantiveValue -Value $acceptanceRequestedAt)) {
        $errors.Add("AZ-ADOPTION-NOTIFY: Status $status requires Acceptance requested at")
    }
    if (-not (Test-SubstantiveValue -Value $acceptanceRequestEvidence)) {
        $errors.Add("AZ-ADOPTION-NOTIFY: Status $status requires Acceptance request evidence")
    }
    if (-not (Test-SubstantiveValue -Value $acceptanceOwner)) {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: Status $status requires Acceptance owner")
    }
    foreach ($readinessField in @(
        @{ Name = "Migration summary"; Value = $migrationSummary },
        @{ Name = "Checks summary"; Value = $checksSummary },
        @{ Name = "Remaining risks"; Value = $remainingRisks },
        @{ Name = "Rollback reference"; Value = $rollbackReference },
        @{ Name = "Decision requested"; Value = $decisionRequested }
    )) {
        if (-not (Test-SubstantiveValue -Value $readinessField.Value)) {
            $errors.Add("AZ-ADOPTION-READINESS: Status $status requires $($readinessField.Name)")
        }
    }
}

if ($status -eq "AWAITING_USER_ACCEPTANCE" -and $finalAcceptance -ne "PENDING") {
    $errors.Add("AZ-ADOPTION-ACCEPTANCE: AWAITING_USER_ACCEPTANCE requires Final acceptance PENDING")
}

if ($status -eq "VERIFIED") {
    if ($finalAcceptance -ne "ACCEPTED") {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: VERIFIED requires Final acceptance ACCEPTED")
    }
    if (-not (Test-SubstantiveValue -Value $acceptedBy)) {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: VERIFIED requires Accepted by")
    }
    if (-not (Test-SubstantiveValue -Value $acceptedAt)) {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: VERIFIED requires Accepted at")
    }
    if (-not (Test-SubstantiveValue -Value $acceptanceEvidence)) {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: VERIFIED requires Acceptance evidence")
    }
    if ((Test-SubstantiveValue -Value $acceptanceOwner) -and $acceptedBy -ne $acceptanceOwner) {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: Accepted by must match Acceptance owner")
    }
}
elseif ($finalAcceptance -eq "ACCEPTED") {
    $errors.Add("AZ-ADOPTION-ACCEPTANCE: Final acceptance ACCEPTED requires Status VERIFIED")
}

if ($status -eq "ROLLED_BACK") {
    if ($finalAcceptance -eq "ACCEPTED") {
        $errors.Add("AZ-ADOPTION-ACCEPTANCE: ROLLED_BACK cannot retain Final acceptance ACCEPTED")
    }
    if ($rollbackResult -ne "PASS") {
        $errors.Add("AZ-ADOPTION-ROLLBACK: ROLLED_BACK requires Rollback result PASS")
    }
    if (-not (Test-SubstantiveValue -Value $rollbackEvidence)) {
        $errors.Add("AZ-ADOPTION-ROLLBACK: ROLLED_BACK requires Rollback evidence")
    }
}

$transitionPattern = '(?m)^\|[ \t]+`(?<from>[A-Z_]+)`[ \t]+\|[ \t]+`(?<to>[A-Z_]+)`[ \t]+\|[ \t]+`(?<at>[^`\r\n]+)`[ \t]+\|[ \t]+`(?<evidence>[^`\r\n]+)`[ \t]+\|[ \t]*\r?$'
$transitionMatches = [regex]::Matches($reportText, $transitionPattern)
if ($transitionMatches.Count -eq 0) {
    $errors.Add("AZ-ADOPTION-TRANSITION: adoption log must contain transition rows")
}
else {
    $allowedEdges = @{
        "NONE->DETECTED" = $true
        "DETECTED->AUDITED" = $true
        "AUDITED->PLAN_APPROVED" = $true
        "PLAN_APPROVED->CUTOVER" = $true
        "CUTOVER->VERIFYING" = $true
        "CUTOVER->ROLLED_BACK" = $true
        "VERIFYING->AWAITING_USER_ACCEPTANCE" = $true
        "VERIFYING->ROLLED_BACK" = $true
        "AWAITING_USER_ACCEPTANCE->VERIFYING" = $true
        "AWAITING_USER_ACCEPTANCE->VERIFIED" = $true
        "AWAITING_USER_ACCEPTANCE->ROLLED_BACK" = $true
    }
    $previousTo = $null
    for ($index = 0; $index -lt $transitionMatches.Count; $index++) {
        $from = $transitionMatches[$index].Groups["from"].Value
        $to = $transitionMatches[$index].Groups["to"].Value
        $at = $transitionMatches[$index].Groups["at"].Value.Trim()
        $transitionEvidence = $transitionMatches[$index].Groups["evidence"].Value.Trim()
        $edge = "$from->$to"

        if (-not $allowedEdges.ContainsKey($edge)) {
            $errors.Add("AZ-ADOPTION-TRANSITION: invalid transition edge: $edge")
        }
        if ($index -gt 0 -and $from -ne $previousTo) {
            $errors.Add("AZ-ADOPTION-TRANSITION: transition chain is discontinuous at $edge")
        }
        if ($index -gt 0 -and -not (Test-SubstantiveValue -Value $at)) {
            $errors.Add("AZ-ADOPTION-TRANSITION: transition $edge requires At")
        }
        if (-not (Test-SubstantiveValue -Value $transitionEvidence)) {
            $errors.Add("AZ-ADOPTION-TRANSITION: transition $edge requires Evidence")
        }
        $previousTo = $to
    }
    if ($transitionMatches[0].Groups["from"].Value -ne "NONE" -or
        $transitionMatches[0].Groups["to"].Value -ne "DETECTED") {
        $errors.Add("AZ-ADOPTION-TRANSITION: transition chain must begin NONE->DETECTED")
    }
    if ($null -ne $status -and $previousTo -ne $status) {
        $errors.Add("AZ-ADOPTION-TRANSITION: final transition status $previousTo does not match Status $status")
    }
}

if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Adoption validation failed:$([Environment]::NewLine)$details"
}

Write-Host "Agent Zero adoption validation passed." -ForegroundColor Green
Write-Host "Status: $status"
Write-Host "Report: $([System.IO.Path]::GetFullPath($ReportPath))"
