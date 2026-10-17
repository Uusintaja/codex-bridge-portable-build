# codex-bridge-portable-build

Patch-based Windows x64 portable builds for Codex Bridge.

No full fork is maintained: the workflow fetches the requested ref of
[`Fanch-hui/codex-bridge`](https://github.com/Fanch-hui/codex-bridge), applies
the patches in `patches/` in file-name order, and then reuses the upstream
Windows build scripts to compile and package the portable ZIP. The `gitCommit`
field in `BUILD-INFO.json` inside the artifact records the exact upstream
commit that was built.

## Repository layout

| Path | Purpose |
|------|---------|
| `patches/*.patch` | Portable / multi-instance patches: plain `git diff -U0` output, LF, applied in file-name order |
| `patches/patched-files.txt` | Git blob ids of every file the patches change; the workflow verifies them right after applying (drift guard for zero-context patches) |
| `.github/workflows/codex-bridge-portable-build.yml` | Build workflow, ported from upstream `.github/workflows/windows.yml @ 5cb469c2` (Inno Setup installer steps removed) |
| `tools/export-patches.ps1` | Regenerates `patches/` from the local development clone |
| `tools/verify-patches.ps1` | Local verification: two-stage tree equality plus the blob manifest check |

## Usage (web UI)

1. Open **Actions -> codex-bridge-portable-build -> Run workflow**
2. Keep `ref` as `win` (or pass an upstream tag / commit for a pinned build)
3. When the run finishes, download the **codex-bridge-windows-x64** artifact (retained 30 days)

## Patch inventory

| # | Patch | Purpose |
|---|-------|---------|
| 001 | `001-portable-generic-isolation-modern-folder-picker.patch` | Generic portable isolation (`CODEX_BRIDGE_DATA_ROOT` honored everywhere) + modern folder picker (IFileDialog) |
| 002 | `002-fix-swift6-concurrency-for-folder-picker.patch` | Swift 6 concurrency fix for the folder picker (comInitialized flag) |
| 003 | `003-folder-picker-cancel-no-longer-falls-back-to.patch` | Folder picker cancel no longer falls back to the legacy dialog |
| 004 | `004-single-binary-multi-instance-identity-per-data.patch` | Single binary, multiple instances (identity per data root) + WebView2 data under the data root |
| 005 | `005-per-instance-tunnel-runtime-key-helper-restart.patch` | Per-instance tunnel runtime key + helper restart on configuration change |
| 006 | `006-window-instance-scope-for-per-instance-activate.patch` | Window instance scope: activate / close matched per instance |
| 007 | `007-canonical-dsh-desktop-identity-scope-legacy.patch` | Canonical DSH desktop identity scope + legacy data migration |
| 008 | `008-fix-window-scope-match-across-processes-opaque.patch` | Cross-process window scope match fix (opaque identity property; eliminates the second-launch crash) |

## Maintenance

### Re-baselining after upstream changes

1. In the local development clone (`codex-bridge`: `origin` is upstream, branch `win`):
   `git fetch origin win`, then rebase the 8 commits on `win` onto the new `origin/win`
2. `pwsh tools\export-patches.ps1` regenerates `patches/` and the blob manifest
3. `pwsh tools\verify-patches.ps1` must print `VERIFY OK` (fidelity stage, upstream merge-tree stage, manifest check)
4. Commit the `patches/` changes

### Keeping build steps in sync

When upstream changes `windows.yml` or `Scripts\*`, mirror the corresponding steps in
the workflow (step names match upstream for easy side-by-side diffing). Apart from
the installer steps everything should stay line-for-line aligned. Run
`tools\verify-patches.ps1` first to confirm the patches still apply cleanly.

### Conventions

- ASCII only: every file in this repository must stay ASCII. The patch files are
  zero-context diffs (`-U0`) so unmodified upstream lines (which may be non-ASCII)
  never end up in the diffs, and anything added to the source must be ASCII.
- LF everywhere: `.gitattributes` pins `* text=auto eol=lf`; the workflow and the
  verification scripts run `git apply` with `-c core.autocrlf=false` and the
  upstream clone is configured the same way.
- `git apply` runs with `--unidiff-zero` because the patches have no context; the
  pinned upstream ref, the tree checks, and the blob manifest keep that safe.
- This repository replaces the fork's old manual sync flow (`portable-patch/` web
  snapshots + `SYNC-FORK-WEB.md`).
