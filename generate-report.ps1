[CmdletBinding()]
param([Parameter(Mandatory)][string]$FindingsPath, [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
function Html([object]$Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }
$review = Get-Content -Raw -LiteralPath $FindingsPath | ConvertFrom-Json
$findings = @($review.findings)
$counts = @{}; 'BLOCKER','MAJOR','MINOR','SUGGESTION','QUESTION' | ForEach-Object { $counts[$_] = @($findings | Where-Object severity -eq $_).Count }
$cards = foreach($f in $findings) {
  $severity = Html $f.severity; $evidence = @($f.evidence | ForEach-Object { '<li>'+ (Html $_) +'</li>' }) -join ''
  "<article class='card $severity'><header><span>$severity</span><small>Confidence: $(Html $f.confidence)</small></header><h3>$(Html $f.title)</h3><p class='location'>$(Html $f.file):$(Html $f.line)</p><h4>Evidence</h4><ul>$evidence</ul><h4>Failure scenario</h4><p>$(Html $f.failureScenario)</p><h4>Impact</h4><p>$(Html $f.impact)</p><h4>Recommendation</h4><p>$(Html $f.recommendation)</p></article>"
}
$passed = @($review.passedChecks | ForEach-Object { '<li>'+ (Html $_) +'</li>' }) -join ''
$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>AI PR Review</title><style>
body{font:15px system-ui;margin:0;color:#172033;background:#f6f8fb}header{background:#101828;color:white;padding:28px}main{max-width:1100px;margin:auto;padding:24px}.summary,.card{background:white;border-radius:10px;padding:20px;margin:16px 0;box-shadow:0 1px 3px #0002}.counts{display:flex;gap:12px;flex-wrap:wrap}.count{padding:10px 14px;border-radius:7px;background:#eef2f6}.card{border-left:7px solid #64748b}.BLOCKER{border-color:#dc2626}.MAJOR{border-color:#f97316}.MINOR{border-color:#eab308}.QUESTION{border-color:#2563eb}.SUGGESTION{border-color:#64748b}.card header{background:none;color:#172033;padding:0;display:flex;justify-content:space-between}.location{color:#64748b}h4{margin-bottom:4px}p,li{line-height:1.5}</style></head><body>
<header><h1>AI PR REVIEW</h1><p>Risk: <strong>$(Html $review.overallRisk)</strong> · Recommendation: <strong>$(Html $review.recommendation)</strong></p></header><main>
<section class='summary'><h2>Executive Summary</h2><p>$(Html $review.executiveSummary)</p><h2>Change Impact</h2><p>$(Html $review.changeImpact)</p><div class='counts'>$(($counts.Keys | Sort-Object | ForEach-Object { "<span class='count'>${_}: $($counts[$_])</span>" }) -join '')</div></section>
<section><h2>Findings</h2>$($cards -join "`n")</section><section class='summary'><h2>Passed Checks</h2><ul>$passed</ul></section></main></body></html>
"@
Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8
