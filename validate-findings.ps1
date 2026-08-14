[CmdletBinding()]
param([Parameter(Mandatory)][string]$FindingsPath)

$ErrorActionPreference = 'Stop'
$review = Get-Content -Raw -LiteralPath $FindingsPath | ConvertFrom-Json
$errors = [System.Collections.Generic.List[string]]::new()
$candidateById = @{}
$architectureDiscovery = $review.architectureDiscovery
if ($null -eq $architectureDiscovery) {
    $errors.Add('Review has no architectureDiscovery from the neutral discovery phase.')
} else {
    foreach ($property in 'adrEvidence','currentModuleEvidence','comparableModuleEvidence','historyEvidence','discoveredConventions','unknowns') {
        if ($null -eq $architectureDiscovery.PSObject.Properties[$property]) { $errors.Add("architectureDiscovery has no $property.") }
    }
}
foreach ($candidate in @($review.candidateFindings)) {
    if ([string]::IsNullOrWhiteSpace($candidate.id)) { $errors.Add('A candidate finding has no id.'); continue }
    $candidateById[$candidate.id] = $candidate
    if ($candidate.origin -notin 'BLIND','ORG_RULE','NOVEL') { $errors.Add("Candidate $($candidate.id) has invalid or missing origin.") }
    if ([string]::IsNullOrWhiteSpace($candidate.executionPath)) { $errors.Add("Candidate $($candidate.id) has no executionPath.") }
    if ($null -ne $candidate.PSObject.Properties['recommendation']) { $errors.Add("Candidate $($candidate.id) must not contain a recommendation before verification.") }
    $verification = $candidate.verification
    if ($null -eq $verification) { $errors.Add("Candidate $($candidate.id) has no verification result."); continue }
    if ($verification.status -notin 'CONFIRMED','DOWNGRADED','QUESTION','REJECTED') { $errors.Add("Candidate $($candidate.id) has invalid verification status.") }
    if (@($verification.inspectedFiles).Count -eq 0) { $errors.Add("Candidate $($candidate.id) has no inspectedFiles.") }
    if ([string]::IsNullOrWhiteSpace($verification.promptBiasSelfCheck)) { $errors.Add("Candidate $($candidate.id) has no promptBiasSelfCheck.") }
    if ([string]::IsNullOrWhiteSpace($verification.reasoning)) { $errors.Add("Candidate $($candidate.id) has no verification reasoning.") }
}

foreach ($finding in @($review.findings)) {
    if ($finding.candidateId -and -not $candidateById.ContainsKey($finding.candidateId)) { $errors.Add("Final finding $($finding.title) references unknown candidateId $($finding.candidateId).") }
    if ($finding.severity -in 'BLOCKER','MAJOR') {
        if ($finding.introducedByPr -ne $true) { $errors.Add("$($finding.severity) '$($finding.title)' must be introducedByPr=true.") }
        if ([string]::IsNullOrWhiteSpace($finding.executionPath)) { $errors.Add("$($finding.severity) '$($finding.title)' has no executionPath.") }
        if (@($finding.counterEvidenceChecked).Count -eq 0) { $errors.Add("$($finding.severity) '$($finding.title)' has no counterEvidenceChecked.") }
        if ([string]::IsNullOrWhiteSpace($finding.counterEvidenceConclusion)) { $errors.Add("$($finding.severity) '$($finding.title)' has no counterEvidenceConclusion.") }
        if ([string]::IsNullOrWhiteSpace($finding.promptBiasSelfCheck)) { $errors.Add("$($finding.severity) '$($finding.title)' has no promptBiasSelfCheck.") }
        if ([string]::IsNullOrWhiteSpace($finding.architectureAssessment)) { $errors.Add("$($finding.severity) '$($finding.title)' has no architectureAssessment.") }
        if ([string]::IsNullOrWhiteSpace($finding.recommendation)) { $errors.Add("$($finding.severity) '$($finding.title)' has no recommendation after verification.") }
        if ([string]::IsNullOrWhiteSpace($finding.candidateId)) { $errors.Add("$($finding.severity) '$($finding.title)' has no candidateId.") }
        elseif ($candidateById.ContainsKey($finding.candidateId) -and $candidateById[$finding.candidateId].verification.status -notin 'CONFIRMED','DOWNGRADED') { $errors.Add("$($finding.severity) '$($finding.title)' was not confirmed or downgraded.") }
    }
}

foreach ($candidate in $candidateById.Values) {
    if ($candidate.verification.status -eq 'REJECTED' -and @($review.findings | Where-Object candidateId -eq $candidate.id).Count -gt 0) { $errors.Add("Rejected candidate $($candidate.id) appears in final findings.") }
}
if ($errors.Count -gt 0) { throw "Invalid review verification:`n - $($errors -join "`n - ")" }
Write-Output 'Review verification schema: PASS'
