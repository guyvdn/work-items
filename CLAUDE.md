# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A single PowerShell function, `work-items`, defined in `work-items.ps1`. It renders a scrollable,
boxed terminal UI of the GitHub issues and PRs assigned to the current user, grouped by their
project-board status, and can hand work off to an interactive Claude Code session.

The whole tool is `work-items.ps1` — one self-contained function. A thin module wrapper under
`module\guyvdn-work-items\` repackages that exact file for the PowerShell Gallery (see *Packaging &
releases* below); it adds **no logic**. Dependencies are just PowerShell 7, the GitHub CLI (`gh`),
and — for the `[C]`/`[N]` actions only — the `claude` CLI.

## Architecture (one file, top to bottom)

1. **Config load** — reads `~/.work-items.json` (`ConvertFrom-Json -AsHashtable`), prompts on first
   run for `RepoRoot` + `Org`, seeds the optional knobs (`SkipProjects`, `SkipStatuses`,
   `StatusPriority`, `StaleDays`).
2. **Prompts load** — reads `~/.work-items.prompts.json`; missing/blank keys are re-seeded from
   `$defaultPrompts` so upgrades add new prompts without clobbering user edits.
3. **Color + frame helpers** — `C-Purple/C-Pink/C-Yellow` (ANSI slots), `C-Dim` (faint),
   `Build-Header/Build-Item/Build-Bottom`.
4. **Data fetch** — three `gh search` calls run concurrently via `ForEach-Object -Parallel -AsJob`
   (assigned issues, assigned PRs, review-requested PRs), shown behind `Wait-WithSpinner`.
5. **Status lookup** — one `gh api graphql` query per item, batched into chunks with global aliases
   (`i0..iN`) and run in parallel; results merge back by alias.
6. **Build + render** — group by status, sort, pre-build every line, then an interactive scrolling
   viewport on the alternate screen buffer. Group order is fetched live from each visible board's
   *Status* column order (`Get-StatusOrder`, backlog→done); `StatusPriority` in the config is an
   optional manual override on top of that.
7. **Actions** — `[Enter]` opens the URL; `[C]` and `[N]` expand a prompt template and launch Claude
   via `Start-Claude` (which `Set-Location`s to `RepoRoot`, leaving you there afterwards).

## Conventions — keep these intact

- **No environment-specific values in the script.** Anything user/org/path-specific belongs in
  `~/.work-items.json` or `~/.work-items.prompts.json` (both in `$HOME`, both git-ignored by living
  outside the repo). Do not hardcode org names, project numbers, paths, or personal data.
- **Theme-adaptive colours, never truecolor.** Accents use the standard 16-colour ANSI slots
  (`ESC[34m` etc.) so each terminal applies its own scheme; normal text uses the default foreground
  and "dim" is the faint attribute (`ESC[2m`). Do not reintroduce `ESC[38;2;r;g;bm` truecolor.
- **Prompts are data, not code.** Hand-off wording lives in the prompts JSON with `{Placeholder}`
  tokens expanded by `Expand-Prompt`. Add a new token by passing it in the `$vars` hashtable at the
  call site; don't inline prompt text into the script.
- **Parallel blocks** must assign `$x = $using:Var` at the top of the block — `$using:` cannot be
  referenced inside a nested scriptblock stored in a hashtable.

## Testing

No automated tests. Smoke-test manually:

```powershell
# Parse check (no execution):
$null = [System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD\work-items.ps1", [ref]$null, [ref]$null); "OK"

# Load and run:
. .\work-items.ps1
work-items

# Inspect resolved status/skip data without opening the UI:
work-items -Diagnose
```

Requires `gh auth status` to show an authenticated account and a populated `~/.work-items.json`.

## Packaging & releases

The tool ships two ways from the **same** `work-items.ps1`: dot-sourcing a clone, and a PowerShell
Gallery module. Keep that single-source rule — never fork logic into the module.

- **`module\guyvdn-work-items\`** — the committed module source:
  - `guyvdn-work-items.psd1` — manifest. Module id is `guyvdn-work-items` (Gallery uniqueness); the
    one exported command is `work-items` (`FunctionsToExport = @('work-items')`, explicit so it
    autoloads). The `GUID` is fixed — never regenerate it. Bump `ModuleVersion` for each release.
  - `guyvdn-work-items.psm1` — loader only: dot-sources `work-items.ps1` (sibling when staged/
    installed, `..\..` when imported from source) and exports the one function.
- **`build\publish.ps1`** — stages a self-contained package into `out\guyvdn-work-items\` (manifest +
  loader + a copy of `work-items.ps1`), runs `Test-ModuleManifest`, then publishes. `out\` is
  git-ignored. Validate without publishing via `.\build\publish.ps1 -WhatIf`. Publish with
  `$env:PSGALLERY_KEY` set (key from the Gallery account; never commit it).
- **Gallery versions are immutable** — you cannot overwrite a published version. Always bump
  `ModuleVersion` before a real publish.
- **Tag releases to match the Gallery.** After publishing X.Y.Z, tag `vX.Y.Z` at the built commit and
  create a matching GitHub release, so git history and the Gallery version line up (`v0.1.0` was the
  first). The git tag/release push uses the repo-owner account, like any other push here.
- The function name `work-items` isn't `Verb-Noun`, so `Import-Module`/publish emit a cosmetic
  "unapproved verbs" warning. Expected; don't rename the command to silence it.
