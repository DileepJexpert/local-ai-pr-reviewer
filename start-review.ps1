[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$PrUrl,
    [string]$Source,
    [string]$Target = 'main',
    [string]$CoderCommand = $(if ($env:IDFC_CODER_CMD) { $env:IDFC_CODER_CMD } else { 'idfc-coder' }),
    [ValidateSet('stdin', 'arg', 'interactive')][string]$CoderMode = 'stdin',
    [ValidateSet('baseline', 'guided', 'both')][string]$ReviewMode = 'guided',
    [string]$OutputRoot,
    [switch]$KeepWorktree,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $PSScriptRoot 'reviews'
}
$uri = [Uri]$PrUrl
$sourceFromUrl = $Source
if (-not [string]::IsNullOrWhiteSpace($sourceFromUrl)) {
    # Explicit source/target works with any URL, including a PR overview page.
} elseif ($uri.Host -eq 'github.com' -and $uri.AbsolutePath -match '^/[^/]+/[^/]+/compare/(.+)$') {
    $range = [Uri]::UnescapeDataString($Matches[1])
    if ($range.Contains('...')) {
        $parts = $range -split '\.\.\.', 2
        $Target = $parts[0]
        $sourceFromUrl = $parts[1]
    } else {
        $sourceFromUrl = $range
    }
} elseif ($uri.AbsolutePath -match '/branches/compare/(.+)$') {
    $range = [Uri]::UnescapeDataString($Matches[1])
    if (-not $range.Contains('..')) { throw 'Bitbucket Cloud compare URL must contain source..target.' }
    $parts = $range -split '\.\.', 2
    $sourceFromUrl = $parts[0]
    $Target = $parts[1]
} elseif ($uri.AbsolutePath -match '/compare$') {
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $sourceFromUrl = $query['sourceBranch']
    $targetFromUrl = $query['targetBranch']
    if ([string]::IsNullOrWhiteSpace($sourceFromUrl) -or [string]::IsNullOrWhiteSpace($targetFromUrl)) {
        throw 'Bitbucket Server compare URL needs sourceBranch and targetBranch query parameters.'
    }
    $sourceFromUrl = $sourceFromUrl -replace '^refs/heads/', ''
    $Target = $targetFromUrl -replace '^refs/heads/', ''
} elseif ($uri.AbsolutePath -match '/projects/[^/]+/repos/[^/]+/pull-requests/(\d+)(?:/|$)') {
    $prId = $Matches[1]
    $fromRef = "refs/remotes/origin/ai-pr-reviewer/pr/$prId/from"
    $toRef = "refs/remotes/origin/ai-pr-reviewer/pr/$prId/to"
    & git -C $Repository fetch origin "+refs/pull-requests/$prId/from:$fromRef" "+refs/pull-requests/$prId/to:$toRef"
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch Bitbucket pull request $prId refs from origin." }
    $sourceFromUrl = (& git -C $Repository rev-parse $fromRef).Trim()
    $Target = (& git -C $Repository rev-parse $toRef).Trim()
} else {
    throw 'Could not determine branches from PrUrl. Pass -Source and -Target, or use a GitHub/Bitbucket compare URL or Bitbucket PR overview URL.'
}
if ([string]::IsNullOrWhiteSpace($sourceFromUrl)) { throw 'Could not determine the source branch from PrUrl.' }

$prLabel = "compare-$($sourceFromUrl -replace '[^A-Za-z0-9_.-]', '_')"
$runner = Join-Path $PSScriptRoot 'review-pr.ps1'
& $runner -Repository $Repository -Source $sourceFromUrl -Target $Target -Pr $prLabel `
    -CoderCommand $CoderCommand -CoderMode $CoderMode -ReviewMode $ReviewMode -OutputRoot $OutputRoot `
    -KeepWorktree:$KeepWorktree -OpenReport:$OpenReport
exit $LASTEXITCODE
