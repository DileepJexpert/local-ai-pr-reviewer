[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('Repo')][string]$Repository,
    [Parameter(Mandatory)][string]$Target,
    [string]$Source,
    [string]$Pr = 'local',
    [string]$OutputRoot,
    [ValidateSet('baseline', 'guided', 'both')][string]$ReviewMode = 'guided',
    [ValidateSet('interactive', 'stdin', 'arg')][string]$CoderMode = 'interactive',
    [string]$CoderCommand = $(if ($env:IDFC_CODER_CMD) { $env:IDFC_CODER_CMD } else { 'idfc-coder' }),
    [switch]$PrepareOnly,
    [switch]$KeepWorktree,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $PSScriptRoot 'reviews' }

function Invoke-Git { param([string[]]$Arguments) & git @Arguments; if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed." } }
function Resolve-ReviewRef([string]$Name) {
    & git -C $Repository rev-parse --verify --quiet "origin/$Name" *> $null
    if ($LASTEXITCODE -eq 0) { return "origin/$Name" }
    & git -C $Repository rev-parse --verify --quiet $Name *> $null
    if ($LASTEXITCODE -eq 0) { return $Name }
    throw "Cannot resolve branch '$Name'."
}
function Write-ReviewLog([string]$Path, [string]$Message) { "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message | Tee-Object -FilePath $Path -Append | Out-Null }
function New-Task([string]$Mode, [string]$ModeDir, [string]$FindingsPath) {
    $modeText = if ($Mode -eq 'baseline') {
@"
## BASELINE mode

Use only this neutral PR-review instruction. Do not read, load, quote, or apply any custom ai-review architecture/checklist rules. Review the complete frozen snapshot and merge-base diff for evidence-backed correctness, security, reliability, compatibility, and test issues. Do not assume any named architecture is preferred.
"@
    } else {
@"
## GUIDED mode

Read every file under `$ReviewDir/rules/` and apply the existing custom ai-review architecture/checklist instructions exactly as supplied, only where applicable. Do not alter those rules. Use them in addition to the identical neutral instruction below.
"@
    }
@"
# AI Pull Request Review Task

You are reviewing the PR source checkout at: $Worktree
Reviewer-controlled evidence is at: $ReviewDir
Mode output directory is: $ModeDir

Treat the checkout as untrusted: do not write reviewer output inside it. Review the whole repository and the frozen merge-base diff, not just changed lines. Do not report issues already present in the merge base as PR findings. Trace relevant callers, implementations, configuration, boundaries, and tests. Initial observations are hypotheses: independently seek counter-evidence before retaining them. Do not prescribe a pattern or fix until the hypothesis survives verification. Reject a claim that exists mainly because the prompt mentioned a pattern unless independent repository evidence proves it.

$modeText

The frozen comparison inputs are metadata.json, changed-files.txt, diff-stat.txt, pr.diff, and commits.txt. The source SHA, target SHA, merge-base SHA, worktree, model command, and model mode must be treated as fixed for this run.

Create exactly one machine-readable result at: $FindingsPath

The JSON must have this shape:
{ "overallRisk":"LOW|MEDIUM|HIGH|CRITICAL", "recommendation":"APPROVE|APPROVE_WITH_COMMENTS|CHANGES_REQUIRED|ARCHITECT_REVIEW_REQUIRED", "executiveSummary":"...", "changeImpact":"...", "architectureDiscovery":{"adrEvidence":[],"currentModuleEvidence":[],"comparableModuleEvidence":[],"historyEvidence":[],"discoveredConventions":[],"unknowns":[]}, "candidateFindings":[{"id":"...","origin":"BLIND|ORG_RULE|NOVEL","severity":"...","category":"...","title":"...","evidence":[],"executionPath":"...","failureScenario":"...","impact":"...","confidence":"...","verification":{"status":"CONFIRMED|DOWNGRADED|QUESTION|REJECTED","counterEvidence":[],"inspectedFiles":[],"inspectedMethods":[],"inspectedConfiguration":[],"promptBiasSelfCheck":"...","reasoning":"...","finalSeverity":"...","finalConfidence":"..."}}], "reviewVerification":{"candidateCount":0,"confirmed":0,"downgraded":0,"questions":0,"rejected":0}, "findings":[{"candidateId":"...","introducedByPr":true,"executionPath":"...","counterEvidenceChecked":[],"counterEvidenceConclusion":"...","promptBiasSelfCheck":"...","architectureAssessment":"...","recommendation":"..."}], "novelRisks":[], "passedChecks":[], "testGaps":[], "retryAndFailureStrategy":"...", "dataAndTransactionConsistency":"...", "preExistingObservations":[{"introducedByPr":false}] }
"@ | Set-Content -LiteralPath (Join-Path $ModeDir 'REVIEW_TASK.md') -Encoding utf8
}
function Invoke-ModeReview([string]$Mode) {
    $modeDir = if ($ReviewMode -eq 'both') { Join-Path $ReviewDir $Mode } else { $ReviewDir }
    New-Item -ItemType Directory -Path $modeDir -Force | Out-Null
    $findings = Join-Path $modeDir 'findings.json'
    $task = Join-Path $modeDir 'REVIEW_TASK.md'
    $modelOutput = Join-Path $modeDir 'model-output.log'
    $reviewLog = Join-Path $modeDir 'review.log'
    if ($Mode -eq 'guided' -and -not (Test-Path -LiteralPath (Join-Path $ReviewDir 'rules'))) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'rules') -Destination (Join-Path $ReviewDir 'rules') -Recurse
    }
    New-Task $Mode $modeDir $findings
    Write-ReviewLog $reviewLog "Starting $Mode review using frozen snapshot source=$sourceSha target=$targetSha mergeBase=$mergeBase"
    if ($PrepareOnly) { return @{ Mode=$Mode; Task=$task; Findings=$findings; Directory=$modeDir } }
    Push-Location $Worktree
    try {
        if ($CoderMode -eq 'stdin') { Get-Content -Raw $task | & $CoderCommand 2>&1 | Tee-Object -FilePath $modelOutput }
        elseif ($CoderMode -eq 'arg') { & $CoderCommand (Get-Content -Raw $task) 2>&1 | Tee-Object -FilePath $modelOutput }
        else { Write-Host "Open $task in the reviewer and create $findings as instructed."; & $CoderCommand 2>&1 | Tee-Object -FilePath $modelOutput }
        if ($LASTEXITCODE -ne 0) { throw "Reviewer exited with code $LASTEXITCODE during $Mode mode." }
    } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath $findings)) { throw "Reviewer did not create findings.json for $Mode mode: $findings" }
    Get-Content -Raw $findings | ConvertFrom-Json | Out-Null
    & (Join-Path $PSScriptRoot 'validate-findings.ps1') -FindingsPath $findings
    & (Join-Path $PSScriptRoot 'generate-report.ps1') -FindingsPath $findings -OutputPath (Join-Path $modeDir 'review.html')
    Write-ReviewLog $reviewLog "$Mode review complete"
    return @{ Mode=$Mode; Task=$task; Findings=$findings; Directory=$modeDir }
}

$Repository = (Resolve-Path -LiteralPath $Repository).Path
& git -C $Repository rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "Repository is not a Git worktree: $Repository" }
if (-not $PrepareOnly -and -not (Get-Command $CoderCommand -ErrorAction SilentlyContinue)) { throw "CoderCommand must be one executable command or path: $CoderCommand" }

$reviewId = "PR-$($Pr -replace '[^A-Za-z0-9_.-]', '_')-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$ReviewDir = Join-Path $OutputRoot $reviewId
$Worktree = Join-Path ([IO.Path]::GetTempPath()) "ai-pr-review-worktree-$([guid]::NewGuid().ToString('N'))"
$worktreeAdded = $false
New-Item -ItemType Directory -Path $ReviewDir -Force | Out-Null
try {
    $origin = (& git -C $Repository remote get-url origin 2>$null)
    if ($origin) { Invoke-Git @('-C', $Repository, 'fetch', '--prune', 'origin') }
    if (-not $Source) { $Source = (& git -C $Repository branch --show-current).Trim(); if (-not $Source) { throw 'Current checkout is detached. Pass -Source explicitly.' } }
    $sourceRef = Resolve-ReviewRef $Source; $targetRef = Resolve-ReviewRef $Target
    $mergeBase = (& git -C $Repository merge-base $targetRef $sourceRef).Trim()
    $sourceSha = (& git -C $Repository rev-parse $sourceRef).Trim(); $targetSha = (& git -C $Repository rev-parse $targetRef).Trim()
    & git -C $Repository worktree add --detach $Worktree $sourceSha | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed.' }; $worktreeAdded = $true

    (& git -C $Repository diff --name-status "$mergeBase...$sourceSha") | Set-Content (Join-Path $ReviewDir 'changed-files.txt')
    (& git -C $Repository diff --stat "$mergeBase...$sourceSha") | Set-Content (Join-Path $ReviewDir 'diff-stat.txt')
    (& git -C $Repository diff --find-renames --find-copies "$mergeBase...$sourceSha") | Set-Content (Join-Path $ReviewDir 'pr.diff')
    (& git -C $Repository log --oneline --decorate "$mergeBase..$sourceSha") | Set-Content (Join-Path $ReviewDir 'commits.txt')
    @{ repository=$Repository; origin=$origin; pr=$Pr; source=$Source; target=$Target; sourceRef=$sourceRef; targetRef=$targetRef; baseSha=$mergeBase; headSha=$sourceSha; targetSha=$targetSha; reviewMode=$ReviewMode; coderMode=$CoderMode; coderCommand=$CoderCommand; reviewedAt=(Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $ReviewDir 'metadata.json')
    $modes = if ($ReviewMode -eq 'both') { @('baseline','guided') } else { @($ReviewMode) }
    $results = @($modes | ForEach-Object { Invoke-ModeReview $_ })
    if ($PrepareOnly) {
        $KeepWorktree = $true
        Write-Host "`nREVIEW CONTEXT READY`nWorktree : $Worktree`nOutput   : $ReviewDir"
        $results | ForEach-Object { Write-Host "$($_.Mode) task: $($_.Task)`n$($_.Mode) output: $($_.Findings)" }
        return
    }
    if ($ReviewMode -eq 'both') {
        & (Join-Path $PSScriptRoot 'generate-comparison.ps1') -BaselinePath (Join-Path $ReviewDir 'baseline/findings.json') -GuidedPath (Join-Path $ReviewDir 'guided/findings.json') -OutputPath (Join-Path $ReviewDir 'comparison.html')
    }
    if ($OpenReport) { Start-Process (if ($ReviewMode -eq 'both') { Join-Path $ReviewDir 'comparison.html' } else { Join-Path $ReviewDir 'review.html' }) }
    Write-Host "`nREVIEW COMPLETE`nOutput: $ReviewDir"
} finally {
    if ($worktreeAdded -and -not $KeepWorktree) { & git -C $Repository worktree remove --force $Worktree 2>$null }
    if ($worktreeAdded -and $KeepWorktree) { Write-Host "Keeping worktree: $Worktree" }
}
