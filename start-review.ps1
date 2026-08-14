[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$PrUrl,
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
$source = $null
if ($uri.Host -eq 'github.com' -and $uri.AbsolutePath -match '^/[^/]+/[^/]+/compare/(.+)$') {
    $range = [Uri]::UnescapeDataString($Matches[1])
    if ($range.Contains('...')) {
        $parts = $range -split '\.\.\.', 2
        $Target = $parts[0]
        $source = $parts[1]
    } else {
        $source = $range
    }
} elseif ($uri.AbsolutePath -match '/branches/compare/(.+)$') {
    $range = [Uri]::UnescapeDataString($Matches[1])
    if (-not $range.Contains('..')) { throw 'Bitbucket Cloud compare URL must contain source..target.' }
    $parts = $range -split '\.\.', 2
    $source = $parts[0]
    $Target = $parts[1]
} elseif ($uri.AbsolutePath -match '/compare$') {
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $source = $query['sourceBranch']
    $targetFromUrl = $query['targetBranch']
    if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($targetFromUrl)) {
        throw 'Bitbucket Server compare URL needs sourceBranch and targetBranch query parameters.'
    }
    $source = $source -replace '^refs/heads/', ''
    $Target = $targetFromUrl -replace '^refs/heads/', ''
} else {
    throw 'PrUrl must be a GitHub compare URL, Bitbucket Cloud branches/compare URL, or Bitbucket Server compare?sourceBranch=...&targetBranch=... URL.'
}
if ([string]::IsNullOrWhiteSpace($source)) { throw 'Could not determine the source branch from PrUrl.' }

$prLabel = "compare-$($source -replace '[^A-Za-z0-9_.-]', '_')"
$runner = Join-Path $PSScriptRoot 'review-pr.ps1'
& $runner -Repository $Repository -Source $source -Target $Target -Pr $prLabel `
    -CoderCommand $CoderCommand -CoderMode $CoderMode -ReviewMode $ReviewMode -OutputRoot $OutputRoot `
    -KeepWorktree:$KeepWorktree -OpenReport:$OpenReport
exit $LASTEXITCODE
