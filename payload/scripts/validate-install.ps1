param(
    [ValidateSet("Auto", "NewProject", "ExistingProject", "UpgradeActive", "UpgradeCandidate")]
    [string]$Mode = "Auto"
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentZeroRoot = Split-Path -Parent $scriptRoot
$projectRoot = Split-Path -Parent $agentZeroRoot

$newAgentsPath = Join-Path $projectRoot "AGENTS.md"
$candidatePath = Join-Path $projectRoot "AGENT_ZERO_CANDIDATE.md"

if ($Mode -eq "Auto") {
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $Mode = "ExistingProject"
    }
    elseif (Test-Path -LiteralPath $newAgentsPath -PathType Leaf) {
        $Mode = "NewProject"
    }
    else {
        throw "Cannot detect kit mode: neither AGENTS.md nor AGENT_ZERO_CANDIDATE.md exists."
    }
}

$errors = [System.Collections.Generic.List[string]]::new()

$commonFiles = @(
    ".agent-zero/VERSION",
    ".agent-zero/TESTING.md",
    ".agent-zero/START.md",
    ".agent-zero/NEXT_STEPS.md",
    ".agent-zero/references/ADOPTION_PROTOCOL.md",
    ".agent-zero/references/BOOTSTRAP_PROTOCOL.md",
    ".agent-zero/references/GOAL_GOVERNANCE.md",
    ".agent-zero/references/EXECUTION_PROTOCOL.md",
    ".agent-zero/references/MEMORY_PROTOCOL.md",
    ".agent-zero/references/CAPABILITY_POLICY.md",
    ".agent-zero/references/SUBAGENT_POLICY.md",
    ".agent-zero/references/SKILL_POLICY.md",
    ".agent-zero/templates/ADOPTION.md",
    ".agent-zero/templates/PROJECT.md",
    ".agent-zero/templates/STATE.md",
    ".agent-zero/templates/CONTEXT_INDEX.md",
    ".agent-zero/templates/DECISIONS.md",
    ".agent-zero/templates/DECISION.md",
    ".agent-zero/templates/LESSONS.md",
    ".agent-zero/templates/LESSON.md",
    ".agent-zero/templates/CAPABILITIES.md",
    ".agent-zero/templates/SKILLS.md",
    ".agent-zero/templates/SKILL.md",
    ".agent-zero/templates/SKILL_EVALS.md",
    ".agent-zero/templates/SUBAGENTS.md",
    ".agent-zero/templates/SUBAGENT.toml",
    ".agent-zero/templates/SUBAGENT_EVALS.md",
    ".agent-zero/templates/CHANGELOG.md",
    ".agent-zero/templates/archive/LESSONS_INDEX.md",
    ".agent-zero/templates/archive/DECISIONS_INDEX.md",
    ".agent-zero/scripts/validate-adoption.ps1",
    ".agent-zero/scripts/validate-core-policy.ps1",
    ".agent-zero/scripts/validate-memory.ps1",
    ".agent-zero/scripts/validate-skill.ps1",
    ".agent-zero/scripts/validate-subagent.ps1",
    ".agent-zero/scripts/validate-capabilities.ps1",
    ".agent-zero/scripts/resolve-capabilities.ps1",
    ".agent-zero/scripts/select-context.ps1"
)

$modeFiles = if ($Mode -eq "NewProject") {
    @(
        "AGENTS.md",
        "CLAUDE.md",
        ".agent/PROJECT.md",
        ".agent/STATE.md",
        ".agent/CONTEXT_INDEX.md",
        ".agent/DECISIONS.md",
        ".agent/LESSONS.md",
        ".agent/CAPABILITIES.md",
        ".agent/SKILLS.md",
        ".agent/SUBAGENTS.md",
        ".agent/CHANGELOG.md",
        ".agent/archive/LESSONS_INDEX.md",
        ".agent/archive/DECISIONS_INDEX.md"
    )
}
elseif ($Mode -in @("ExistingProject", "UpgradeCandidate")) {
    @(
        "AGENT_ZERO_CANDIDATE.md",
        ".agent-zero/adoption/ADOPTION.md"
    )
}
else {
    @("AGENTS.md")
}
if ($Mode -in @("UpgradeActive", "UpgradeCandidate")) {
    $modeFiles = @($modeFiles) + @(".agent-zero/UPGRADE_RESULT.md")
}

foreach ($relativePath in @($commonFiles + $modeFiles)) {
    $fullPath = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $errors.Add("Missing required file: $relativePath")
    }
}

$installedVersionPath = Join-Path $projectRoot ".agent-zero/VERSION"
if (Test-Path -LiteralPath $installedVersionPath -PathType Leaf) {
    $installedVersion = (Get-Content -Raw -LiteralPath $installedVersionPath).Trim()
    if ($installedVersion -ne "0.11.1") { $errors.Add("Installed VERSION must be 0.11.1, found: $installedVersion") }
}

$startPath = Join-Path $projectRoot ".agent-zero/START.md"
if (Test-Path -LiteralPath $startPath -PathType Leaf) {
    $startText = Get-Content -Raw -LiteralPath $startPath
    foreach ($marker in @("AGENT_ZERO_CANDIDATE.md", "ADOPTION", "shadow", "AGENTS.md", "BOOTSTRAP", "VERIFIED", "mục tiêu lịch sử", "hướng tương lai")) {
        if (-not $startText.Contains($marker)) {
            $errors.Add("Installed START.md is missing activation marker: $marker")
        }
    }
}

$nextStepsPath = Join-Path $projectRoot ".agent-zero/NEXT_STEPS.md"
if (Test-Path -LiteralPath $nextStepsPath -PathType Leaf) {
    $nextStepsText = Get-Content -Raw -LiteralPath $nextStepsPath
    foreach ($marker in @("CAI DAT THANH CONG", "Khoi dong Agent Zero theo .agent-zero/START.md", "Auto-detect")) {
        if (-not $nextStepsText.Contains($marker)) {
            $errors.Add("Installed NEXT_STEPS.md is missing guidance marker: $marker")
        }
    }
}

if ($Mode -in @("UpgradeActive", "UpgradeCandidate")) {
    $upgradeResultPath = Join-Path $projectRoot ".agent-zero/UPGRADE_RESULT.md"
    if (Test-Path -LiteralPath $upgradeResultPath -PathType Leaf) {
        $upgradeResultText = Get-Content -Raw -LiteralPath $upgradeResultPath
        foreach ($marker in @(
            '- From: `0.10.0`',
            '- To: `0.11.1`',
            '- Known-pristine v0.10.0 core SHA-256: `FB0756CE6F5A2B705E7C95E926E15453CB3BFD54347A1FE2A666F8A3B78CF187`',
            '- Source core identity: `VERIFIED`'
        )) {
            if (-not $upgradeResultText.Contains($marker)) {
                $errors.Add("Installed upgrade result is missing identity evidence: $marker")
            }
        }
    }
}

$corePath = if ($Mode -in @("NewProject", "UpgradeActive")) { $newAgentsPath } else { $candidatePath }
if (Test-Path -LiteralPath $corePath -PathType Leaf) {
    $coreBytes = (Get-Item -LiteralPath $corePath).Length
    if ($coreBytes -gt 28672) {
        $errors.Add("Agent Zero core is $coreBytes bytes; keep the stable core at or below 28672 bytes.")
    }

    $coreText = Get-Content -Raw -LiteralPath $corePath
    foreach ($section in @("# Agent Zero v0.11.1", "## Stable core contract và project context", "## ADOPTION", "## Adaptive goal governance", "## Meta-review và cải tiến", "## Learning loop và bộ nhớ học tập riêng", "## Capability coexistence và resolver")) {
        if (-not $coreText.Contains($section)) {
            $errors.Add("Agent Zero core is missing section: $section")
        }
    }
    foreach ($marker in @("CUTOVER -> VERIFYING -> AWAITING_USER_ACCEPTANCE -> VERIFIED", "Acceptance request", "restore checks", "freshness")) {
        if (-not $coreText.Contains($marker)) {
            $errors.Add("AZ-CORE-POLICY-ADOPTION: Agent Zero core is missing adoption invariant marker: $marker")
        }
    }
    foreach ($marker in @("HYPOTHESIS -> PROPOSED -> ACCEPTED -> SUPERSEDED", "Opportunity backlog", "OFF_GOAL", "MAINTENANCE|INCIDENT", "không suy ra roadmap")) {
        if (-not $coreText.Contains($marker)) {
            $errors.Add("AZ-CORE-POLICY-GOAL: Agent Zero core is missing adaptive-goal invariant marker: $marker")
        }
    }
    foreach ($marker in @("CONTEXT_INDEX.md", "select-context.ps1", "Hot control plane", "fingerprint", "quota")) {
        if (-not $coreText.Contains($marker)) {
            $errors.Add("AZ-CORE-POLICY-CONTEXT: Agent Zero core is missing bounded-context marker: $marker")
        }
    }
    foreach ($marker in @("governance fitness", "SELF_IMPROVEMENT_PROPOSAL", "PROJECT_SPECIFIC|FRAMEWORK_CORE", "SAFETY_INVARIANT|USER_BOUNDARY|PROCEDURAL_DEFAULT|CAPABILITY_ASSUMPTION", "FRICTION -> DIAGNOSED -> PROPOSED -> ACCEPTED|REJECTED -> IMPLEMENTED -> BEHAVIORALLY_VERIFIED", "IncludeProposed")) {
        if (-not $coreText.Contains($marker)) {
            $errors.Add("AZ-CORE-POLICY-META-REVIEW: Agent Zero core is missing self-improvement invariant marker: $marker")
        }
    }
    foreach ($marker in @("HARD_INVARIANT|REQUIRED_OUTCOME|PROCEDURAL_DEFAULT|CAPABILITY_ASSUMPTION", "TRIVIAL|STANDARD|HIGH_RISK|GOVERNANCE", "UNDERSTAND -> DIRECT_REPORT -> COMPLETE", "AUDIT -> CHECKPOINT -> REMEDIATION", "VERIFY_FAIL -> REPAIR -> VERIFY", "COMPLETE|BLOCKED|AWAITING_USER_DECISION", "repair<=2|review<=2|meta-review<=1|proposal<=1|memory-transaction<=1|subagent-starts<=3|full-matrix<=2", "Logical task ID", "80%-<90%", ">=90%", "tóm tắt hiện trạng/next action", "chỉ resume cùng ID/counter khi dưới 90", "matrix 1 FAIL -> repair mới -> focused PASS", "focused check", "canonical source", "PASS|FAIL", "fallback/downgrade/switch model", "NO_DURABLE_LEARNING", "NO_MEMORY_DELTA", "internal phase")) {
        if (-not $coreText.Contains($marker)) {
            $errors.Add("AZ-CORE-POLICY-BOUNDED-EXECUTION: Agent Zero core is missing bounded-execution marker: $marker")
        }
    }
    foreach ($marker in @("BASELINE|IGNORE|REUSE|COMPOSE|SPECIALIZE|CONFLICT|FALLBACK", "AGENT_ZERO_PROJECT", "EXISTING_PROJECT", "EXTERNAL_USER", "INHERIT_PARENT_RUN", "az-<project>-", "az_<project>_")) {
        if (-not $coreText.Contains($marker)) {
            $errors.Add("AZ-CORE-POLICY-CAPABILITY: Agent Zero core is missing coexistence invariant marker: $marker")
        }
    }
    $subAgentSectionMatches = [regex]::Matches($coreText, '(?ms)^##[ \t]+[^\r\n]*sub-agent[^\r\n]*\r?\n(?<body>.*?)(?=^##[ \t]|\z)')
    if ($subAgentSectionMatches.Count -ne 1) {
        $errors.Add("AZ-CORE-SECTION-SUBAGENT: Agent Zero core must contain exactly one sub-agent coordination section; found $($subAgentSectionMatches.Count).")
    }
    else {
        $subAgentPolicyBody = $subAgentSectionMatches[0].Groups["body"].Value
        foreach ($marker in @("runtime", "tool trace", "objective", "ba start", "Logical task ID", "nested delegation", "approval", "integration check", "write ownership", "repair count", "orchestrator", "budget con", "Persistent custom agent")) {
            if (-not $subAgentPolicyBody.Contains($marker)) {
                $errors.Add("AZ-CORE-POLICY-SUBAGENT: sub-agent coordination policy is missing invariant marker: $marker")
            }
        }
    }
}

$corePolicyValidatorPath = Join-Path $agentZeroRoot "scripts/validate-core-policy.ps1"
$installedReferenceRoot = Join-Path $agentZeroRoot "references"
if ((Test-Path -LiteralPath $corePolicyValidatorPath -PathType Leaf) -and
    (Test-Path -LiteralPath $corePath -PathType Leaf) -and
    (Test-Path -LiteralPath $installedReferenceRoot -PathType Container)) {
    & $corePolicyValidatorPath -CorePath $corePath -ReferenceRoot $installedReferenceRoot -ExpectedVersion "0.11.1" | Out-Null
}

if ($Mode -eq "NewProject") {
    $claudeAdapterPath = Join-Path $projectRoot "CLAUDE.md"
    if (Test-Path -LiteralPath $claudeAdapterPath -PathType Leaf) {
        $claudeAdapter = Get-Content -Raw -LiteralPath $claudeAdapterPath
        if (-not $claudeAdapter.Contains("@AGENTS.md")) {
            $errors.Add("New-project CLAUDE.md must import AGENTS.md.")
        }
    }

    $projectMemoryPath = Join-Path $projectRoot ".agent/PROJECT.md"
    if (Test-Path -LiteralPath $projectMemoryPath -PathType Leaf) {
        $projectMemory = Get-Content -Raw -LiteralPath $projectMemoryPath
        if (-not $projectMemory.Contains('- Status: `BOOTSTRAP`')) {
            $errors.Add("New-project memory must begin in BOOTSTRAP status.")
        }
        if (-not $projectMemory.Contains('- Schema: `4`') -or -not $projectMemory.Contains('## Goal governance') -or -not $projectMemory.Contains('## Context architecture')) {
            $errors.Add("New-project memory must use schema 4 bounded context governance.")
        }
    }

    $stateMemoryPath = Join-Path $projectRoot ".agent/STATE.md"
    if (Test-Path -LiteralPath $stateMemoryPath -PathType Leaf) {
        $stateMemory = Get-Content -Raw -LiteralPath $stateMemoryPath
        foreach ($marker in @('- Schema: `6`', '- Logical task ID:', '- Task phase:', '- Sub-agent start limit: `3`', '- Full-matrix limit: `2`', '- Full-matrix last result:', '- Full-matrix retry state:', '- Full-matrix failure repair baseline:', '- Full-matrix retry evidence:', '- Usage gate:', '- Quota checkpoint summary:', '- Quota checkpoint next action:', '- Quota resume condition:', '- Execution profile:', '- Review limit: `2`', '- Meta-review limit: `1`', '- Proposal limit: `1`', '- Memory transaction limit: `1`')) {
            if (-not $stateMemory.Contains($marker)) {
                $errors.Add("New-project state is missing bounded-loop marker: $marker")
            }
        }
    }

    foreach ($relativeDirectory in @(".agent/lessons", ".agent/decisions", ".agent/skill-candidates", ".agent/subagent-candidates", ".agent/archive/lessons", ".agent/archive/decisions", ".agent/archive/changelog")) {
        if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $relativeDirectory) -PathType Container)) {
            $errors.Add("Missing memory directory: $relativeDirectory")
        }
    }

    $memoryValidatorPath = Join-Path $agentZeroRoot "scripts/validate-memory.ps1"
    if (Test-Path -LiteralPath $memoryValidatorPath -PathType Leaf) {
        & $memoryValidatorPath -ProjectRoot $projectRoot
    }
}
elseif ($Mode -eq "UpgradeActive") {
    $capabilityRegistryPath = Join-Path $projectRoot ".agent/CAPABILITIES.md"
    $subagentRegistryPath = Join-Path $projectRoot ".agent/SUBAGENTS.md"
    $hasCapabilityRegistry = Test-Path -LiteralPath $capabilityRegistryPath -PathType Leaf
    $hasSubagentRegistry = Test-Path -LiteralPath $subagentRegistryPath -PathType Leaf
    if ($hasCapabilityRegistry -xor $hasSubagentRegistry) {
        $errors.Add("UpgradeActive found a partial capability schema after installation.")
    }
    elseif ($hasCapabilityRegistry) {
        $memoryValidatorPath = Join-Path $agentZeroRoot "scripts/validate-memory.ps1"
        if (-not (Test-Path -LiteralPath $memoryValidatorPath -PathType Leaf)) {
            $errors.Add("UpgradeActive cannot validate active capability registries because validate-memory.ps1 is missing.")
        }
        else {
            try { & $memoryValidatorPath -ProjectRoot $projectRoot -AllowLegacyStateSchema5 | Out-Null }
            catch { $errors.Add("UpgradeActive capability registry validation failed: $($_.Exception.Message)") }
        }
    }
}
elseif ($Mode -in @("ExistingProject", "UpgradeCandidate")) {
    $adoptionPath = Join-Path $projectRoot ".agent-zero/adoption/ADOPTION.md"
    if (Test-Path -LiteralPath $adoptionPath -PathType Leaf) {
        $adoptionText = Get-Content -Raw -LiteralPath $adoptionPath
        if ($Mode -eq "ExistingProject" -and -not $adoptionText.Contains('- Status: `DETECTED`')) {
            $errors.Add("Existing-project adoption report must begin in DETECTED status.")
        }
    }
}

$adoptionValidatorPath = Join-Path $agentZeroRoot "scripts/validate-adoption.ps1"
$adoptionTemplatePath = Join-Path $agentZeroRoot "templates/ADOPTION.md"
if ((Test-Path -LiteralPath $adoptionValidatorPath -PathType Leaf) -and
    (Test-Path -LiteralPath $adoptionTemplatePath -PathType Leaf)) {
    & $adoptionValidatorPath -ReportPath $adoptionTemplatePath
}
if ($Mode -in @("ExistingProject", "UpgradeCandidate") -and (Test-Path -LiteralPath $adoptionValidatorPath -PathType Leaf)) {
    $installedAdoptionPath = Join-Path $projectRoot ".agent-zero/adoption/ADOPTION.md"
    if (Test-Path -LiteralPath $installedAdoptionPath -PathType Leaf) {
        & $adoptionValidatorPath -ReportPath $installedAdoptionPath
    }
}

if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Agent Zero kit validation failed ($Mode):$([Environment]::NewLine)$details"
}

$versionPath = Join-Path $agentZeroRoot "VERSION"
$version = (Get-Content -Raw -LiteralPath $versionPath).Trim()
Write-Host "Agent Zero kit validation passed." -ForegroundColor Green
Write-Host "Mode: $Mode"
Write-Host "Version: $version"
Write-Host "Project root: $projectRoot"
