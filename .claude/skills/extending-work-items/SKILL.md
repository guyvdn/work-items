---
name: extending-work-items
description: Recipes and conventions for changing work-items.ps1 — adding keybindings/actions, alt-screen pickers, config knobs, status logic, plus testing limits and gotchas. Use when modifying the work-items terminal dashboard.
---

# Extending work-items

`work-items.ps1` is one self-contained PowerShell function rendering a terminal dashboard of your
assigned GitHub issues/PRs. This skill is the playbook for changing it. Read `CLAUDE.md` for the
architecture overview; this file is the **how-to** for common enhancements and the traps to avoid.

## Golden rules (don't break these)

1. **Keep it generic.** No org names, usernames, paths, or company references in the script. Anything
   environment-specific goes in `~/.work-items.json` or `~/.work-items.prompts.json` (in `$HOME`,
   never the repo). Personal mechanisms (e.g. a direnv `.envrc.ps1` for credentials) stay out of the
   script — leave them to the user's own profile.
2. **Theme-adaptive colours only.** Accents use the 16-colour ANSI *slots*; body text uses the
   default foreground; "dim" is the faint attribute. **Never** truecolor (`ESC[38;2;r;g;bm`).
   - `C-Purple` = ANSI blue (34): borders & headers · `C-Pink` = magenta (35): cursor ·
     `C-Yellow` = (33): item IDs · `C-Dim` = faint (`ESC[2m`): stale/secondary text.
3. **Prompts are data.** Claude hand-off wording lives in `~/.work-items.prompts.json` with
   `{Placeholder}` tokens expanded by `Expand-Prompt`. Add a token via the `$vars` hashtable at the
   call site — never inline prompt text.
4. **Parallel blocks:** assign `$x = $using:Var` at the **top** of a `ForEach-Object -Parallel`
   block. `$using:` cannot be referenced inside a nested scriptblock stored in a hashtable.
5. **One source, two delivery paths.** `work-items.ps1` is the only place logic lives. Both the
   clone-and-dot-source path and the PowerShell Gallery module (`module\guyvdn-work-items\`) load that
   *same* file — never duplicate or diverge code into the module wrapper.

## Recipe: add a keybinding / action

An action is wired in five places. Follow the existing `[F]` (filter) or `[N]` (new) as a template:

1. **Nav bar** (`$nav = ...`): add `(C-Purple "[X]") + (C-Dim " Label   ") +`.
2. **Flag init** (just before `[Console]::Write("${ESC}[?1049h")`): add `$myAction = $false` to the
   `$sel = 0; $scroll = 0; ...` line.
3. **Key handler** (the `ReadKey` `if/elseif` chain): `elseif ($key.Key -eq "X") { $myAction = $true; break }`.
4. **Post-loop block** (after the `try/finally` that restores the screen): `if ($myAction) { ... }`.
   - To **hand off and exit** (like `[C]`/`[N]`): do the work, then `return`.
   - To **change state and re-render** (like `[F]`): do the work, then `$doRefresh = $true` (the
     `while ($doRefresh)` loop re-fetches and redraws).
5. **README** keybindings table.

> **Don't "fix" `Start-Claude` back to `Push`/`Pop-Location`.** It uses `Set-Location $REPO_ROOT`
> *on purpose*, so you're left in the repo root afterwards and any directory-entry hook (e.g. a
> direnv-style credential loader in the user's profile) fires before `claude` launches. Restoring the
> previous directory would defeat both.

## Recipe: add an alt-screen picker

Copy `Select-Board` (single-choice) or `Select-Filters` (multi-toggle, multi-group). The skeleton:

- Save cursor visibility, `[Console]::Write("${ESC}[?1049h")` to enter the alt screen, hide cursor.
- Loop: draw a `◆ T I T L E` line (row 0), blank (row 1), `Build-Header`, rows with a pink `▶`
  cursor and `Build-Bottom`, then a nav line; `ReadKey($true)`; handle Up/Down/Home/End/Enter/Escape.
- `finally`: restore cursor visibility and `[Console]::Write("${ESC}[?1049l")` to leave the alt screen.
- **Return an object on apply, `$null` on cancel** — e.g. `[pscustomobject]@{ ... }` vs `$null`.
  Do NOT return a bare array: PowerShell collapses `@()`→`$null` and unwraps single-element arrays,
  so "applied empty" becomes indistinguishable from "cancelled". The object wrapper avoids this.
- For a multi-toggle list, track a `HashSet` and toggle on `Spacebar`.

## Recipe: add a config knob

1. **Seed a default** in the first-run "dirty" block so the saved file documents it:
   `if ($null -eq $cfg.MyKey) { $cfg.MyKey = <default> }`.
2. **Read it** near the other assignments: `$MY = $cfg.MyKey`.
3. **Persist runtime changes** with `$cfg.MyKey = $new; $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8`.
   - `ConvertTo-Json` default depth (2) preserves the existing nested `StatusPriority` object. If you
     introduce deeper nesting, pass `-Depth`.
4. **Document** it in the README config table.

## Status / grouping logic

- Each item's project memberships come from one batched GraphQL query (per-item aliases `i0..iN`,
  chunked and run in parallel). `projectItems` returns **every** board an item is on.
- Two **hide-lists** (blocklists), both persisted and both edited via the single `[F]` picker:
  - `SkipProjects` (numbers) → `$skipProjSet`, rebuilt from config each refresh. Boards in it are
    ignored entirely: their status never groups. Per-item, status = first status from a **non-hidden**
    board. An item on ≥1 board but with **no** visible board (lives only on hidden boards) is hidden
    entirely — tracked via `$onAnyBoard`/`$hasVisibleBoard` so genuinely board-less issues (e.g. PRs
    awaiting review) still show as *No Status* rather than being dropped.
  - `SkipStatuses` (names) → an item whose non-hidden status is listed is hidden.
- Each refresh collects `$seenProjects` (every board number seen, for the `[F]`/`[N]` board lists)
  and `$seenStatuses` (statuses from non-hidden boards only, for the `[F]` status list).
- The `[F]` picker (`Select-Filters`) shows two groups — Projects then Statuses — inverted
  (checked = visible) and returns `@{HideProjects; HideStatuses}`; both sets are saved to config.
  Project rows need titles, so the handler resolves `$seenProjects ∪ SkipProjects` via `Get-Boards`
  before opening the picker.
- **Group order is auto-derived, not configured.** `Get-StatusOrder` queries each visible board's
  *Status* single-select `options` (which come back in board column order, backlog→done) and folds
  them into one name→rank map (`$autoOrder`, first-seen wins so each board's flow is preserved). The
  sort is: `StatusPriority[name]` (optional manual override) ?? `$autoOrder[name]` ?? `100`, with
  *No Status* pinned at `999`. `StatusPriority` defaults to `@{}` — most users never touch it.

## Recipe: cut a Gallery release

The tool is published as the module **`guyvdn-work-items`** from the same `work-items.ps1` that
clone-users dot-source — `module\guyvdn-work-items\` is a thin wrapper (loader + manifest), never a
fork. To release:

1. **Bump `ModuleVersion`** in `module\guyvdn-work-items\guyvdn-work-items.psd1`. Gallery versions are
   immutable — you can't overwrite one. Leave `GUID` untouched.
2. **Dry run:** `.\build\publish.ps1 -WhatIf` stages `out\guyvdn-work-items\` (manifest + loader + a
   copy of `work-items.ps1`) and runs `Test-ModuleManifest`, without publishing. Confirm the staged
   folder is self-contained.
3. **Publish:** `$env:PSGALLERY_KEY = '<key>'; .\build\publish.ps1`. Never commit the key (scope it to
   the `guyvdn-work-items` package on the Gallery).
4. Refresh `ReleaseNotes` in the manifest's `PSData` when the change is user-visible.
5. **Tag + GitHub release** so git history and the Gallery stay aligned. After a successful publish,
   tag the built commit `vX.Y.Z` and mirror it on GitHub (push under the repo-owner account, then
   switch back — see the bottom of this file):
   ```powershell
   git tag -a vX.Y.Z -m "vX.Y.Z" <commit>; git push origin vX.Y.Z
   gh release create vX.Y.Z -R guyvdn/work-items --title vX.Y.Z --notes '<notes>'
   ```

Gotchas:
- `FunctionsToExport` must stay an **explicit** `@('work-items')` (not `'*'`) — that's what makes the
  command autoload, so installers never touch `$PROFILE`.
- The `work-items` name trips an "unapproved verbs" warning on import/publish. Cosmetic — don't rename
  the command to silence it.
- Add a *second* public command? Add it to both `FunctionsToExport` and the psm1's
  `Export-ModuleMember`. Otherwise keep the public surface to the one function.

## Recipe: regenerate the README screenshot

`docs\screenshot.png` is a **mock**, not a capture of the live tool — the real TUI can't be
screenshotted (see headless limits below), and a real capture would leak internal issue titles/org
into a now-public repo. Rebuild it from a small self-contained HTML file rendered headlessly:

- **Layout = a `<pre>` of the same lines the tool draws**, each coloured token wrapped in a `<span>`
  class. Compute every row's trailing pad from the **plain-text** length (excluding the span tags)
  against a fixed `INNER` width, or the `│` right borders won't line up. Build the boxes in JS so the
  padding math is exact rather than hand-counting dashes.
- **Colours map to the tool's ANSI roles, not arbitrary hex** — keep the mock honest. For the Dracula
  mock: borders/headers (`C-Purple` / ANSI blue slot) → `#bd93f9`, item ids (yellow) → `#f1fa8c`,
  cursor (magenta) → `#ff79c6`, dim/stale (faint) → `#6272a4`, fg `#f8f8f2`, bg `#282a36`.
- **Windows Terminal chrome:** a tab strip plus window buttons drawn from the **Segoe MDL2 Assets**
  font (minimise `E921`, maximise `E922`, close `E8BB`, new-tab `E710`, chevron `E70D`). Use a
  **Cascadia Code** font stack on the `<pre>` so the box-drawing glyphs (`╭ ╮ ╰ ╯ │ ◆ ↑ ↓ ↵`) render —
  that font is exactly what makes them render in real Windows Terminal, so the mock doubles as proof
  the glyphs are safe.
- **Use sanitized sample data** (fake issue titles/numbers) — never real boards, same reason as the
  no-real-names golden rule.
- **Rendering:** Playwright blocks `file://`, so serve the folder over localhost
  (`python -m http.server <port>` from `docs\`) and navigate to `http://localhost:<port>/...`
  (cache-bust with `?v=N` between iterations). The PNG saves into the MCP output dir; find it with
  Glob, move it to `docs\screenshot.png`. Only the PNG is committed — delete the scratch HTML after.

## Testing & headless limits

- **Parse check** (safe, fast):
  `[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)` then inspect
  the errors `[ref]`.
- **The TUI and `-Diagnose` cannot run headless.** They call `[Console]::SetCursorPosition`, which
  throws `The handle is invalid` when stdout is redirected (as it is under tool/CI capture). Verify
  logic by **reproducing the data path in isolation** (run the `gh` queries + the transform in a
  small harness) rather than invoking the function.
- **`$HOME` is read-only** — you can't reassign it to fake a home dir in a child shell. To test the
  first-run/config path without touching the real `$HOME`, factor the logic out or accept that a
  headless `work-items` run will write to the real home (back up `~/.work-items*.json` first).
- Always confirm a config-save round-trips: write, `ConvertFrom-Json -AsHashtable`, check that
  `StatusPriority`/`SkipProjects`/`SkipStatuses` survived unchanged.

## Keep contributions clean

- No real names, usernames, org names, or employer references in any committed file (script, README,
  LICENSE, this skill) or in commit messages — the repo is meant to be shareable/public-ready.
- If the repo is hosted under a different account than your active `gh` account, switch accounts
  before pushing, then switch back.
