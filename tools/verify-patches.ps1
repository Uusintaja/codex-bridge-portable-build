# Verifies patches/ against upstream before dispatching the CI build.
#
# Two stages, each in a throw-away worktree with core.autocrlf disabled:
#   1. fidelity  - apply all patches on merge-base(<Head>, <Ref>) and require
#                  the tree to equal <Head>^{tree}: the patch set faithfully
#                  reproduces the fork chain on its original anchor.
#   2. upstream  - apply all patches on <Ref> and require the tree to equal
#                  `git merge-tree --write-tree <Head> <Ref>`: patching the
#                  current upstream ref yields exactly the intended fork
#                  content on top of it (what the CI build compiles).
#
# NOTE: `git apply` honors core.autocrlf when writing patched files, so every
# apply/add below passes `-c core.autocrlf=false` explicitly, and because the
# patches are zero-context (-U0) every apply passes --unidiff-zero. The
# upstream stage additionally verifies patches/patched-files.txt, the same
# blob-id manifest check the workflow runs.
#
# Usage:
#   pwsh -File tools\verify-patches.ps1
#   pwsh -File tools\verify-patches.ps1 -Ref origin/win -Head win
param(
  [string]$Repo = (Join-Path $PSScriptRoot "..\..\codex-bridge"),
  [string]$Ref = "origin/win",
  [string]$Head = "win",
  [string]$PatchesDir = (Join-Path $PSScriptRoot "..\patches")
)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$PatchesDir = (Resolve-Path -LiteralPath $PatchesDir).Path

$patches = @(Get-ChildItem -LiteralPath $PatchesDir -Filter '*.patch' | Sort-Object Name)
if ($patches.Count -eq 0) { throw "no patch files found in $PatchesDir" }

function Invoke-Git {
  param([string[]]$GitArgs)
  $out = & git @GitArgs
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)" }
  return (@($out) -join "`n")
}

function Test-PatchesOnRef {
  param([string]$OnRef, [string]$ExpectedTree, [string]$Label, [switch]$VerifyManifest)

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cb-patch-verify-' + [Guid]::NewGuid().ToString('N'))
  & git -C $Repo worktree prune
  & git -c core.autocrlf=false -C $Repo worktree add --detach $tmp $OnRef
  if ($LASTEXITCODE -ne 0) { throw "worktree add failed for $OnRef" }

  try {
    foreach ($p in $patches) {
      & git -c core.autocrlf=false -C $tmp apply --unidiff-zero --check $p.FullName
      if ($LASTEXITCODE -ne 0) { throw "patch does not apply on ${OnRef}: $($p.Name)" }
      & git -c core.autocrlf=false -C $tmp apply --unidiff-zero $p.FullName
      if ($LASTEXITCODE -ne 0) { throw "patch apply failed: $($p.Name)" }
    }

    & git -c core.autocrlf=false -C $tmp add -A
    $actual = Invoke-Git @('-C', $tmp, 'write-tree')
    if ($actual -ne $ExpectedTree) {
      Write-Host '--- worktree diff vs expected tree (first 40 lines) ---'
      & git -c core.autocrlf=false -C $tmp diff --stat $ExpectedTree | Select-Object -First 40 | Write-Host
      throw "[$Label] tree mismatch: actual=$actual expected=$ExpectedTree ($OnRef + $($patches.Count) patches)"
    }

    Write-Host "OK [$Label] $OnRef + $($patches.Count) patches -> $actual"

    if ($VerifyManifest) {
      $manifestPath = Join-Path $PatchesDir 'patched-files.txt'
      if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "patch manifest is missing: $manifestPath" }
      $entries = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
      if ($entries.Count -eq 0) { throw "patch manifest is empty: $manifestPath" }
      foreach ($entry in $entries) {
        $parts = $entry -split ' ', 2
        if ($parts.Count -ne 2) { throw "malformed manifest line: $entry" }
        $expected = $parts[0].Trim()
        $relative = $parts[1].Trim()
        $out = @(& git -c core.autocrlf=false -C $tmp hash-object -- $relative)
        if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) { throw "git hash-object failed for $relative" }
        $actualBlob = $out[0].ToString().Trim()
        if ($actualBlob -ne $expected) { throw "manifest mismatch for $relative (expected $expected, actual $actualBlob)" }
      }
      Write-Host "OK [manifest] $($entries.Count) patched files match the recorded blob ids"
    }
  } finally {
    & git -C $Repo worktree remove --force $tmp
    & git -C $Repo worktree prune
  }
}

$base = Invoke-Git @('-C', $Repo, 'merge-base', $Head, $Ref)
if (-not $base) { throw "cannot resolve merge-base of '$Head' and '$Ref'" }
$refSha = Invoke-Git @('-C', $Repo, 'rev-parse', $Ref)
$headTree = Invoke-Git @('-C', $Repo, 'rev-parse', "${Head}^{tree}")
$mergeTree = Invoke-Git @('-C', $Repo, '-c', 'merge.renames=false', 'merge-tree', '--write-tree', $Head, $Ref)
if ($mergeTree -notmatch '^[0-9a-f]{40,64}$') { throw "unexpected merge-tree output: $mergeTree" }

Write-Host "repo : $Repo"
Write-Host "head : $Head ($headTree)"
Write-Host "ref  : $Ref ($refSha)"
Write-Host "base : $base"

Test-PatchesOnRef -OnRef $base -ExpectedTree $headTree -Label 'fidelity'
Test-PatchesOnRef -OnRef $Ref  -ExpectedTree $mergeTree -Label 'upstream' -VerifyManifest

Write-Host 'VERIFY OK'
