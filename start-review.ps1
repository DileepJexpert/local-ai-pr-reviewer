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
if ($uri.Host -ne 'github.com' -or $uri.AbsolutePath -notmatch '^/[^/]+/[^/]+/compare/') {
    throw 'PrUrl must be a GitHub compare URL, for example https://github.com/owner/repo/compare/main...feature/my-change.'
}

$range = [Uri]::UnescapeDataString(($uri.AbsolutePath -replace '^/[^/]+/[^/]+/compare/', ''))
if ($range.Contains('...')) {
    $parts = $range -split '\.\.\.', 2
    $Target = $parts[0]
    $source = $parts[1]
} else {
    # GitHub accepts /compare/<head>; use the explicitly supplied/default target.
    $source = $range
}
if ([string]::IsNullOrWhiteSpace($source)) { throw 'Could not determine the source branch from PrUrl.' }

$prLabel = "github-$($source -replace '[^A-Za-z0-9_.-]', '_')"
$runner = Join-Path $PSScriptRoot 'review-pr.ps1'
& $runner -Repository $Repository -Source $source -Target $Target -Pr $prLabel `
    -CoderCommand $CoderCommand -CoderMode $CoderMode -ReviewMode $ReviewMode -OutputRoot $OutputRoot `
    -KeepWorktree:$KeepWorktree -OpenReport:$OpenReport
exit $LASTEXITCODE
