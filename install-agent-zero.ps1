param(
    [string]$TargetPath,
    [switch]$WhatIf,
    [switch]$NonInteractive,
    [switch]$LauncherOwnsFailurePause,
    [string[]]$AdditionalInstructionName = @()
)

$ErrorActionPreference = "Stop"

$kitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadRoot = Join-Path $kitRoot "payload"
$candidateSource = Join-Path $kitRoot "AGENT_ZERO_CANDIDATE.md"
$claudeAdapterSource = Join-Path $payloadRoot "adapters/CLAUDE.md"
$startSource = Join-Path $payloadRoot "START.md"
$kitFullPath = [System.IO.Path]::GetFullPath($kitRoot)
$targetWasProvided = $PSBoundParameters.ContainsKey("TargetPath") -and -not [string]::IsNullOrWhiteSpace($TargetPath)
$interactiveMode = -not $targetWasProvided -and -not $NonInteractive
$installationCommitted = $false
$rollbackTargets = [System.Collections.Generic.List[string]]::new()
$activationPrompt = "Khoi dong Agent Zero theo .agent-zero/START.md"

function Wait-BeforeClose {
    param([string]$Message = "Nhan Enter de dong cua so")

    if ($interactiveMode -and -not $LauncherOwnsFailurePause) {
        [void](Read-Host $Message)
    }
}

function Show-ModeExplanation {
    Write-Host ""
    Write-Host "HAI CHE DO CAI DAT" -ForegroundColor Cyan
    Write-Host "1. Project moi hoan toan (NEW_PROJECT)"
    Write-Host "   Tao AGENTS.md, CLAUDE.md va bo nho .agent de Agent Zero hoat dong ngay."
    Write-Host "2. Project cu hoac da co agent (ADOPTION)"
    Write-Host "   Giu nguyen context hien tai va chi cai Agent Zero dang candidate o che do shadow."
    Write-Host ""
    Write-Host "Neu khong chac, hay chon ADOPTION. Day la lua chon an toan hon." -ForegroundColor Yellow
}

function Select-InstallMode {
    param(
        [ValidateSet("NEW_PROJECT", "ADOPTION")]
        [string]$DetectedMode,
        [System.Collections.Generic.List[string]]$DetectedSignals
    )

    $recommendedChoice = if ($DetectedMode -eq "NEW_PROJECT") { "1" } else { "2" }

    while ($true) {
        Write-Host ""
        Write-Host "CHON CACH CAI DAT" -ForegroundColor Cyan
        $newLabel = if ($recommendedChoice -eq "1") { " (khuyen nghi)" } else { " (khong kha dung - da phat hien context)" }
        $adoptionLabel = if ($recommendedChoice -eq "2") { " (khuyen nghi)" } else { " (lua chon than trong)" }
        Write-Host "1. Project moi hoan toan - NEW_PROJECT$newLabel"
        Write-Host "2. Project cu hoac da co agent - ADOPTION$adoptionLabel"
        Write-Host "3. Xem giai thich hai che do"
        Write-Host "Q. Huy cai dat"
        Write-Host ""

        $choice = (Read-Host "Lua chon [$recommendedChoice]").Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -in @("Y", "y", "YES", "Yes", "yes")) {
            $choice = $recommendedChoice
        }

        switch ($choice.ToUpperInvariant()) {
            "1" {
                if ($DetectedMode -eq "ADOPTION") {
                    Write-Host ""
                    Write-Host "Khong the chon NEW_PROJECT vi installer da phat hien context agent hien co:" -ForegroundColor Red
                    foreach ($signal in $DetectedSignals) {
                        Write-Host "- $signal" -ForegroundColor Yellow
                    }
                    Write-Host "Hay chon ADOPTION de bao ve cac file nay, hoac Q de huy." -ForegroundColor Yellow
                    continue
                }
                return "NEW_PROJECT"
            }
            "2" {
                return "ADOPTION"
            }
            "3" {
                Show-ModeExplanation
                continue
            }
            { $_ -in @("Q", "N", "NO") } {
                return "CANCELLED"
            }
            default {
                Write-Host "Lua chon khong hop le. Hay nhap 1, 2, 3 hoac Q." -ForegroundColor Yellow
            }
        }
    }
}

function Write-InstallStep {
    param(
        [int]$Step,
        [int]$Total,
        [string]$Message
    )

    Write-Host "[$Step/$Total] $Message" -ForegroundColor Cyan
}

function Show-SuccessActions {
    param(
        [string]$Prompt,
        [string]$NextStepsPath
    )

    if (-not $interactiveMode) {
        return
    }

    while ($true) {
        Write-Host ""
        $action = (Read-Host "[C] Copy lenh  [O] Mo huong dan  [Enter] Dong").Trim()
        if ([string]::IsNullOrWhiteSpace($action)) {
            return
        }

        switch ($action.ToUpperInvariant()) {
            "C" {
                try {
                    Set-Clipboard -Value $Prompt -ErrorAction Stop
                    Write-Host "Da copy lenh khoi dong vao clipboard." -ForegroundColor Green
                }
                catch {
                    Write-Host "Khong the copy tu dong. Hay copy dong lenh hien tren man hinh." -ForegroundColor Yellow
                }
            }
            "O" {
                try {
                    Start-Process -FilePath $NextStepsPath -ErrorAction Stop
                    Write-Host "Da mo file huong dan." -ForegroundColor Green
                }
                catch {
                    Write-Host "Khong the mo tu dong. File huong dan nam tai: $NextStepsPath" -ForegroundColor Yellow
                }
            }
            default {
                Write-Host "Hay nhap C, O hoac Enter." -ForegroundColor Yellow
            }
        }
    }
}

function Undo-AgentZeroInstall {
    param(
        [string]$ProjectRoot,
        [System.Collections.Generic.List[string]]$Paths
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or $Paths.Count -eq 0) {
        return
    }

    $projectFullPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $projectBoundary = $projectFullPath + '\'
    $rollbackFailures = [System.Collections.Generic.List[string]]::new()

    for ($index = $Paths.Count - 1; $index -ge 0; $index--) {
        $rollbackPath = [System.IO.Path]::GetFullPath($Paths[$index])
        if (-not $rollbackPath.StartsWith($projectBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rollbackFailures.Add("Unsafe rollback target was skipped: $rollbackPath")
            continue
        }

        if (-not (Test-Path -LiteralPath $rollbackPath)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $rollbackPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $rollbackFailures.Add("Could not remove $rollbackPath : $($_.Exception.Message)")
        }
    }

    if ($rollbackFailures.Count -gt 0) {
        Write-Host "Rollback khong hoan tat:" -ForegroundColor Red
        foreach ($rollbackFailure in $rollbackFailures) {
            Write-Host "- $rollbackFailure" -ForegroundColor Red
        }
    }
    else {
        Write-Host "Da rollback cac file do lan cai dat nay tao ra." -ForegroundColor Yellow
    }
}

try {
    if ($targetWasProvided) {
        $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
    }
    else {
        # Right-click flow: agent-zero-kit is copied as one folder inside the project.
        $targetFullPath = [System.IO.Path]::GetFullPath((Split-Path -Parent $kitFullPath))
    }

    if (-not (Test-Path -LiteralPath $targetFullPath -PathType Container)) {
        throw "Target project does not exist or is not a directory: $targetFullPath"
    }

    if ($targetFullPath.TrimEnd('\') -eq $kitFullPath.TrimEnd('\')) {
        throw "Target project cannot be the Agent Zero kit directory itself."
    }

    $targetDriveRoot = [System.IO.Path]::GetPathRoot($targetFullPath)
    if ($targetFullPath.TrimEnd('\') -eq $targetDriveRoot.TrimEnd('\')) {
        throw "Refusing to install Agent Zero directly into a drive root: $targetFullPath"
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "          AGENT ZERO SETUP" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Project: $targetFullPath" -ForegroundColor White
    Write-Host "Dang kiem tra project va context agent..." -ForegroundColor Cyan

$requiredPayloadFiles = @(
    $candidateSource,
    $claudeAdapterSource,
    $startSource,
    (Join-Path $payloadRoot "VERSION"),
    (Join-Path $payloadRoot "TESTING.md"),
    (Join-Path $payloadRoot "references/ADOPTION_PROTOCOL.md"),
    (Join-Path $payloadRoot "references/BOOTSTRAP_PROTOCOL.md"),
    (Join-Path $payloadRoot "references/GOAL_GOVERNANCE.md"),
    (Join-Path $payloadRoot "references/EXECUTION_PROTOCOL.md"),
    (Join-Path $payloadRoot "references/MEMORY_PROTOCOL.md"),
    (Join-Path $payloadRoot "references/SUBAGENT_POLICY.md"),
    (Join-Path $payloadRoot "references/SKILL_POLICY.md"),
    (Join-Path $payloadRoot "templates/ADOPTION.md"),
    (Join-Path $payloadRoot "templates/PROJECT.md"),
    (Join-Path $payloadRoot "templates/STATE.md"),
    (Join-Path $payloadRoot "templates/CONTEXT_INDEX.md"),
    (Join-Path $payloadRoot "templates/DECISIONS.md"),
    (Join-Path $payloadRoot "templates/DECISION.md"),
    (Join-Path $payloadRoot "templates/LESSONS.md"),
    (Join-Path $payloadRoot "templates/LESSON.md"),
    (Join-Path $payloadRoot "templates/SKILLS.md"),
    (Join-Path $payloadRoot "templates/SKILL.md"),
    (Join-Path $payloadRoot "templates/SKILL_EVALS.md"),
    (Join-Path $payloadRoot "templates/CHANGELOG.md"),
    (Join-Path $payloadRoot "templates/archive/LESSONS_INDEX.md"),
    (Join-Path $payloadRoot "templates/archive/DECISIONS_INDEX.md"),
    (Join-Path $payloadRoot "scripts/validate-install.ps1"),
    (Join-Path $payloadRoot "scripts/validate-core-policy.ps1"),
    (Join-Path $payloadRoot "scripts/validate-adoption.ps1"),
    (Join-Path $payloadRoot "scripts/validate-memory.ps1"),
    (Join-Path $payloadRoot "scripts/validate-skill.ps1"),
    (Join-Path $payloadRoot "scripts/select-context.ps1")
)

foreach ($requiredPayloadFile in $requiredPayloadFiles) {
    if (-not (Test-Path -LiteralPath $requiredPayloadFile -PathType Leaf)) {
        throw "Agent Zero kit payload is incomplete: $requiredPayloadFile"
    }
}

$existingSignals = [System.Collections.Generic.List[string]]::new()
$instructionNames = [System.Collections.Generic.List[string]]::new()
$defaultInstructionNames = @(
    "AGENTS.md",
    "AGENTS.override.md",
    ".agents.md",
    "CLAUDE.md",
    "CLAUDE.local.md",
    ".cursorrules",
    ".windsurfrules",
    "GEMINI.md",
    "TEAM_GUIDE.md",
    "AI_INSTRUCTIONS.md"
)

foreach ($instructionName in @($defaultInstructionNames + $AdditionalInstructionName)) {
    if (-not [string]::IsNullOrWhiteSpace($instructionName) -and
        [System.IO.Path]::GetFileName($instructionName) -eq $instructionName -and
        $instructionName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0 -and
        -not $instructionNames.Contains($instructionName)) {
        $instructionNames.Add($instructionName)
    }
}

$codexHomePath = $null
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    $codexHomePath = $env:CODEX_HOME
}
else {
    $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
        $userProfilePath = $env:USERPROFILE
    }
    if (-not [string]::IsNullOrWhiteSpace($userProfilePath)) {
        $codexHomePath = Join-Path $userProfilePath ".codex"
    }
}

$codexConfigPath = if ([string]::IsNullOrWhiteSpace($codexHomePath)) { $null } else { Join-Path $codexHomePath "config.toml" }
if (-not [string]::IsNullOrWhiteSpace($codexConfigPath) -and (Test-Path -LiteralPath $codexConfigPath -PathType Leaf)) {
    try {
        $codexConfigText = [System.IO.File]::ReadAllText($codexConfigPath)
        $fallbackAssignment = [regex]::Match(
            $codexConfigText,
            '(?ms)^\s*project_doc_fallback_filenames\s*=\s*\[(?<values>.*?)\]'
        )
        if ($fallbackAssignment.Success) {
            foreach ($nameMatch in [regex]::Matches($fallbackAssignment.Groups["values"].Value, '"(?<name>[^\"]+)"')) {
                $fallbackName = $nameMatch.Groups["name"].Value
                if (-not [string]::IsNullOrWhiteSpace($fallbackName) -and
                    [System.IO.Path]::GetFileName($fallbackName) -eq $fallbackName -and
                    $fallbackName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0 -and
                    -not $instructionNames.Contains($fallbackName)) {
                    $instructionNames.Add($fallbackName)
                }
            }
        }
    }
    catch {
        Write-Warning "Could not read Codex fallback instruction names; continuing with built-in detection."
    }
}

$contextDirectoryNames = @(".agent", ".agents", ".claude", ".cursor", ".codex")
$skipDirectoryNames = @(".git", "node_modules", "vendor", ".venv", "venv", "dist", "build", "target", "coverage", ".next", "out")
$directoryQueue = [System.Collections.Generic.Queue[System.IO.DirectoryInfo]]::new()
$directoryQueue.Enqueue((Get-Item -LiteralPath $targetFullPath))
$targetPrefixLength = $targetFullPath.TrimEnd('\').Length + 1

while ($directoryQueue.Count -gt 0) {
    $currentDirectory = $directoryQueue.Dequeue()

    try {
        $currentFiles = @(Get-ChildItem -LiteralPath $currentDirectory.FullName -Force -File -ErrorAction Stop)
        $currentDirectories = @(Get-ChildItem -LiteralPath $currentDirectory.FullName -Force -Directory -ErrorAction Stop)
    }
    catch {
        throw "Cannot safely inspect project directory: $($currentDirectory.FullName). $($_.Exception.Message)"
    }

    foreach ($file in $currentFiles) {
        $relativePath = $file.FullName.Substring($targetPrefixLength).Replace('\', '/')
        $isKnownInstruction = $instructionNames -contains $file.Name
        $isCopilotInstruction = $relativePath -ieq ".github/copilot-instructions.md"
        $isGitHubInstruction = $relativePath -ilike ".github/instructions/*.instructions.md"
        $isGitHubAgent = $relativePath -ilike ".github/agents/*.agent.md"
        if (($isKnownInstruction -or $isCopilotInstruction -or $isGitHubInstruction -or $isGitHubAgent) -and -not $existingSignals.Contains($relativePath)) {
            $existingSignals.Add($relativePath)
        }
    }

    foreach ($directory in $currentDirectories) {
        $relativePath = $directory.FullName.Substring($targetPrefixLength).Replace('\', '/')
        $directoryFullPath = [System.IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
        if ($directoryFullPath -eq $kitFullPath.TrimEnd('\')) {
            continue
        }
        if ($contextDirectoryNames -contains $directory.Name) {
            if (-not $existingSignals.Contains($relativePath)) {
                $existingSignals.Add($relativePath)
            }
            continue
        }
        if ($skipDirectoryNames -contains $directory.Name) {
            continue
        }
        $directoryQueue.Enqueue($directory)
    }
}

$detectedMode = if ($existingSignals.Count -gt 0) { "ADOPTION" } else { "NEW_PROJECT" }
$agentZeroDestination = Join-Path $targetFullPath ".agent-zero"
$candidateDestination = Join-Path $targetFullPath "AGENT_ZERO_CANDIDATE.md"
$agentsDestination = Join-Path $targetFullPath "AGENTS.md"
$claudeDestination = Join-Path $targetFullPath "CLAUDE.md"
$memoryDestination = Join-Path $targetFullPath ".agent"
$nextStepsDestination = Join-Path $agentZeroDestination "NEXT_STEPS.md"

Write-Host ""
Write-Host "KET QUA KIEM TRA" -ForegroundColor Cyan
if ($detectedMode -eq "ADOPTION") {
    Write-Host "Phat hien: Project da co agent hoac context lien quan." -ForegroundColor Yellow
    Write-Host "Che do khuyen nghi: ADOPTION (giu nguyen context hien tai)" -ForegroundColor Green
    Write-Host "Evidence da phat hien:"
    foreach ($existingSignal in $existingSignals) {
        Write-Host "- $existingSignal"
    }
}
else {
    Write-Host "Phat hien: Chua co agent hoac project memory." -ForegroundColor Green
    Write-Host "Che do khuyen nghi: NEW_PROJECT"
    Write-Host "Evidence: khong tim thay file instruction hoac thu muc context da biet."
}

if ($interactiveMode -and -not $WhatIf) {
    $mode = Select-InstallMode -DetectedMode $detectedMode -DetectedSignals $existingSignals
    if ($mode -eq "CANCELLED") {
        Write-Host "Da huy. Khong co file nao duoc thay doi." -ForegroundColor Yellow
        Wait-BeforeClose
        return
    }
}
else {
    $mode = $detectedMode
}

Write-Host ""
Write-Host "Che do se dung: $mode" -ForegroundColor Green
if ($mode -eq "ADOPTION") {
    Write-Host "Installer se khong sua AGENTS.md, CLAUDE.md hoac context agent hien co."
}

if (Test-Path -LiteralPath $agentZeroDestination) {
    throw "Refusing to overwrite existing .agent-zero directory: $agentZeroDestination"
}

if (Test-Path -LiteralPath $candidateDestination) {
    throw "Refusing to overwrite existing candidate: $candidateDestination"
}

if ($mode -eq "NEW_PROJECT") {
    if (Test-Path -LiteralPath $agentsDestination) {
        throw "Detection inconsistency: AGENTS.md exists but mode is NEW_PROJECT."
    }
    if (Test-Path -LiteralPath $memoryDestination) {
        throw "Detection inconsistency: .agent exists but mode is NEW_PROJECT."
    }
    if (Test-Path -LiteralPath $claudeDestination) {
        throw "Detection inconsistency: CLAUDE.md exists but mode is NEW_PROJECT."
    }
}

$rollbackTargets.Add($agentZeroDestination)
if ($mode -eq "NEW_PROJECT") {
    $rollbackTargets.Add($agentsDestination)
    $rollbackTargets.Add($claudeDestination)
    $rollbackTargets.Add($memoryDestination)
}
else {
    $rollbackTargets.Add($candidateDestination)
}

if ($WhatIf) {
    Write-Host "WhatIf: da kiem tra xong; khong co file nao duoc thay doi." -ForegroundColor Yellow
    Wait-BeforeClose
    return
}

Write-Host ""
Write-InstallStep -Step 1 -Total 4 -Message "Dang cai cac file Agent Zero..."
New-Item -ItemType Directory -Path $agentZeroDestination | Out-Null
Copy-Item -LiteralPath (Join-Path $payloadRoot "VERSION") -Destination (Join-Path $agentZeroDestination "VERSION")
Copy-Item -LiteralPath (Join-Path $payloadRoot "TESTING.md") -Destination (Join-Path $agentZeroDestination "TESTING.md")
Copy-Item -LiteralPath $startSource -Destination (Join-Path $agentZeroDestination "START.md")
Copy-Item -LiteralPath (Join-Path $payloadRoot "references") -Destination (Join-Path $agentZeroDestination "references") -Recurse
Copy-Item -LiteralPath (Join-Path $payloadRoot "templates") -Destination (Join-Path $agentZeroDestination "templates") -Recurse
Copy-Item -LiteralPath (Join-Path $payloadRoot "scripts") -Destination (Join-Path $agentZeroDestination "scripts") -Recurse

Write-InstallStep -Step 2 -Total 4 -Message "Dang cau hinh che do $mode..."
if ($mode -eq "NEW_PROJECT") {
    Copy-Item -LiteralPath $candidateSource -Destination $agentsDestination
    Copy-Item -LiteralPath $claudeAdapterSource -Destination $claudeDestination
    New-Item -ItemType Directory -Path $memoryDestination | Out-Null
    foreach ($memoryFile in @("PROJECT.md", "STATE.md", "CONTEXT_INDEX.md", "DECISIONS.md", "LESSONS.md", "SKILLS.md", "CHANGELOG.md")) {
        Copy-Item -LiteralPath (Join-Path $payloadRoot "templates/$memoryFile") -Destination (Join-Path $memoryDestination $memoryFile)
    }
    foreach ($memoryDirectory in @("lessons", "decisions", "archive", "archive/lessons", "archive/decisions", "archive/changelog")) {
        New-Item -ItemType Directory -Path (Join-Path $memoryDestination $memoryDirectory) | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $payloadRoot "templates/archive/LESSONS_INDEX.md") -Destination (Join-Path $memoryDestination "archive/LESSONS_INDEX.md")
    Copy-Item -LiteralPath (Join-Path $payloadRoot "templates/archive/DECISIONS_INDEX.md") -Destination (Join-Path $memoryDestination "archive/DECISIONS_INDEX.md")

}
else {
    Copy-Item -LiteralPath $candidateSource -Destination $candidateDestination
    $adoptionDestination = Join-Path $agentZeroDestination "adoption"
    New-Item -ItemType Directory -Path $adoptionDestination | Out-Null
    Copy-Item -LiteralPath (Join-Path $payloadRoot "templates/ADOPTION.md") -Destination (Join-Path $adoptionDestination "ADOPTION.md")

    $resultLines = @(
        "# Agent Zero Install Result",
        "",
        "- Mode: ``ADOPTION``",
        "- Auto-detected mode: ``$detectedMode``",
        "- Existing context was not modified.",
        "- Detected signals:"
    )
    if ($existingSignals.Count -gt 0) {
        foreach ($existingSignal in $existingSignals) {
            $resultLines += "  - ``$existingSignal``"
        }
    }
    else {
        $resultLines += "  - ``NONE - ADOPTION was selected manually``"
    }
    [System.IO.File]::WriteAllLines((Join-Path $agentZeroDestination "INSTALL_RESULT.md"), $resultLines, [System.Text.UTF8Encoding]::new($false))

}

$modeDescription = if ($mode -eq "NEW_PROJECT") {
    "Project moi; Agent Zero da duoc cai lam agent dang hoat dong."
}
else {
    "Project cu/da co agent; Agent Zero duoc cai dang candidate o che do ADOPTION shadow."
}
$nextStepsLines = @(
    "# Agent Zero - Buoc tiep theo",
    "",
    "- Ket qua: ``CAI DAT THANH CONG``",
    "- Che do: ``$mode``",
    "- Auto-detect: ``$detectedMode``",
    "- Y nghia: $modeDescription",
    "",
    "## Khoi dong",
    "",
    "1. Mo mot phien AI moi tai thu muc goc cua project: ``$targetFullPath``",
    "2. Gui dung mot cau ngan sau:",
    "",
    '```text',
    $activationPrompt,
    '```',
    "",
    "Agent se doc ``.agent-zero/START.md``, xac nhan che do va huong dan ban tung buoc."
)
if ($mode -eq "ADOPTION") {
    $nextStepsLines += @(
        "",
        "## Bao ve project cu",
        "",
        "Installer khong sua, doi ten hoac thay the context agent hien co. Agent Zero bat dau o che do shadow va chi cutover sau khi ban phe duyet."
    )
}
[System.IO.File]::WriteAllLines($nextStepsDestination, $nextStepsLines, [System.Text.UTF8Encoding]::new($false))

Write-InstallStep -Step 3 -Total 4 -Message "Dang kiem tra tinh toan ven cua ban cai..."
$validationMode = if ($mode -eq "NEW_PROJECT") { "NewProject" } else { "ExistingProject" }
& (Join-Path $agentZeroDestination "scripts/validate-install.ps1") -Mode $validationMode
$installationCommitted = $true
Write-InstallStep -Step 4 -Total 4 -Message "Kiem tra hoan tat. Dang hien thi buoc tiep theo..."

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "       CAI DAT THANH CONG" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Che do: $mode"
if ($mode -eq "NEW_PROJECT") {
    Write-Host "Agent Zero da san sang bootstrap project moi." -ForegroundColor Green
}
else {
    Write-Host "Agent Zero da duoc cai dang candidate an toan." -ForegroundColor Green
    Write-Host "Context agent hien tai khong bi thay doi."
}

Write-Host ""
Write-Host "BUOC TIEP THEO" -ForegroundColor Cyan
Write-Host "1. Mo mot phien AI moi tai project: $targetFullPath"
Write-Host "2. Gui mot cau ngan sau:" -ForegroundColor Cyan
Write-Host ""
Write-Host "   $activationPrompt" -ForegroundColor White
Write-Host ""
Write-Host "Huong dan da duoc luu tai: $nextStepsDestination"
$targetPrefix = $targetFullPath.TrimEnd('\') + '\'
$kitIsInsideTarget = $kitFullPath.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)
if ($kitIsInsideTarget) {
    Write-Host "Ban co the xoa thu muc kit sau khi cai: $kitFullPath"
}

Show-SuccessActions -Prompt $activationPrompt -NextStepsPath $nextStepsDestination
}
catch {
    Write-Host ""
    if (-not $installationCommitted) {
        Write-Host "CAI DAT THAT BAI" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Undo-AgentZeroInstall -ProjectRoot $targetFullPath -Paths $rollbackTargets
        Write-Host "Khong tu copy, doi ten hoac ghi de file de bo qua loi." -ForegroundColor Yellow
    }
    else {
        Write-Host "Agent Zero da duoc cai va validation da pass, nhung khong the hien thi day du buoc tiep theo." -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    Wait-BeforeClose
    exit 1
}
