[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$GuidedPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
function Html([object]$Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }
function Key($Finding) {
    $title = ([string]$Finding.title).Trim().ToLowerInvariant()
    $category = ([string]$Finding.category).Trim().ToLowerInvariant()
    $file = ([string]$Finding.file).Trim().ToLowerInvariant()
    return "$category|$file|$title"
}
function CountText($Review) {
    $counts = @{}; 'BLOCKER','MAJOR','MINOR','SUGGESTION','QUESTION' | ForEach-Object { $counts[$_] = @($Review.findings | Where-Object severity -eq $_).Count }
    return ($counts.Keys | Sort-Object | ForEach-Object { "${_}: $($counts[$_])" }) -join ' | '
}
function FindingRows($Findings) {
    @($Findings | ForEach-Object { "<tr><td>$(Html $_.severity)</td><td>$(Html $_.confidence)</td><td>$(Html $_.category)</td><td>$(Html $_.title)</td><td>$(Html $_.file)</td></tr>" }) -join ''
}

$baseline = Get-Content -Raw -LiteralPath $BaselinePath | ConvertFrom-Json
$guided = Get-Content -Raw -LiteralPath $GuidedPath | ConvertFrom-Json
$baselineByKey = @{}; @($baseline.findings) | ForEach-Object { $baselineByKey[(Key $_)] = $_ }
$guidedByKey = @{}; @($guided.findings) | ForEach-Object { $guidedByKey[(Key $_)] = $_ }
$commonKeys = @($baselineByKey.Keys | Where-Object { $guidedByKey.ContainsKey($_) })
$baselineOnly = @($baselineByKey.Keys | Where-Object { -not $guidedByKey.ContainsKey($_) } | ForEach-Object { $baselineByKey[$_] })
$guidedOnly = @($guidedByKey.Keys | Where-Object { -not $baselineByKey.ContainsKey($_) } | ForEach-Object { $guidedByKey[$_] })
$commonRows = @($commonKeys | ForEach-Object {
    $b = $baselineByKey[$_]; $g = $guidedByKey[$_]
    "<tr><td>$(Html $b.category)</td><td>$(Html $b.title)</td><td>$(Html $b.file)</td><td>$(Html $b.severity) / $(Html $b.confidence)</td><td>$(Html $g.severity) / $(Html $g.confidence)</td></tr>"
}) -join ''

$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>PR Review Comparison</title><style>
body{font:15px system-ui;margin:0;color:#172033;background:#f6f8fb}header{background:#101828;color:white;padding:28px}main{max-width:1200px;margin:auto;padding:24px}.card{background:white;border-radius:10px;padding:20px;margin:16px 0;box-shadow:0 1px 3px #0002}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #d8dee8;vertical-align:top}th{background:#eef2f6}.split{display:grid;grid-template-columns:1fr 1fr;gap:16px}@media(max-width:800px){.split{grid-template-columns:1fr}}
</style></head><body><header><h1>PR REVIEW MODE COMPARISON</h1><p>Both reviews use the same frozen repository snapshot, worktree, diff, model command, and model mode. The only variable is custom ai-review instruction inclusion.</p></header><main>
<section class='split'><article class='card'><h2>Baseline</h2><p>Risk: <strong>$(Html $baseline.overallRisk)</strong><br>Recommendation: <strong>$(Html $baseline.recommendation)</strong><br>Finding counts: $(Html (CountText $baseline))</p></article><article class='card'><h2>Guided</h2><p>Risk: <strong>$(Html $guided.overallRisk)</strong><br>Recommendation: <strong>$(Html $guided.recommendation)</strong><br>Finding counts: $(Html (CountText $guided))</p></article></section>
<section class='card'><h2>Findings common to both reviews</h2><table><tr><th>Category</th><th>Title</th><th>File</th><th>Baseline severity / confidence</th><th>Guided severity / confidence</th></tr>$commonRows</table></section>
<section class='card'><h2>Findings only found by baseline</h2><table><tr><th>Severity</th><th>Confidence</th><th>Category</th><th>Title</th><th>File</th></tr>$(FindingRows $baselineOnly)</table></section>
<section class='card'><h2>Findings only found by guided</h2><table><tr><th>Severity</th><th>Confidence</th><th>Category</th><th>Title</th><th>File</th></tr>$(FindingRows $guidedOnly)</table></section>
</main></body></html>
"@
Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8
