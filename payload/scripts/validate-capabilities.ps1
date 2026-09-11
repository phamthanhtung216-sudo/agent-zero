param(
    [string]$ProjectRoot,
    [string]$RegistryPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptParent = Split-Path -Parent $scriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ((Split-Path -Leaf $scriptParent) -eq ".agent-zero") { $ProjectRoot = Split-Path -Parent $scriptParent }
    else { $ProjectRoot = $scriptParent }
}
$projectFullPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
if ([string]::IsNullOrWhiteSpace($RegistryPath)) { $RegistryPath = Join-Path $projectFullPath ".agent/CAPABILITIES.md" }
$registryFullPath = [System.IO.Path]::GetFullPath($RegistryPath)
$errors = [System.Collections.Generic.List[string]]::new()
$recognizedSecretPattern = '(?i)(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|authorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{12,}|["'']?(?:api[_-]?key|token|password|secret)["'']?\s*[:=]\s*["'']?[A-Za-z0-9._~+/=-]{8,})'

function Add-ValidationError { param([string]$Message) $errors.Add($Message) }
function Clean-Cell { param([string]$Value) return $Value.Trim().Trim('`').Trim() }
function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}
function Read-Utf8Lines {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines([System.IO.Path]::GetFullPath($Path), [System.Text.UTF8Encoding]::new($false, $true))
}
function Test-NoRecognizedSecret {
    param([string]$Value, [string]$Label)
    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match $script:recognizedSecretPattern) {
        Add-ValidationError "$Label may contain a secret or credential."
    }
}
function Get-MarkdownField {
    param([string]$Text, [string]$Label)
    $match = [regex]::Match($Text, '(?m)^\s*-\s*' + [regex]::Escape($Label) + ':\s*`(?<value>[^`]+)`\s*$')
    if ($match.Success) { return $match.Groups['value'].Value.Trim() }
    return $null
}
function Split-Values {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "NONE") { return @() }
    return @($Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Test-SanitizedRef {
    param([string]$Value, [string]$Label, [switch]$AllowNone, [switch]$AllowUnknown)
    if ($AllowNone -and $Value -eq "NONE") { return }
    if ($AllowUnknown -and $Value -eq "UNKNOWN") { return }
    if ([string]::IsNullOrWhiteSpace($Value) -or
        [System.IO.Path]::IsPathRooted($Value) -or
        $Value -match '(?i)(?:[A-Z]:[\\/]+Users[\\/]+|/Users/|/home/|\\\\)' -or
        $Value -match '(^|[\\/])\.\.([\\/]|$)') {
        Add-ValidationError "$Label contains an absolute, personal, UNC, traversal, or empty reference: $Value"
    }
    Test-NoRecognizedSecret -Value $Value -Label $Label
}
function Test-ShaField {
    param([string]$Value, [string]$Label, [switch]$AllowUnknown)
    if ($AllowUnknown -and $Value -eq "UNKNOWN") { return }
    if ($Value -notmatch '^SHA256:[A-Fa-f0-9]{64}$') { Add-ValidationError "$Label must be SHA256:<64 hex>$(if($AllowUnknown){' or UNKNOWN'}): $Value" }
}
function Test-CapabilityKey {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^[a-z0-9]+(?:\.[a-z0-9]+)*$') { Add-ValidationError "$Label has invalid capability key: $Value" }
}
function Test-Contribution {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^[a-z0-9]+(?:[._-][a-z0-9]+)*$') { Add-ValidationError "$Label has invalid contribution: $Value" }
}
function Get-SideEffectRank {
    param([string]$Value)
    switch ($Value) {
        "READ_ONLY" { return 0 }
        "WORKSPACE_WRITE" { return 1 }
        "EXTERNAL_WRITE" { return 2 }
        default { return 3 }
    }
}

if (-not (Test-Path -LiteralPath $registryFullPath -PathType Leaf)) {
    throw "Capability validation failed: registry does not exist: $registryFullPath"
}
$text = Read-Utf8Text $registryFullPath
if ([System.Text.Encoding]::UTF8.GetByteCount($text) -gt 1048576) {
    Add-ValidationError "Capability registry exceeds the 1 MiB standalone validation limit."
}
Test-NoRecognizedSecret -Value $text -Label "Capability registry"
foreach ($heading in @("# Capability Registry", "## Providers", "## Resolutions")) {
    if (-not $text.Contains($heading)) { Add-ValidationError "Registry is missing heading: $heading" }
}
if ((Get-MarkdownField $text "Schema") -ne "1") { Add-ValidationError "Schema must be 1." }
$providerRowSchema = Get-MarkdownField $text "Provider row schema"
$routeRowSchema = Get-MarkdownField $text "Route row schema"
if ($null -ne $providerRowSchema -and $providerRowSchema -ne "2") { Add-ValidationError "Provider row schema must be 2 when declared." }
if ($null -ne $routeRowSchema -and $routeRowSchema -ne "2") { Add-ValidationError "Route row schema must be 2 when declared." }
if (($null -eq $providerRowSchema) -ne ($null -eq $routeRowSchema)) { Add-ValidationError "Provider row schema and Route row schema must be declared together." }
$canonicalProviderRows = $providerRowSchema -eq "2"
$canonicalRouteRows = $routeRowSchema -eq "2"
$registryLines = Read-Utf8Lines $registryFullPath
$expectedProviderHeader = if ($canonicalProviderRows) {
    '| Provider ID | Capability keys | Kind | Display name | Scope | Ownership | Authority | Availability | Contributions | Side effect | Delegation | Source ref | Observed SHA256 | Last seen |'
}
else {
    '| Provider ID | Capability key | Kind | Name | Scope | Ownership | Mutation policy | State | Invocation | Side effects | Delegation | Source ref | Observed SHA256 | Last seen |'
}
$expectedRouteHeader = if ($canonicalRouteRows) {
    '| Route ID | Capability key | Use case | Candidate providers | Decision | Selected providers | Required contributions | Max side effect | Delegation allowance | Authority | Fallback evidence | Evidence | Parent-run accounting | Review trigger | Status |'
}
else {
    '| Route ID | Capability key | Use case | Candidate providers | Decision | Selected providers | Boundary/delta | Authority | Parent-run accounting | Evidence | Review trigger | Status |'
}
$expectedProviderSeparator = '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'
$expectedRouteSeparator = if ($canonicalRouteRows) { '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|' } else { '|---|---|---|---|---|---|---|---|---|---|---|---|' }
foreach ($requiredTableLine in @($expectedProviderHeader, $expectedProviderSeparator, $expectedRouteHeader, $expectedRouteSeparator)) {
    if ($requiredTableLine -notin $registryLines) { Add-ValidationError "Registry is missing the exact table header/separator required by its declared row schema: $requiredTableLine" }
}
$inventoryScope = Get-MarkdownField $text "Inventory scope"
if ($inventoryScope -ne "RELEVANT_ONLY") { Add-ValidationError "Inventory scope must be RELEVANT_ONLY." }
$resolutionMode = Get-MarkdownField $text "Resolution mode"
if ($resolutionMode -ne "ON_DEMAND") { Add-ValidationError "Resolution mode must be ON_DEMAND." }
$catalogState = Get-MarkdownField $text "Catalog state"
if ($catalogState -notin @("UNOBSERVED", "CURRENT", "PARTIAL", "STALE")) { Add-ValidationError "Catalog state is invalid: $catalogState" }
$catalogFingerprint = Get-MarkdownField $text "Catalog fingerprint"
if ($catalogFingerprint -ne "NONE") { Test-ShaField $catalogFingerprint "Catalog fingerprint" -AllowUnknown }

$providerDataLines = [System.Collections.Generic.List[string]]::new()
$routeDataLines = [System.Collections.Generic.List[string]]::new()
$tableSection = "NONE"
foreach ($line in $registryLines) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "## Providers") { $tableSection = "PROVIDERS"; continue }
    if ($trimmed -eq "## Resolutions") { $tableSection = "RESOLUTIONS"; continue }
    if ($trimmed -match '^##\s') { $tableSection = "NONE"; continue }
    if ($tableSection -eq "NONE") {
        if ($trimmed -match '^\|\s*`(?:CP|CR)-\d{3,}`\s*\|') { Add-ValidationError "Capability row appears outside its declared Providers/Resolutions table: $trimmed" }
        continue
    }
    if (-not $trimmed.StartsWith('|')) { continue }
    if ($trimmed -match '^\|\s*(?:Provider ID|Route ID)\s*\|' -or $trimmed -match '^\|\s*:?-{3,}') { continue }
    if ($tableSection -eq "PROVIDERS" -and $trimmed -notmatch '^\|\s*`CP-\d{3,}`\s*\|') {
        Add-ValidationError "Provider table contains an unparseable data row; Provider ID must be a backticked CP-NNN identifier: $trimmed"
    }
    elseif ($tableSection -eq "RESOLUTIONS" -and $trimmed -notmatch '^\|\s*`CR-\d{3,}`\s*\|') {
        Add-ValidationError "Resolution table contains an unparseable data row; Route ID must be a backticked CR-NNN identifier: $trimmed"
    }
    elseif ($tableSection -eq "PROVIDERS") { $providerDataLines.Add($line) }
    elseif ($tableSection -eq "RESOLUTIONS") { $routeDataLines.Add($line) }
}

$providers = @{}
$sourceOwners = @{}
foreach ($line in $providerDataLines) {
    if ($line -notmatch '^\|\s*`(?<id>CP-\d{3,})`\s*\|') { continue }
    $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
    if ($cells.Count -ne 14) { Add-ValidationError "Malformed provider row $($matches['id']); expected 14 cells, found $($cells.Count)."; continue }

    $id=$cells[0]; $capabilityKeys=@(Split-Values $cells[1]); $kind=$cells[2]; $displayName=$cells[3]; $scope=$cells[4]; $ownership=$cells[5]
    $availability=$cells[7]; $sideEffect=$cells[9]; $delegation=$cells[10]; $sourceRef=$cells[11]; $observedHash=$cells[12]; $lastSeen=$cells[13]
    $legacyRow = -not $canonicalProviderRows
    if ($legacyRow) {
        $mutation=$cells[6]; $invocation=$cells[8]; $authority="UNKNOWN"; $contributions=@(); $contributionsKnown=$false
    }
    else {
        $authority=$cells[6]; $contributions=@(Split-Values $cells[8]); $contributionsKnown=$cells[8] -ne "UNKNOWN"
    }

    if ($providers.ContainsKey($id)) { Add-ValidationError "Duplicate immutable Provider ID: $id"; continue }
    if ($capabilityKeys.Count -eq 0) { Add-ValidationError "$id requires at least one Capability key." }
    foreach ($key in $capabilityKeys) { Test-CapabilityKey $key $id }
    if ($kind -notin @("SKILL", "CUSTOM_AGENT", "BUILTIN_AGENT", "PLUGIN", "RUNTIME_TOOL", "UNKNOWN")) { Add-ValidationError "$id has invalid Kind: $kind" }
    if ($scope -notin @("REPO", "USER", "ADMIN", "SYSTEM", "PLUGIN", "RUNTIME", "UNKNOWN")) { Add-ValidationError "$id has invalid Scope: $scope" }
    if ($ownership -notin @("AGENT_ZERO_PROJECT", "EXISTING_PROJECT", "EXTERNAL_USER", "EXTERNAL_ADMIN", "EXTERNAL_SYSTEM", "EXTERNAL_PLUGIN", "RUNTIME", "UNKNOWN")) { Add-ValidationError "$id has invalid Ownership: $ownership" }
    if ($ownership -eq "AGENT_ZERO_PROJECT" -and $kind -notin @("SKILL", "CUSTOM_AGENT")) {
        Add-ValidationError "$id Agent Zero-managed providers must use Kind SKILL or CUSTOM_AGENT so lifecycle approval cannot be bypassed."
    }
    if ($scope -ne "UNKNOWN" -and $ownership -ne "UNKNOWN") {
        $allowedOwnerships = @(switch ($scope) {
            "REPO" { @("AGENT_ZERO_PROJECT", "EXISTING_PROJECT") }
            "USER" { @("EXTERNAL_USER") }
            "ADMIN" { @("EXTERNAL_ADMIN") }
            "SYSTEM" { @("EXTERNAL_SYSTEM") }
            "PLUGIN" { @("EXTERNAL_PLUGIN") }
            "RUNTIME" { @("RUNTIME") }
            default { @() }
        })
        if ($allowedOwnerships.Count -gt 0 -and $ownership -notin $allowedOwnerships) { Add-ValidationError "$id Scope $scope is incompatible with Ownership $ownership." }
    }
    if ($legacyRow) {
        $expectedMutation = if ($ownership -eq "AGENT_ZERO_PROJECT") { "MANAGED" } else { "READ_ONLY" }
        if ($mutation -ne $expectedMutation) { Add-ValidationError "$id Ownership $ownership requires legacy Mutation policy $expectedMutation." }
        if ($invocation -notin @("IMPLICIT", "EXPLICIT_ONLY", "PARENT_CONTROLLED", "UNKNOWN")) { Add-ValidationError "$id has invalid legacy Invocation: $invocation" }
    }
    elseif ($authority -notin @("PROVIDER", "ORCHESTRATOR", "UNKNOWN")) { Add-ValidationError "$id has invalid Authority: $authority" }
    if ($availability -notin @("CANDIDATE", "AVAILABLE", "MISSING", "RETIRED", "UNKNOWN")) { Add-ValidationError "$id has invalid Availability: $availability" }
    if ($sideEffect -notin @("READ_ONLY", "WORKSPACE_WRITE", "EXTERNAL_WRITE", "UNKNOWN")) { Add-ValidationError "$id has invalid Side effect: $sideEffect" }
    if ($delegation -notin @("NONE", "CUSTOM_AGENT", "REQUESTS_DELEGATION", "UNKNOWN")) { Add-ValidationError "$id has invalid Delegation: $delegation" }
    if ([string]::IsNullOrWhiteSpace($displayName)) { Add-ValidationError "$id requires Display name or explicit UNKNOWN." }
    if ($contributionsKnown) { foreach ($contribution in $contributions) { Test-Contribution $contribution $id } }
    Test-SanitizedRef $sourceRef "$id Source ref" -AllowUnknown
    Test-ShaField $observedHash "$id Observed SHA256" -AllowUnknown
    if ($lastSeen -ne "UNKNOWN" -and $lastSeen -notmatch '^\d{4}-\d{2}-\d{2}$') { Add-ValidationError "$id Last seen must be YYYY-MM-DD or UNKNOWN." }
    if ($sourceRef -ne "UNKNOWN") {
        if ($scope -eq "REPO") {
            if ([System.IO.Path]::IsPathRooted($sourceRef) -or $sourceRef -match '(^|[\\/])\.\.([\\/]|$)' -or $sourceRef -match ':') { Add-ValidationError "$id repo Source ref must be project-relative and cannot be a URI or logical external pointer." }
        }
        elseif ($scope -in @("USER", "ADMIN", "SYSTEM", "PLUGIN", "RUNTIME") -and $sourceRef -notmatch ('^' + $scope + ':[A-Za-z0-9._:-]+$')) {
            Add-ValidationError "$id external Source ref must match its Scope as a sanitized logical pointer."
        }
    }
    if ($sourceRef -ne "UNKNOWN") {
        if ($sourceOwners.ContainsKey($sourceRef) -and $sourceOwners[$sourceRef] -ne $ownership) { Add-ValidationError "Source ref is claimed by multiple ownership classes: $sourceRef" }
        else { $sourceOwners[$sourceRef]=$ownership }
    }

    $providers[$id]=[pscustomobject]@{
        Id=$id; CapabilityKeys=[object[]]$capabilityKeys; Kind=$kind; DisplayName=$displayName; Scope=$scope; Ownership=$ownership
        Authority=$authority; Availability=$availability; Contributions=[object[]]$contributions; ContributionsKnown=$contributionsKnown
        SideEffect=$sideEffect; Delegation=$delegation; SourceRef=$sourceRef; Legacy=$legacyRow
    }
}

foreach ($nameGroup in @($providers.Values | Where-Object { $_.DisplayName -ne "UNKNOWN" } | Group-Object { $_.DisplayName.ToLowerInvariant() })) {
    if ($nameGroup.Count -gt 1 -and @($nameGroup.Group | Where-Object { $_.Ownership -eq "AGENT_ZERO_PROJECT" }).Count -gt 0) {
        Add-ValidationError "Agent Zero-managed display name collides with another catalog provider: $($nameGroup.Name)"
    }
}

$routes = @{}
foreach ($line in $routeDataLines) {
    if ($line -notmatch '^\|\s*`(?<id>CR-\d{3,})`\s*\|') { continue }
    $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { Clean-Cell $_ })
    $routeId=$matches['id']
    $expectedRouteCells = if ($canonicalRouteRows) { 15 } else { 12 }
    if ($cells.Count -ne $expectedRouteCells) { Add-ValidationError "Malformed route row $routeId; expected $expectedRouteCells cells for the declared registry schema, found $($cells.Count)."; continue }

    $legacyRoute = -not $canonicalRouteRows
    $id=$cells[0]; $key=$cells[1]; $useCase=$cells[2]; $candidateIds=@(Split-Values $cells[3]); $decision=$cells[4]; $selectedIds=@(Split-Values $cells[5])
    if ($legacyRoute) {
        $requiredContributions=@(); $maxSideEffect="UNKNOWN"; $delegationAllowance="UNKNOWN"; $authority=$cells[7]
        $fallbackEvidence="UNKNOWN"; $evidence=$cells[9]; $accounting=$cells[8]; $reviewTrigger=$cells[10]; $status=$cells[11]
    }
    else {
        $requiredContributions=@(Split-Values $cells[6]); $maxSideEffect=$cells[7]; $delegationAllowance=$cells[8]; $authority=$cells[9]
        $fallbackEvidence=$cells[10]; $evidence=$cells[11]; $accounting=$cells[12]; $reviewTrigger=$cells[13]; $status=$cells[14]
    }

    if ($routes.ContainsKey($id)) { Add-ValidationError "Duplicate immutable Route ID: $id" } else { $routes[$id]=$true }
    Test-CapabilityKey $key $id
    if (@($candidateIds | Sort-Object -Unique).Count -ne $candidateIds.Count) { Add-ValidationError "$id contains duplicate Candidate provider IDs." }
    if (@($selectedIds | Sort-Object -Unique).Count -ne $selectedIds.Count) { Add-ValidationError "$id contains duplicate Selected provider IDs." }
    if ($decision -notin @("BASELINE", "IGNORE", "REUSE", "COMPOSE", "SPECIALIZE", "CONFLICT", "FALLBACK")) { Add-ValidationError "$id has invalid Decision: $decision" }
    if ($authority -notin @("AGENT_WITHIN_SCOPE", "USER_DECISION", "UNRESOLVED")) { Add-ValidationError "$id has invalid Authority: $authority" }
    if ($accounting -ne "INHERIT_PARENT_RUN") { Add-ValidationError "$id must use Parent-run accounting INHERIT_PARENT_RUN." }
    if ($status -notin @("CURRENT", "STALE", "SUPERSEDED")) { Add-ValidationError "$id has invalid Status: $status" }
    if ([string]::IsNullOrWhiteSpace($useCase) -or $useCase -in @("NONE", "UNKNOWN") -or $useCase.Length -gt 256 -or $useCase -match '[\x00-\x1F]') { Add-ValidationError "$id requires a substantive bounded Use case." }
    if ([string]::IsNullOrWhiteSpace($reviewTrigger) -or $reviewTrigger -in @("NONE", "UNKNOWN") -or $reviewTrigger.Length -gt 256 -or $reviewTrigger -match '[\x00-\x1F]') { Add-ValidationError "$id requires a substantive bounded Review trigger." }
    Test-SanitizedRef $evidence "$id Evidence" -AllowNone -AllowUnknown

    foreach ($contribution in $requiredContributions) { Test-Contribution $contribution $id }
    foreach ($providerId in @($candidateIds + $selectedIds | Sort-Object -Unique)) {
        if (-not $providers.ContainsKey($providerId)) { Add-ValidationError "$id references unknown provider: $providerId" }
    }
    foreach ($selectedId in $selectedIds) {
        if ($selectedId -notin $candidateIds) { Add-ValidationError "$id selected provider $selectedId is not a Candidate provider." }
    }
    foreach ($candidateId in $candidateIds) {
        if ($providers.ContainsKey($candidateId) -and $key -notin @($providers[$candidateId].CapabilityKeys)) { Add-ValidationError "$id candidate provider $candidateId does not declare capability $key." }
    }

    if ($decision -eq "REUSE" -and $selectedIds.Count -ne 1) { Add-ValidationError "$id REUSE requires exactly one selected provider." }
    if ($decision -eq "COMPOSE" -and $selectedIds.Count -lt 2) { Add-ValidationError "$id COMPOSE requires at least two selected providers." }
    if ($decision -in @("BASELINE", "IGNORE", "SPECIALIZE", "CONFLICT", "FALLBACK") -and $selectedIds.Count -ne 0) { Add-ValidationError "$id $decision must select NONE." }

    if ($legacyRoute) {
        if ($status -eq "CURRENT" -and $decision -in @("REUSE", "COMPOSE", "SPECIALIZE", "FALLBACK")) {
            Add-ValidationError "$id executable CURRENT route must use canonical route schema with explicit safety and evidence fields."
        }
        continue
    }

    if ($maxSideEffect -notin @("READ_ONLY", "WORKSPACE_WRITE", "EXTERNAL_WRITE")) { Add-ValidationError "$id has invalid Max side effect: $maxSideEffect" }
    if ($delegationAllowance -notin @("DENY", "ALLOW")) { Add-ValidationError "$id has invalid Delegation allowance: $delegationAllowance" }
    Test-SanitizedRef $fallbackEvidence "$id Fallback evidence" -AllowNone -AllowUnknown
    if ($status -eq "CURRENT" -and $evidence -in @("NONE", "UNKNOWN")) { Add-ValidationError "$id CURRENT route requires Evidence." }
    if ($decision -eq "FALLBACK") {
        if ($fallbackEvidence -in @("NONE", "UNKNOWN")) { Add-ValidationError "$id FALLBACK requires evidence-equivalent Fallback evidence." }
    }
    elseif ($fallbackEvidence -ne "NONE") { Add-ValidationError "$id $decision must set Fallback evidence to NONE." }
    if (($maxSideEffect -eq "EXTERNAL_WRITE" -or $delegationAllowance -eq "ALLOW") -and $authority -ne "USER_DECISION") {
        Add-ValidationError "$id external-write or delegation allowance requires USER_DECISION authority."
    }
    if ($decision -in @("REUSE", "COMPOSE", "FALLBACK") -and $authority -eq "UNRESOLVED") { Add-ValidationError "$id executable route cannot have UNRESOLVED authority." }
    if ($decision -in @("SPECIALIZE", "CONFLICT") -and $authority -eq "AGENT_WITHIN_SCOPE") { Add-ValidationError "$id $decision requires USER_DECISION or UNRESOLVED authority." }

    $selectedProviders = [System.Collections.Generic.List[object]]::new()
    foreach ($selectedId in $selectedIds) {
        if (-not $providers.ContainsKey($selectedId)) { continue }
        $provider=$providers[$selectedId]
        $selectedProviders.Add($provider)
        if ($provider.Legacy) { Add-ValidationError "$id cannot execute legacy provider metadata for $selectedId; refresh it to canonical fields." }
        if ($provider.Availability -ne "AVAILABLE") { Add-ValidationError "$id selects provider $selectedId that is not AVAILABLE." }
        if ($provider.Authority -ne "PROVIDER") { Add-ValidationError "$id selects provider $selectedId with unsafe Authority $($provider.Authority)." }
        if ($provider.DisplayName -eq "UNKNOWN" -or $provider.Kind -eq "UNKNOWN" -or $provider.Scope -eq "UNKNOWN" -or $provider.Ownership -eq "UNKNOWN" -or $provider.SourceRef -eq "UNKNOWN" -or -not $provider.ContributionsKnown) {
            Add-ValidationError "$id selects provider $selectedId with UNKNOWN canonical metadata."
        }
        if ($provider.SideEffect -eq "UNKNOWN" -or (Get-SideEffectRank $provider.SideEffect) -gt (Get-SideEffectRank $maxSideEffect)) {
            Add-ValidationError "$id provider $selectedId exceeds Max side effect $maxSideEffect."
        }
        if ($provider.Delegation -eq "UNKNOWN" -or ($provider.Delegation -ne "NONE" -and $delegationAllowance -ne "ALLOW")) {
            Add-ValidationError "$id provider $selectedId delegation is not explicitly allowed."
        }
    }

    if ($decision -in @("REUSE", "COMPOSE")) {
        $combinedContributions = @($selectedProviders | ForEach-Object { @($_.Contributions) } | Sort-Object -Unique)
        foreach ($requiredContribution in $requiredContributions) {
            if ($requiredContribution -notin $combinedContributions) { Add-ValidationError "$id selected providers do not cover required contribution $requiredContribution." }
        }
    }
    if ($decision -eq "COMPOSE") {
        $seenContributions=@{}
        foreach ($provider in $selectedProviders) {
            foreach ($contribution in @($provider.Contributions)) {
                if ($seenContributions.ContainsKey($contribution)) { Add-ValidationError "$id COMPOSE providers overlap on contribution $contribution." }
                else { $seenContributions[$contribution]=$provider.Id }
            }
        }
    }
}

if ($errors.Count -gt 0) {
    $details = ($errors | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    throw "Capability validation failed:$([Environment]::NewLine)$details"
}

Write-Host "Capability validation passed." -ForegroundColor Green
Write-Host "Providers: $($providers.Count)"
Write-Host "Routes: $($routes.Count)"
Write-Host "Registry: $registryFullPath"
