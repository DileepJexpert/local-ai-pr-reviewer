$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $toolRoot 'generate-comparison.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("review-mode-comparison-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $baseline = @{ overallRisk='LOW'; recommendation='APPROVE'; findings=@(
        @{ severity='MINOR'; confidence='MEDIUM'; category='SECURITY'; title='Shared finding'; file='A.java' },
        @{ severity='MAJOR'; confidence='HIGH'; category='CORRECTNESS'; title='Baseline only'; file='B.java' }
    ) }
    $guided = @{ overallRisk='HIGH'; recommendation='CHANGES_REQUIRED'; findings=@(
        @{ severity='MAJOR'; confidence='HIGH'; category='SECURITY'; title='Shared finding'; file='A.java' },
        @{ severity='MINOR'; confidence='LOW'; category='TESTING'; title='Guided only'; file='C.java' }
    ) }
    $baselinePath = Join-Path $root 'baseline.json'; $guidedPath = Join-Path $root 'guided.json'; $outputPath = Join-Path $root 'comparison.html'
    $baseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $baselinePath
    $guided | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $guidedPath
    & $generator -BaselinePath $baselinePath -GuidedPath $guidedPath -OutputPath $outputPath
    $html = Get-Content -Raw -LiteralPath $outputPath
    foreach ($required in 'Baseline','Guided','Shared finding','Baseline only','Guided only','MINOR / MEDIUM','MAJOR / HIGH') {
        if (-not $html.Contains($required)) { throw "Comparison output is missing: $required" }
    }
    Write-Output 'PASS: review mode comparison fixture'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
