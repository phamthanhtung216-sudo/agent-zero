param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogPath,

    [Parameter(Mandatory = $true)]
    [string]$CapabilityKey,

    [string[]]$RequiredContributions = @(),

    [string]$ExplicitProvider,

    [ValidateSet("READ_ONLY", "WORKSPACE_WRITE", "EXTERNAL_WRITE")]
    [string]$AllowedSideEffect = "READ_ONLY",

    [switch]$AllowDelegation,

    [string]$FallbackEvidence = "NONE",

    [switch]$SpecializationEligible,

    [switch]$AsJson
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Get-StringArray {
    param([object]$Value)

    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-ContainsLiteral {
    param([string[]]$Values, [string]$Expected)

    foreach ($value in @($Values)) {
        if ($value.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-CoversAll {
    param([string[]]$Available, [string[]]$Required)

    foreach ($item in @($Required)) {
        if (-not (Test-ContainsLiteral -Values $Available -Expected $item)) { return $false }
    }
    return $true
}

function Find-DisjointComposition {
    param(
        [object[]]$Providers,
        [string[]]$Required,
        [int]$MaxStates = 20000
    )

    $states = [System.Collections.Generic.List[object]]::new()
    $states.Add([pscustomobject]@{
        NextIndex = 0
        Selected = [object[]]@()
        UsedContributions = @{}
        CoveredRequired = @{}
    })
    $visitedStates = 0
    $overlapObserved = $false
    $maxDepth = [Math]::Min($Providers.Count, $Required.Count)

    for ($depth = 1; $depth -le $maxDepth; $depth++) {
        $nextStates = [System.Collections.Generic.List[object]]::new()
        foreach ($state in $states) {
            for ($index = $state.NextIndex; $index -lt $Providers.Count; $index++) {
                $provider = $Providers[$index]
                $overlap = $false
                foreach ($contribution in @($provider.contributions)) {
                    if ($state.UsedContributions.ContainsKey($contribution)) { $overlap = $true; break }
                }
                if ($overlap) { $overlapObserved = $true; continue }

                $gainsRequired = $false
                foreach ($item in $Required) {
                    if (-not $state.CoveredRequired.ContainsKey($item) -and (Test-ContainsLiteral -Values @($provider.contributions) -Expected $item)) {
                        $gainsRequired = $true
                        break
                    }
                }
                if (-not $gainsRequired) { continue }

                $used = @{}
                foreach ($key in $state.UsedContributions.Keys) { $used[$key] = $true }
                foreach ($contribution in @($provider.contributions)) { $used[$contribution] = $true }
                $covered = @{}
                foreach ($key in $state.CoveredRequired.Keys) { $covered[$key] = $true }
                foreach ($item in $Required) {
                    if (Test-ContainsLiteral -Values @($provider.contributions) -Expected $item) { $covered[$item] = $true }
                }
                $selectedSet = [object[]]@(@($state.Selected) + @($provider))

                $visitedStates++
                if ($visitedStates -gt $MaxStates) {
                    return [pscustomobject]@{ Found=$false; Exhausted=$true; Providers=[object[]]@(); OverlapObserved=$overlapObserved; VisitedStates=$visitedStates }
                }
                if ($covered.Count -eq $Required.Count -and $selectedSet.Count -ge 2) {
                    return [pscustomobject]@{ Found=$true; Exhausted=$false; Providers=$selectedSet; OverlapObserved=$overlapObserved; VisitedStates=$visitedStates }
                }
                if ($depth -lt $maxDepth) {
                    $nextStates.Add([pscustomobject]@{
                        NextIndex = $index + 1
                        Selected = $selectedSet
                        UsedContributions = $used
                        CoveredRequired = $covered
                    })
                }
            }
        }
        $states = $nextStates
        if ($states.Count -eq 0) { break }
    }

    return [pscustomobject]@{ Found=$false; Exhausted=$false; Providers=[object[]]@(); OverlapObserved=$overlapObserved; VisitedStates=$visitedStates }
}

function Get-SideEffectRank {
    param([string]$SideEffect)

    switch ($SideEffect.ToUpperInvariant()) {
        "READ_ONLY" { return 0 }
        "WORKSPACE_WRITE" { return 1 }
        "EXTERNAL_WRITE" { return 2 }
        default { return 3 }
    }
}

function Get-ScopeRank {
    param([string]$Scope)

    switch ($Scope.ToUpperInvariant()) {
        "REPO" { return 0 }
        "USER" { return 1 }
        "PLUGIN" { return 2 }
        "RUNTIME" { return 2 }
        "ADMIN" { return 3 }
        "SYSTEM" { return 4 }
        default { return 5 }
    }
}

function Get-OwnershipRank {
    param([string]$Ownership)

    switch ($Ownership.ToUpperInvariant()) {
        "EXISTING_PROJECT" { return 0 }
        "AGENT_ZERO_PROJECT" { return 1 }
        "EXTERNAL_USER" { return 2 }
        "EXTERNAL_PLUGIN" { return 3 }
        "RUNTIME" { return 3 }
        "EXTERNAL_ADMIN" { return 4 }
        "EXTERNAL_SYSTEM" { return 5 }
        default { return 6 }
    }
}

function Get-ProviderBreadthRank {
    param([object]$Provider, [string[]]$Required)

    if (@($Required).Count -eq 0) { return @($Provider.contributions).Count }
    return @($Provider.contributions | Where-Object { -not (Test-ContainsLiteral -Values $Required -Expected $_) }).Count
}

function Test-SafeReference {
    param([string]$Value, [switch]$AllowNone)

    if ($AllowNone -and $Value -eq "NONE") { return }
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 512) { throw "Evidence/source reference is empty or too long." }
    if ([System.IO.Path]::IsPathRooted($Value) -or
        $Value -match '(?i)(?:[A-Z]:[\\/]+Users[\\/]+|/Users/|/home/|\\\\)' -or
        $Value -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Evidence/source reference must be sanitized and project-relative or logical: $Value"
    }
}

function New-Resolution {
    param(
        [string]$Route,
        [object[]]$Providers,
        [object[]]$Candidates,
        [string]$Reason
    )

    $providerIds = @($Providers | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    $candidateIds = @($Candidates | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        route = $Route
        providers = [object[]]$providerIds
        candidateProviders = [object[]]$candidateIds
        capabilityKey = $CapabilityKey
        requiredContributions = [object[]]$required
        allowedSideEffect = $AllowedSideEffect
        delegationAllowed = [bool]$AllowDelegation
        fallbackEvidence = $FallbackEvidence
        reason = $Reason
        parentRunAccounting = "INHERIT_PARENT_RUN"
    }
}

function New-FallbackOrConflict {
    param([object[]]$Candidates, [string]$Reason)

    if ($hasFallbackEvidence) {
        return New-Resolution -Route "FALLBACK" -Providers @() -Candidates $Candidates -Reason $Reason
    }
    return New-Resolution -Route "CONFLICT" -Providers @() -Candidates $Candidates -Reason ($Reason + "_NO_EQUIVALENT_FALLBACK")
}

function Test-ProviderSafety {
    param([object]$Provider)

    if ($Provider.availability -ne "AVAILABLE") { return [pscustomobject]@{ Safe=$false; Reason="NOT_AVAILABLE" } }
    if ($Provider.displayName -eq "UNKNOWN" -or $Provider.kind -eq "UNKNOWN" -or $Provider.scope -eq "UNKNOWN" -or $Provider.ownership -eq "UNKNOWN" -or $Provider.sourceRef -eq "UNKNOWN") {
        return [pscustomobject]@{ Safe=$false; Reason="UNKNOWN_IDENTITY_METADATA" }
    }
    if ($Provider.authority -ne "PROVIDER") { return [pscustomobject]@{ Safe=$false; Reason="UNSAFE_AUTHORITY" } }
    if ($Provider.sideEffect -eq "UNKNOWN") { return [pscustomobject]@{ Safe=$false; Reason="UNKNOWN_SIDE_EFFECT" } }
    if ((Get-SideEffectRank $Provider.sideEffect) -gt (Get-SideEffectRank $AllowedSideEffect)) {
        return [pscustomobject]@{ Safe=$false; Reason="SIDE_EFFECT_NOT_ALLOWED" }
    }
    if ($Provider.delegation -eq "UNKNOWN") { return [pscustomobject]@{ Safe=$false; Reason="UNKNOWN_DELEGATION" } }
    if ($Provider.delegation -ne "NONE" -and -not $AllowDelegation) {
        return [pscustomobject]@{ Safe=$false; Reason="DELEGATION_NOT_ALLOWED" }
    }
    if (-not $Provider.contributionsKnown) { return [pscustomobject]@{ Safe=$false; Reason="UNKNOWN_CONTRIBUTIONS" } }
    return [pscustomobject]@{ Safe=$true; Reason="SAFE" }
}

if ($CapabilityKey -notmatch '^[a-z0-9]+(?:\.[a-z0-9]+)*$') {
    throw "Capability key must be a lowercase dotted token: $CapabilityKey"
}
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
    throw "Capability catalog does not exist: $CatalogPath"
}

$required = @(Get-StringArray -Value $RequiredContributions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
foreach ($item in $required) {
    if ($item -notmatch '^[a-z0-9]+(?:[._-][a-z0-9]+)*$') { throw "Contribution must be a lowercase token: $item" }
}

$FallbackEvidence = $FallbackEvidence.Trim()
$hasFallbackEvidence = -not [string]::IsNullOrWhiteSpace($FallbackEvidence) -and $FallbackEvidence -notin @("NONE", "UNKNOWN")
if ($hasFallbackEvidence) { Test-SafeReference -Value $FallbackEvidence }
else { $FallbackEvidence = "NONE" }

$catalogText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($CatalogPath))
try { $parsed = ConvertFrom-Json -InputObject $catalogText }
catch { throw "Capability catalog is not valid JSON: $($_.Exception.Message)" }
$catalog = @($parsed)
if ($catalog.Count -eq 1 -and $null -eq $catalog[0]) { $catalog = @() }

$normalized = [System.Collections.Generic.List[object]]::new()
$seenIds = @{}
foreach ($record in $catalog) {
    if ($null -eq $record) { throw "Capability catalog contains a null record." }
    foreach ($field in @("id", "displayName", "kind", "scope", "ownership", "availability", "capabilityKeys", "contributions", "sideEffect", "authority", "delegation", "sourceRef")) {
        if ($null -eq $record.PSObject.Properties[$field]) { throw "Capability catalog record is missing canonical field '$field'." }
    }
    if ($record.capabilityKeys -is [string] -or $record.contributions -is [string]) {
        throw "Capability keys and contributions must be JSON arrays."
    }

    $id = ([string]$record.id).Trim()
    $displayName = ([string]$record.displayName).Trim()
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$') { throw "Capability provider id is invalid: $id" }
    if ($seenIds.ContainsKey($id)) { throw "Capability catalog contains duplicate immutable provider id: $id" }
    $seenIds[$id] = $true
    if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName.Length -gt 128 -or $displayName -match '[\x00-\x1F|]') {
        throw "Capability provider displayName is invalid for $id."
    }

    $availability = ([string]$record.availability).ToUpperInvariant()
    if ($availability -notin @("AVAILABLE", "MISSING", "CANDIDATE", "RETIRED", "UNKNOWN")) { throw "Provider $id has invalid availability: $availability" }
    $authority = ([string]$record.authority).ToUpperInvariant()
    if ($authority -notin @("PROVIDER", "ORCHESTRATOR", "UNKNOWN")) { throw "Provider $id has invalid authority: $authority" }
    $kind = ([string]$record.kind).ToUpperInvariant()
    if ($kind -notin @("SKILL", "CUSTOM_AGENT", "BUILTIN_AGENT", "PLUGIN", "RUNTIME_TOOL", "UNKNOWN")) { throw "Provider $id has invalid kind: $kind" }
    $scope = ([string]$record.scope).ToUpperInvariant()
    if ($scope -notin @("REPO", "USER", "ADMIN", "SYSTEM", "PLUGIN", "RUNTIME", "UNKNOWN")) { throw "Provider $id has invalid scope: $scope" }
    $ownership = ([string]$record.ownership).ToUpperInvariant()
    if ($ownership -notin @("AGENT_ZERO_PROJECT", "EXISTING_PROJECT", "EXTERNAL_USER", "EXTERNAL_ADMIN", "EXTERNAL_SYSTEM", "EXTERNAL_PLUGIN", "RUNTIME", "UNKNOWN")) { throw "Provider $id has invalid ownership: $ownership" }
    $sideEffect = ([string]$record.sideEffect).ToUpperInvariant()
    if ($sideEffect -notin @("READ_ONLY", "WORKSPACE_WRITE", "EXTERNAL_WRITE", "UNKNOWN")) { throw "Provider $id has invalid sideEffect: $sideEffect" }
    $delegation = ([string]$record.delegation).ToUpperInvariant()
    if ($delegation -notin @("NONE", "CUSTOM_AGENT", "REQUESTS_DELEGATION", "UNKNOWN")) { throw "Provider $id has invalid delegation: $delegation" }

    if ($scope -ne "UNKNOWN" -and $ownership -ne "UNKNOWN") {
        $expectedOwnerships = switch ($scope) {
            "REPO" { @("AGENT_ZERO_PROJECT", "EXISTING_PROJECT") }
            "USER" { @("EXTERNAL_USER") }
            "ADMIN" { @("EXTERNAL_ADMIN") }
            "SYSTEM" { @("EXTERNAL_SYSTEM") }
            "PLUGIN" { @("EXTERNAL_PLUGIN") }
            "RUNTIME" { @("RUNTIME") }
        }
        if ($ownership -notin $expectedOwnerships) { throw "Provider $id scope $scope is incompatible with ownership $ownership" }
    }

    $keys = @(Get-StringArray -Value $record.capabilityKeys | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if ($keys.Count -eq 0) { throw "Provider $id requires at least one capability key." }
    foreach ($key in $keys) {
        if ($key -notmatch '^[a-z0-9]+(?:\.[a-z0-9]+)*$') { throw "Provider $id has invalid capability key: $key" }
    }

    $rawContributions = @(Get-StringArray -Value $record.contributions)
    $contributionsKnown = -not ($rawContributions.Count -eq 1 -and $rawContributions[0].Equals("UNKNOWN", [System.StringComparison]::OrdinalIgnoreCase))
    if (-not $contributionsKnown) { $contributions = @() }
    else {
        $contributions = @($rawContributions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
        foreach ($contribution in $contributions) {
            if ($contribution -notmatch '^[a-z0-9]+(?:[._-][a-z0-9]+)*$') { throw "Provider $id has invalid contribution: $contribution" }
        }
    }

    $sourceRef = ([string]$record.sourceRef).Trim()
    if ($sourceRef -ne "UNKNOWN") {
        Test-SafeReference -Value $sourceRef
        if ($scope -eq "REPO") {
            if ($sourceRef -match ':' -or $sourceRef -match '^(USER|ADMIN|SYSTEM|PLUGIN|RUNTIME):') { throw "Provider $id repo sourceRef must be project-relative and cannot be a URI or logical external pointer." }
        }
        elseif ($scope -in @("USER", "ADMIN", "SYSTEM", "PLUGIN", "RUNTIME")) {
            if ($sourceRef -notmatch ('^' + $scope + ':[A-Za-z0-9._:-]+$')) { throw "Provider $id sourceRef is incompatible with scope $scope." }
        }
    }

    $normalized.Add([pscustomobject][ordered]@{
        id = $id
        displayName = $displayName
        kind = $kind
        scope = $scope
        ownership = $ownership
        availability = $availability
        capabilityKeys = [object[]]$keys
        contributions = [object[]]$contributions
        contributionsKnown = $contributionsKnown
        sideEffect = $sideEffect
        authority = $authority
        delegation = $delegation
        sourceRef = $sourceRef
    })
}

if ($normalized.Count -eq 0) {
    $resolution = New-Resolution -Route "BASELINE" -Providers @() -Candidates @() -Reason "EMPTY_CATALOG"
}
else {
    $matching = @($normalized | Where-Object { Test-ContainsLiteral -Values @($_.capabilityKeys) -Expected $CapabilityKey } | Sort-Object id)
    if ($matching.Count -eq 0) {
        $resolution = New-Resolution -Route "IGNORE" -Providers @() -Candidates @() -Reason "NO_RELEVANT_PROVIDER"
    }
    else {
        $available = @($matching | Where-Object { $_.availability -eq "AVAILABLE" })
        $safe = [System.Collections.Generic.List[object]]::new()
        $safetyReasons = [System.Collections.Generic.List[string]]::new()
        foreach ($provider in $available) {
            $safety = Test-ProviderSafety -Provider $provider
            if ($safety.Safe) { $safe.Add($provider) }
            else { $safetyReasons.Add("$($provider.id):$($safety.Reason)") }
        }

        if (-not [string]::IsNullOrWhiteSpace($ExplicitProvider)) {
            $explicit = @($matching | Where-Object { $_.id.Equals($ExplicitProvider, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($explicit.Count -ne 1) {
                $resolution = New-Resolution -Route "CONFLICT" -Providers @() -Candidates $matching -Reason "EXPLICIT_PROVIDER_NOT_RELEVANT"
            }
            elseif ($explicit[0].availability -ne "AVAILABLE") {
                $resolution = New-FallbackOrConflict -Candidates $matching -Reason "EXPLICIT_PROVIDER_UNAVAILABLE"
            }
            else {
                $explicitSafety = Test-ProviderSafety -Provider $explicit[0]
                if (-not $explicitSafety.Safe) {
                    $resolution = New-Resolution -Route "CONFLICT" -Providers @() -Candidates $matching -Reason ("EXPLICIT_PROVIDER_" + $explicitSafety.Reason)
                }
                elseif ($required.Count -gt 0 -and -not (Test-CoversAll -Available @($explicit[0].contributions) -Required $required)) {
                    if ($SpecializationEligible) { $resolution = New-Resolution -Route "SPECIALIZE" -Providers @() -Candidates $matching -Reason "EXPLICIT_PROVIDER_COVERAGE_GAP" }
                    else { $resolution = New-FallbackOrConflict -Candidates $matching -Reason "EXPLICIT_PROVIDER_COVERAGE_GAP" }
                }
                else {
                    $resolution = New-Resolution -Route "REUSE" -Providers @($explicit[0]) -Candidates $matching -Reason "EXPLICIT_PROVIDER_SAFE"
                }
            }
        }
        elseif ($available.Count -eq 0) {
            $resolution = New-FallbackOrConflict -Candidates $matching -Reason "MATCHING_PROVIDER_UNAVAILABLE"
        }
        elseif ($safe.Count -eq 0) {
            $reason = if ($safetyReasons.Count -gt 0) { "NO_SAFE_PROVIDER_" + (($safetyReasons | Sort-Object) -join ',') } else { "NO_SAFE_PROVIDER" }
            $resolution = New-Resolution -Route "CONFLICT" -Providers @() -Candidates $matching -Reason $reason
        }
        else {
            $ranked = @($safe | Sort-Object `
                @{Expression={ Get-SideEffectRank $_.sideEffect }; Ascending=$true}, `
                @{Expression={ if($_.delegation -eq 'NONE'){0}else{1} }; Ascending=$true}, `
                @{Expression={ Get-ProviderBreadthRank -Provider $_ -Required $required }; Ascending=$true}, `
                @{Expression={ Get-ScopeRank $_.scope }; Ascending=$true}, `
                @{Expression={ Get-OwnershipRank $_.ownership }; Ascending=$true}, `
                @{Expression="id"; Ascending=$true})
            $full = @(if ($required.Count -eq 0) { $ranked } else { $ranked | Where-Object { Test-CoversAll -Available @($_.contributions) -Required $required } })
            if ($full.Count -gt 0) {
                $resolution = New-Resolution -Route "REUSE" -Providers @($full[0]) -Candidates $matching -Reason "SINGLE_PROVIDER_COVERS_REQUIREMENT"
            }
            elseif ($required.Count -gt 0) {
                $composition = Find-DisjointComposition -Providers $ranked -Required $required
                if ($composition.Found) {
                    $resolution = New-Resolution -Route "COMPOSE" -Providers @($composition.Providers) -Candidates $matching -Reason "DISJOINT_COMPLEMENTARY_PROVIDER_SET"
                }
                elseif ($composition.Exhausted) {
                    $resolution = New-Resolution -Route "CONFLICT" -Providers @() -Candidates $matching -Reason "COMPOSITION_SEARCH_LIMIT"
                }
                elseif ($SpecializationEligible) {
                    $reason = if ($composition.OverlapObserved) { "OVERLAPPING_CONTRIBUTION_GAP" } else { "REUSABLE_CONTRIBUTION_GAP" }
                    $resolution = New-Resolution -Route "SPECIALIZE" -Providers @() -Candidates $matching -Reason $reason
                }
                else {
                    $reason = if ($composition.OverlapObserved) { "OVERLAPPING_CONTRIBUTIONS" } else { "PROVIDER_COVERAGE_GAP" }
                    $resolution = New-FallbackOrConflict -Candidates $matching -Reason $reason
                }
            }
            else {
                $resolution = New-Resolution -Route "REUSE" -Providers @($ranked[0]) -Candidates $matching -Reason "RELEVANT_PROVIDER_AVAILABLE"
            }
        }
    }
}

if ($AsJson) {
    $resolution | ConvertTo-Json -Depth 6 -Compress
}
else {
    Write-Output "Capability route: $($resolution.route)"
    Write-Output "Capability key: $($resolution.capabilityKey)"
    Write-Output "Providers: $(if (@($resolution.providers).Count -eq 0) { 'NONE' } else { @($resolution.providers) -join '; ' })"
    Write-Output "Reason: $($resolution.reason)"
}
