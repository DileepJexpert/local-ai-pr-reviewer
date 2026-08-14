[CmdletBinding()]
param([Parameter(Mandatory)][string]$FindingsPath, [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
function Html([object]$Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }
function ListHtml($Values) { @($Values | ForEach-Object { '<li>' + (Html $_) + '</li>' }) -join '' }

$review = Get-Content -Raw -LiteralPath $FindingsPath | ConvertFrom-Json
$findings = @($review.findings)
$counts = @{}; 'BLOCKER','MAJOR','MINOR','SUGGESTION','QUESTION' | ForEach-Object { $counts[$_] = @($findings | Where-Object severity -eq $_).Count }
$verification = $review.reviewVerification
$verificationHtml = if ($null -eq $verification) { '<p>No structured candidate-verification metadata was supplied.</p>' } else {
  "<div class='counts'><span class='count'>Candidates: $(Html $verification.candidateCount)</span><span class='count'>Confirmed: $(Html $verification.confirmed)</span><span class='count'>Downgraded: $(Html $verification.downgraded)</span><span class='count'>Questions: $(Html $verification.questions)</span><span class='count'>Rejected: $(Html $verification.rejected)</span></div>"
}
$architecture = $review.architectureDiscovery
$architectureHtml = if ($null -eq $architecture) { '<p>No architecture discovery metadata was supplied.</p>' } else {
  "<h3>Discovered conventions</h3><ul>$(ListHtml $architecture.discoveredConventions)</ul><h3>Current-module evidence</h3><ul>$(ListHtml $architecture.currentModuleEvidence)</ul><h3>Comparable-module evidence</h3><ul>$(ListHtml $architecture.comparableModuleEvidence)</ul><h3>ADR and history evidence</h3><ul>$(ListHtml (@($architecture.adrEvidence) + @($architecture.historyEvidence)))</ul><h3>Unknowns</h3><ul>$(ListHtml $architecture.unknowns)</ul>"
}
$cards = foreach($f in $findings) {
  $severity = Html $f.severity
  $introduced = if ($f.introducedByPr -eq $true) { 'YES' } else { 'NO' }
  $evidence = ListHtml $f.evidence; $counterEvidence = ListHtml $f.counterEvidenceChecked
  "<article class='card $severity'><header><span>$severity · $(Html $f.category)</span><small>Confidence: $(Html $f.confidence)</small></header><h3>$(Html $f.title)</h3><p class='location'>$(Html $f.file):$(Html $f.line) · Introduced by PR: <strong>$introduced</strong></p><h4>Evidence</h4><ul>$evidence</ul><h4>Execution path</h4><p>$(Html $f.executionPath)</p><h4>Failure scenario</h4><p>$(Html $f.failureScenario)</p><h4>Counter-evidence checked</h4><ul>$counterEvidence</ul><p><strong>Conclusion:</strong> $(Html $f.counterEvidenceConclusion)</p><h4>Impact</h4><p>$(Html $f.impact)</p><h4>Recommendation</h4><p>$(Html $f.recommendation)</p></article>"
}
$passed = ListHtml $review.passedChecks
$findingAudit = @($findings | ForEach-Object { "<li><strong>$(Html $_.title)</strong>: prompt-bias self-check: $(Html $_.promptBiasSelfCheck) | architecture assessment: $(Html $_.architectureAssessment)</li>" }) -join ''
$preExisting = @($review.preExistingObservations | ForEach-Object { '<li><strong>Introduced by PR: NO</strong> — ' + (Html $_.title) + '</li>' }) -join ''
$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>AI PR Review</title><style>
body{font:15px system-ui;margin:0;color:#172033;background:#f6f8fb}header{background:#101828;color:white;padding:28px}main{max-width:1100px;margin:auto;padding:24px}.summary,.card{background:white;border-radius:10px;padding:20px;margin:16px 0;box-shadow:0 1px 3px #0002}.counts{display:flex;gap:12px;flex-wrap:wrap}.count{padding:10px 14px;border-radius:7px;background:#eef2f6}.card{border-left:7px solid #64748b}.BLOCKER{border-color:#dc2626}.MAJOR{border-color:#f97316}.MINOR{border-color:#eab308}.QUESTION{border-color:#2563eb}.SUGGESTION{border-color:#64748b}.card header{background:none;color:#172033;padding:0;display:flex;justify-content:space-between}.location{color:#64748b}h4{margin-bottom:4px}p,li{line-height:1.5}</style></head><body>
<header><h1>AI PR REVIEW</h1><p>Risk: <strong>$(Html $review.overallRisk)</strong> · Recommendation: <strong>$(Html $review.recommendation)</strong></p></header><main>
<section class='summary'><h2>Executive Summary</h2><p>$(Html $review.executiveSummary)</p><h2>Change Impact</h2><p>$(Html $review.changeImpact)</p><div class='counts'>$(($counts.Keys | Sort-Object | ForEach-Object { "<span class='count'>${_}: $($counts[$_])</span>" }) -join '')</div></section>
<section class='summary'><h2>Neutral Architecture Discovery</h2>$architectureHtml</section>
<section class='summary'><h2>Review Verification</h2>$verificationHtml</section>
<section><h2>PR Findings</h2>$($cards -join "`n")</section><section class='summary'><h2>Pre-existing Architectural Observations</h2><ul>$preExisting</ul></section><section class='summary'><h2>Passed Checks</h2><ul>$passed</ul></section></main></body></html>
"@
Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8
