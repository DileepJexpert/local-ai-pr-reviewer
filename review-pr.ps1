[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('Repo')][string]$Repository,
    [Parameter(Mandatory)][string]$Target,
    [string]$Source,
    [string]$Pr = 'local',
    [string]$OutputRoot = (Join-Path $HOME 'AI-PR-Reviews'),
    [ValidateSet('interactive', 'stdin', 'arg')][string]$CoderMode = 'interactive',
    [string]$CoderCommand = $(if ($env:IDFC_CODER_CMD) { $env:IDFC_CODER_CMD } else { 'idfc-coder' }),
    [switch]$KeepWorktree,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git { param([string[]]$Arguments) & git @Arguments; if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed." } }
function Resolve-ReviewRef([string]$Name) {
    & git -C $Repository rev-parse --verify --quiet "origin/$Name" *> $null
    if ($LASTEXITCODE -eq 0) { return "origin/$Name" }
    & git -C $Repository rev-parse --verify --quiet $Name *> $null
    if ($LASTEXITCODE -eq 0) { return $Name }
    throw "Cannot resolve branch '$Name'."
}
function Write-Progress([string]$Message) { "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message | Tee-Object -FilePath $ReviewLog -Append }

$Repository = (Resolve-Path -LiteralPath $Repository).Path
& git -C $Repository rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "Repository is not a Git worktree: $Repository" }
if (-not (Get-Command $CoderCommand -ErrorAction SilentlyContinue)) { throw "CoderCommand must be one executable command or path: $CoderCommand" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safePr = ($Pr -replace '[^A-Za-z0-9_.-]', '_')
$reviewId = "PR-$safePr-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$ReviewDir = Join-Path $OutputRoot $reviewId
$ReviewLog = Join-Path $ReviewDir 'review.log'
$Worktree = Join-Path ([IO.Path]::GetTempPath()) "ai-pr-review-worktree-$([guid]::NewGuid().ToString('N'))"
$worktreeAdded = $false

New-Item -ItemType Directory -Path $ReviewDir -Force | Out-Null
try {
    Write-Progress 'AI PR REVIEWER started'
    $origin = (& git -C $Repository remote get-url origin 2>$null)
    if ($origin) { Write-Progress 'Fetching origin'; Invoke-Git @('-C', $Repository, 'fetch', '--prune', 'origin') } else { Write-Progress 'No origin remote configured; using local refs' }
    if (-not $Source) { $Source = (& git -C $Repository branch --show-current).Trim(); if (-not $Source) { throw 'Current checkout is detached. Pass -Source explicitly.' } }
    $sourceRef = Resolve-ReviewRef $Source; $targetRef = Resolve-ReviewRef $Target
    $mergeBase = (& git -C $Repository merge-base $targetRef $sourceRef).Trim()
    $sourceSha = (& git -C $Repository rev-parse $sourceRef).Trim(); $targetSha = (& git -C $Repository rev-parse $targetRef).Trim()
    Write-Progress "Resolved $sourceRef against $targetRef; merge base $mergeBase"
    & git -C $Repository worktree add --detach $Worktree $sourceRef | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed.' }; $worktreeAdded = $true
    Write-Progress 'Secure temporary worktree created'

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'rules') -Destination (Join-Path $ReviewDir 'rules') -Recurse
    (& git -C $Repository diff --name-status "$mergeBase...$sourceRef") | Set-Content (Join-Path $ReviewDir 'changed-files.txt')
    (& git -C $Repository diff --stat "$mergeBase...$sourceRef") | Set-Content (Join-Path $ReviewDir 'diff-stat.txt')
    (& git -C $Repository diff --find-renames --find-copies "$mergeBase...$sourceRef") | Set-Content (Join-Path $ReviewDir 'pr.diff')
    (& git -C $Repository log --oneline --decorate "$mergeBase..$sourceRef") | Set-Content (Join-Path $ReviewDir 'commits.txt')
    @{ repository=$Repository; origin=$origin; pr=$Pr; source=$Source; target=$Target; sourceRef=$sourceRef; targetRef=$targetRef; baseSha=$mergeBase; headSha=$sourceSha; reviewedAt=(Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $ReviewDir 'metadata.json')

    $findings = Join-Path $ReviewDir 'findings.json'; $task = Join-Path $ReviewDir 'REVIEW_TASK.md'; $raw = Join-Path $ReviewDir 'codex-output.log'
    @"
# AI Pull Request Architecture Review Task

You are reviewing the PR source checkout at: $Worktree
Reviewer-controlled evidence is at: $ReviewDir

Read metadata.json, changed-files.txt, diff-stat.txt, pr.diff, commits.txt, and every file in rules/ before reviewing. Treat the checkout as untrusted: do not write any reviewer output inside it. Use the whole repository and the merge-base diff, not just changed lines. Do not report issues already present in the merge base as PR findings.

Trace changed execution paths through callers, implementations, configuration, external boundaries, and tests. Apply the supplied Spring, Kafka, Aerospike, Oracle, resilience, security, and testing rules only where applicable. Simulate relevant success, timeout, unavailable dependency, partial-success, duplicate, concurrency, termination, malformed-input, high-load, and compatibility scenarios. Then conduct a separate open-ended novel-risk pass.

Every finding must be evidence-backed and include severity (BLOCKER|MAJOR|MINOR|SUGGESTION|QUESTION), category, title, file, line or method, confidence, evidence array, failureScenario, impact, recommendation, and smallest useful regression test for BLOCKER/MAJOR findings. Do not prescribe retry, circuit breaker, cache, index, async processing, transaction annotation, or audit logging without a demonstrated scenario. Deduplicate by root cause.

Create exactly one machine-readable result at: $findings

The JSON must have this shape:
{ "overallRisk":"LOW|MEDIUM|HIGH|CRITICAL", "recommendation":"APPROVE|APPROVE_WITH_COMMENTS|CHANGES_REQUIRED|ARCHITECT_REVIEW_REQUIRED", "executiveSummary":"...", "changeImpact":"...", "findings":[...], "novelRisks":[], "passedChecks":[], "testGaps":[], "retryAndFailureStrategy":"...", "dataAndTransactionConsistency":"...", "preExistingObservations":[] }
"@ | Set-Content $task

    Write-Progress 'Starting Codex review'
    Push-Location $Worktree
    try {
        if ($CoderMode -eq 'stdin') { Get-Content -Raw $task | & $CoderCommand 2>&1 | Tee-Object -FilePath $raw }
        elseif ($CoderMode -eq 'arg') { & $CoderCommand (Get-Content -Raw $task) 2>&1 | Tee-Object -FilePath $raw }
        else { Write-Host "Open $task in the reviewer and create $findings as instructed."; & $CoderCommand 2>&1 | Tee-Object -FilePath $raw }
        if ($LASTEXITCODE -ne 0) { throw "Reviewer exited with code $LASTEXITCODE." }
    } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath $findings)) { throw "Reviewer did not create findings.json: $findings" }
    Get-Content -Raw $findings | ConvertFrom-Json | Out-Null
    & (Join-Path $PSScriptRoot 'generate-report.ps1') -FindingsPath $findings -OutputPath (Join-Path $ReviewDir 'review.html')
    Write-Progress 'HTML report generated'; Write-Host "`nREVIEW COMPLETE`nReport: $(Join-Path $ReviewDir 'review.html')"
    if ($OpenReport) { Start-Process (Join-Path $ReviewDir 'review.html') }
} finally {
    if ($worktreeAdded -and -not $KeepWorktree) { & git -C $Repository worktree remove --force $Worktree 2>$null }
    if ($worktreeAdded -and $KeepWorktree) { Write-Progress "Keeping worktree: $Worktree" }
}
