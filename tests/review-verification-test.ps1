$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $toolRoot 'validate-findings.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("review-verification-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    function New-Candidate($id, $status, $counterEvidence) {
        @{ id=$id; origin='BLIND'; severity='MAJOR'; category='CONCURRENCY'; title=$id; evidence=@('initial candidate evidence'); executionPath='Controller -> Service -> Repository'; failureScenario='failure'; impact='impact'; confidence='HIGH'; verification=@{ status=$status; counterEvidence=@($counterEvidence); inspectedFiles=@('Service.java','Repository.java'); inspectedMethods=@('serviceMethod','helper'); inspectedConfiguration=@(); promptBiasSelfCheck='Repository evidence, not prompt wording, motivated this hypothesis.'; reasoning='Verification completed against the relevant execution path.'; finalSeverity='MAJOR'; finalConfidence='HIGH' } }
    }
    function New-Finding($id) {
        @{ candidateId=$id; severity='MAJOR'; category='CONCURRENCY'; title=$id; file='Service.java'; line=10; introducedByPr=$true; confidence='HIGH'; evidence=@('direct evidence'); executionPath='Controller -> Service -> Repository'; failureScenario='failure'; counterEvidenceChecked=@('helper and locking inspected'); counterEvidenceConclusion='No mechanism invalidates this failure.'; promptBiasSelfCheck='Repository execution-path evidence independently proves the failure.'; architectureAssessment='Correctness defect; no architecture drift is asserted.'; impact='impact'; recommendation='recommendation'; regressionTest='concurrent integration test' }
    }
    function New-ArchitectureDiscovery {
        @{ adrEvidence=@('No applicable ADR found'); currentModuleEvidence=@('Current module inspected'); comparableModuleEvidence=@('Comparable module inspected'); historyEvidence=@('Relevant history inspected'); discoveredConventions=@('Repository convention recorded'); unknowns=@() }
    }
    function Assert-Valid($name, $review) {
        $file = Join-Path $root "$name.json"; $review | ConvertTo-Json -Depth 10 | Set-Content $file
        & $validator -FindingsPath $file | Out-Null
    }
    # A: helper synchronizes active; the state-change candidate must be rejected.
    Assert-Valid 'helper-mitigates' @{ overallRisk='LOW'; recommendation='APPROVE'; architectureDiscovery=New-ArchitectureDiscovery; candidateFindings=@(New-Candidate 'STATE-001' 'REJECTED' 'copy/synchronize helper sets active from the parent entity'); reviewVerification=@{candidateCount=1;confirmed=0;downgraded=0;questions=0;rejected=1}; findings=@(); passedChecks=@(); preExistingObservations=@() }
    # B: lock on the parent resource serializes the apparent read/insert pattern.
    Assert-Valid 'pessimistic-lock' @{ overallRisk='LOW'; recommendation='APPROVE'; architectureDiscovery=New-ArchitectureDiscovery; candidateFindings=@(New-Candidate 'CONCURRENCY-001' 'REJECTED' 'PESSIMISTIC_WRITE acquired on the parent resource in the transaction'); reviewVerification=@{candidateCount=1;confirmed=0;downgraded=0;questions=0;rejected=1}; findings=@(); passedChecks=@(); preExistingObservations=@() }
    # C: no lock/upsert/recovery: the candidate survives and is permitted in final PR findings.
    Assert-Valid 'real-race' @{ overallRisk='HIGH'; recommendation='CHANGES_REQUIRED'; architectureDiscovery=New-ArchitectureDiscovery; candidateFindings=@(New-Candidate 'CONCURRENCY-002' 'CONFIRMED' 'No lock, upsert, conflict recovery, or unique constraint was found'); reviewVerification=@{candidateCount=1;confirmed=1;downgraded=0;questions=0;rejected=0}; findings=@(New-Finding 'CONCURRENCY-002'); passedChecks=@(); preExistingObservations=@() }
    # D: pre-existing observation is not a PR finding and cannot require changes.
    Assert-Valid 'pre-existing' @{ overallRisk='LOW'; recommendation='APPROVE'; architectureDiscovery=New-ArchitectureDiscovery; candidateFindings=@(); reviewVerification=@{candidateCount=0;confirmed=0;downgraded=0;questions=0;rejected=0}; findings=@(); passedChecks=@(); preExistingObservations=@(@{title='Existing architecture observation';introducedByPr=$false}) }
    # E: helper was inspected but does not mitigate; confirmed candidate survives.
    Assert-Valid 'helper-does-not-mitigate' @{ overallRisk='HIGH'; recommendation='CHANGES_REQUIRED'; architectureDiscovery=New-ArchitectureDiscovery; candidateFindings=@(New-Candidate 'STATE-002' 'CONFIRMED' 'Helper was inspected but does not write the affected field'); reviewVerification=@{candidateCount=1;confirmed=1;downgraded=0;questions=0;rejected=0}; findings=@(New-Finding 'STATE-002'); passedChecks=@(); preExistingObservations=@() }
    # Guardrail: rejected candidates cannot leak into final findings.
    $invalidCandidate = New-Candidate 'REJECTED-LEAK' 'CONFIRMED' 'locking found'
    $invalidCandidate.recommendation = 'Do not allow this before verification'
    $invalid = @{ overallRisk='HIGH'; recommendation='CHANGES_REQUIRED'; architectureDiscovery=New-ArchitectureDiscovery; candidateFindings=@($invalidCandidate); reviewVerification=@{}; findings=@(New-Finding 'REJECTED-LEAK'); passedChecks=@(); preExistingObservations=@() }
    $invalidPath = Join-Path $root 'invalid.json'; $invalid | ConvertTo-Json -Depth 10 | Set-Content $invalidPath
    $failedAsExpected = $false
    try { & $validator -FindingsPath $invalidPath | Out-Null } catch { $failedAsExpected = $true }
    if (-not $failedAsExpected) { throw 'Recommendation-bearing candidate was not rejected by validator.' }

    # Guardrail: a review cannot skip neutral architecture discovery.
    $missingDiscovery = @{ overallRisk='LOW'; recommendation='APPROVE'; candidateFindings=@(); reviewVerification=@{}; findings=@(); passedChecks=@(); preExistingObservations=@() }
    $missingDiscoveryPath = Join-Path $root 'missing-discovery.json'; $missingDiscovery | ConvertTo-Json -Depth 10 | Set-Content $missingDiscoveryPath
    $failedAsExpected = $false
    try { & $validator -FindingsPath $missingDiscoveryPath | Out-Null } catch { $failedAsExpected = $true }
    if (-not $failedAsExpected) { throw 'Review without neutral architecture discovery was not rejected by validator.' }
    Write-Output 'PASS: review verification regression fixtures'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
