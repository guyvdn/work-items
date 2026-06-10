function work-items {
    param([switch]$Diagnose)
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ESC             = [char]27
    $RESET           = "${ESC}[0m"
    $BOLD            = "${ESC}[1m"
    # --- Per-user configuration. Everything environment-specific (repo location, GitHub org,
    #     project numbers, status names) lives in ~/.work-items.json, NOT in this script, so the
    #     script stays generic. The file is created on first run; edit it to tune the rest. ---
    $configPath = Join-Path $HOME ".work-items.json"
    $cfg = $null
    if (Test-Path $configPath) {
        try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable } catch { }
    }
    if (-not $cfg) { $cfg = @{} }

    # Migrate: the old allow-list 'ProjectNumbers' is superseded by the 'SkipProjects' hide-list.
    $migrated = $false
    if ($cfg.ContainsKey('ProjectNumbers')) { [void]$cfg.Remove('ProjectNumbers'); $migrated = $true }

    # Prompt once for any missing essential (repo root + org), then persist.
    $dirty = $migrated
    if (-not $cfg.RepoRoot) {
        $inRoot = (Read-Host "Path to the folder where your repositories are checked out").Trim().Trim('"')
        if (-not $inRoot)             { Write-Host "  No repository root set; aborting." -ForegroundColor Red; return }
        if (-not (Test-Path $inRoot)) { Write-Host "  '$inRoot' does not exist; aborting." -ForegroundColor Red; return }
        $cfg.RepoRoot = $inRoot; $dirty = $true
    }
    if (-not $cfg.Org) {
        $inOrg = (Read-Host "GitHub organization (owner) to search").Trim()
        if (-not $inOrg) { Write-Host "  No organization set; aborting." -ForegroundColor Red; return }
        $cfg.Org = $inOrg; $dirty = $true
    }
    if ($dirty) {
        # Seed the optional knobs so the saved file documents what can be tuned.
        if ($null -eq $cfg.SkipProjects)   { $cfg.SkipProjects   = @() }   # project numbers to hide (ignore their boards)
        if ($null -eq $cfg.SkipStatuses)   { $cfg.SkipStatuses   = @() }   # statuses to hide
        if ($null -eq $cfg.StatusPriority) { $cfg.StatusPriority = @{} }   # optional override; empty = auto-order from board columns
        if ($null -eq $cfg.StaleDays)      { $cfg.StaleDays      = 7  }    # items older than this are dimmed
        $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
        Write-Host "  Saved $configPath - tune SkipProjects, SkipStatuses and StatusPriority there, or use [F] in the app." -ForegroundColor DarkGray
    }

    $REPO_ROOT     = $cfg.RepoRoot
    $ORG           = $cfg.Org
    $SKIP_PROJECTS = @($cfg.SkipProjects)
    $SKIP_STATUS   = @($cfg.SkipStatuses)
    $statusPriority = if ($cfg.StatusPriority) { $cfg.StatusPriority } else { @{} }
    $cutoff         = (Get-Date).AddDays(-1 * $(if ($cfg.StaleDays) { [int]$cfg.StaleDays } else { 7 }))

    # --- Claude hand-off prompts. Kept in ~/.work-items.prompts.json so devs can tweak the
    #     wording without touching this script. Placeholders in {curly braces} are filled in
    #     at run time: {Number} {Title} {Repo} {Url} {RepoRoot} {Org} {BoardTitle} {BoardNumber}.
    #     Missing/blank entries are re-seeded from these defaults (so upgrades add new keys). ---
    $promptsPath = Join-Path $HOME ".work-items.prompts.json"
    $defaultPrompts = [ordered]@{
        Issue       = "I want to work on GitHub issue #{Number} (`"{Title}`"), filed in the '{Repo}' repository: {Url}. First move the issue to the 'In Progress' status on its project board. Note the code to implement this may live in a DIFFERENT repository than the one the issue is filed in. Read the issue, figure out which repository under {RepoRoot} is the right place to do the work, create a new branch there (follow that repo's branch-naming rules if it defines any), and start working on it."
        PullRequest = "I want to work on GitHub pull request #{Number} (`"{Title}`"), filed in the '{Repo}' repository: {Url}. The matching repository is checked out somewhere under {RepoRoot} - find it, check out this PR's branch, and help me review and address it."
        NewIssue    = "I want to create a new GitHub issue and add it to the '{BoardTitle}' project board (project number {BoardNumber}) in the '{Org}' organization. Ask me - as a normal chat message, not a multiple-choice question - only for a description of the issue, then come up with a clear, concise title for it yourself. Use the board's default repository; do not ask me which repository to use. Create the issue with the gh CLI, assign it to me, add it to that board, and set its status to the board's default status. Confirm the title and details with me before creating anything."
    }
    $PROMPTS = $null
    if (Test-Path $promptsPath) {
        try { $PROMPTS = Get-Content $promptsPath -Raw | ConvertFrom-Json -AsHashtable } catch { }
    }
    if (-not $PROMPTS) { $PROMPTS = @{} }
    $promptsDirty = $false
    foreach ($k in $defaultPrompts.Keys) {
        if (-not $PROMPTS.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$PROMPTS[$k])) {
            $PROMPTS[$k] = $defaultPrompts[$k]; $promptsDirty = $true
        }
    }
    if ($promptsDirty) {
        $ordered = [ordered]@{}
        foreach ($k in $defaultPrompts.Keys) { $ordered[$k] = $PROMPTS[$k] }
        $ordered | ConvertTo-Json | Set-Content $promptsPath -Encoding UTF8
    }

    # Inner box width (content area between the two vertical borders). Adapts to terminal.
    $inner = [Math]::Max(40, [Math]::Min(118, [Console]::WindowWidth - 3))

    # --- Color helpers. Two principles keep this readable on ANY terminal theme (light or
    #     dark): (1) accents use the standard 16-color ANSI slots, which each terminal maps to
    #     its own scheme - the slots are chosen to match the Dracula palette (its "blue" slot is
    #     #bd93f9), so Dracula users see the original look; (2) body text uses NO fixed color -
    #     normal text is the terminal's default foreground and "dim" is the faint attribute, so
    #     both adapt to the background instead of assuming a dark one. ---
    function fg($code, $t) { "${ESC}[${code}m$t$RESET" }
    function C-Purple ($t) { fg 34 $t }            # borders & group headers -> ANSI blue
    function C-Pink   ($t) { fg 35 $t }            # active cursor           -> ANSI magenta
    function C-Yellow ($t) { fg 33 $t }            # item IDs                -> ANSI yellow
    function C-Dim    ($t) { "${ESC}[2m$t$RESET" } # stale items, footer, hints -> faint (relative)

    # --- Frame builders -------------------------------------------------------
    # NOTE: each builder starts its return expression with a parenthesised term so
    # PowerShell parses it as an expression, not a command invocation. Writing
    # `C-Purple ("..") + ..` would call C-Purple with the rest as arguments.
    function Build-Header($label, $count) {
        $text   = "$label ($count)"
        $dashes = [Math]::Max(0, $inner - 4 - $text.Length)
        $line = (C-Purple "`u{256D}`u{2500}`u{2500} ") + (C-Purple "$BOLD$text$RESET") +
                (C-Purple " ") + (C-Purple ("`u{2500}" * $dashes)) + (C-Purple "`u{256E}")
        $line
    }

    function Build-Bottom { (C-Purple ("`u{2570}" + ("`u{2500}" * $inner) + "`u{256F}")) }

    function Build-Item($item, $selected) {
        # Single compact line: "│ {cursor} {id,5}  {title} │"  (prefix = 11 visible cols)
        $cursor = if ($selected) { C-Pink "`u{25B6}" } else { " " }
        $id     = "{0,5}" -f $item.Number
        $titleMax = $inner - 11
        $title  = $item.Title
        if ($title.Length -gt $titleMax) { $title = $title.Substring(0, $titleMax - 1) + "`u{2026}" }
        $titleLen = $title.Length
        if     ($selected)    { $titleC = "$BOLD$title$RESET" } # bold, default foreground
        elseif ($item.Stale)  { $titleC = C-Dim $title }       # faint = theme-relative dim
        else                  { $titleC = $title }             # plain default foreground
        $pad = $inner - 11 - $titleLen
        $line = (C-Purple "`u{2502}") +
                " " + $cursor + "  " + (C-Yellow $id) + "  " + $titleC + (" " * $pad) +
                (C-Purple "`u{2502}")
        $line
    }

    function status-line($msg) { Write-Host "  $msg" -ForegroundColor DarkGray }

    # Animate a spinner on the current line while a background job runs, then return its
    # output. Keeps the load from looking hung; the line is cleared when the job finishes.
    function Wait-WithSpinner($job, $label) {
        $frames = "`u{280B}","`u{2819}","`u{2839}","`u{2838}","`u{283C}","`u{2834}","`u{2826}","`u{2827}","`u{2807}","`u{280F}"
        $i = 0
        while ($job.State -in "NotStarted", "Running") {
            Write-Host ("`r  " + (C-Purple $frames[$i % $frames.Count]) + " $label") -NoNewline
            Start-Sleep -Milliseconds 80
            $i++
        }
        Write-Host ("`r" + (" " * ($label.Length + 6)) + "`r") -NoNewline   # clear the line
        Receive-Job $job -Wait -AutoRemoveJob
    }

    # Resolve a set of project numbers to {Number, Title} boards (one aliased query, so closed/older
    # boards resolve regardless of `gh project list` pagination).
    function Get-Boards($numbers) {
        $nums = @($numbers)
        if ($nums.Count -eq 0) { return @() }
        $frags = $nums | ForEach-Object { "p${_}: projectV2(number: $_) { number title }" }
        $q     = "{ organization(login: `"$ORG`") { " + ($frags -join " ") + " } }"
        $payload = [System.Text.Encoding]::UTF8.GetBytes((@{ query = $q } | ConvertTo-Json -Compress))
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllBytes($tmp, $payload)
            $r = gh api graphql --input $tmp 2>$null | ConvertFrom-Json
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        $org = $r.data.organization
        @(foreach ($n in $nums) {
            $p = $org."p$n"
            if ($p) { [pscustomobject]@{ Number = $p.number; Title = $p.title } }
        })
    }

    # Fetch each board's "Status" single-select options in board (column) order and
    # fold them into one status-name -> rank map. This is how the group order is
    # derived automatically from the boards themselves (no manual list to maintain,
    # works on anyone's project). Boards are merged in the given order, first-seen
    # wins, so each board's own backlog->done flow is preserved; statuses unique to
    # a later board are appended after the earlier boards'.
    function Get-StatusOrder($numbers) {
        $nums = @($numbers)
        if ($nums.Count -eq 0) { return @{} }
        $frags = $nums | ForEach-Object {
            "p${_}: projectV2(number: $_) { field(name: `"Status`") { ... on ProjectV2SingleSelectField { options { name } } } }"
        }
        $q = "{ organization(login: `"$ORG`") { " + ($frags -join " ") + " } }"
        $payload = [System.Text.Encoding]::UTF8.GetBytes((@{ query = $q } | ConvertTo-Json -Compress))
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllBytes($tmp, $payload)
            $r = gh api graphql --input $tmp 2>$null | ConvertFrom-Json
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        $org  = $r.data.organization
        $rank = @{}; $i = 0
        foreach ($n in $nums) {
            $p = $org."p$n"
            if (-not $p) { continue }
            foreach ($opt in @($p.field.options)) {
                if ($opt.name -and -not $rank.ContainsKey($opt.name)) { $rank[$opt.name] = $i; $i++ }
            }
        }
        $rank
    }

    # Fill {placeholder} tokens in a prompt template from a hashtable of values.
    function Expand-Prompt($template, $vars) {
        $out = [string]$template
        foreach ($k in $vars.Keys) { $out = $out.Replace("{$k}", [string]$vars[$k]) }
        $out
    }

    # Launch an interactive Claude session rooted at the configured repo root.
    # Uses Set-Location (not Push/Pop) so you're left in the repo root afterwards,
    # ready to keep working there.
    function Start-Claude($prompt) {
        if (-not (Test-Path $REPO_ROOT)) { Write-Host "  $REPO_ROOT not found." -ForegroundColor Red; return }
        Set-Location $REPO_ROOT
        claude $prompt
    }

    # Arrow-key board picker, styled like the main dashboard (alt screen, boxed, pink cursor).
    # Returns the chosen board object, or $null if cancelled.
    function Select-Board($boards) {
        $sel = 0
        $savedVisible = [Console]::CursorVisible
        [Console]::Write("${ESC}[?1049h")
        [Console]::CursorVisible = $false
        $chosen = $null
        try {
            while ($true) {
                $titleLine = (C-Pink "$BOLD  `u{25C6} $RESET") + (C-Purple "$BOLD`u{2009}N E W   I S S U E$RESET")
                [Console]::SetCursorPosition(0, 0); Write-Host ($titleLine + "${ESC}[K") -NoNewline
                [Console]::SetCursorPosition(0, 1); Write-Host "${ESC}[K" -NoNewline

                [Console]::SetCursorPosition(0, 2)
                Write-Host ((Build-Header "Choose a board" $boards.Count) + "${ESC}[K") -NoNewline
                for ($b = 0; $b -lt $boards.Count; $b++) {
                    $cursor  = if ($b -eq $sel) { C-Pink "`u{25B6}" } else { " " }
                    $name    = $boards[$b].Title
                    $nameMax = $inner - 4
                    if ($name.Length -gt $nameMax) { $name = $name.Substring(0, $nameMax - 1) + "`u{2026}" }
                    $nameC   = if ($b -eq $sel) { "$BOLD$name$RESET" } else { $name }
                    $pad     = $inner - 4 - $name.Length
                    $line    = (C-Purple "`u{2502}") + " " + $cursor + "  " + $nameC + (" " * $pad) + (C-Purple "`u{2502}")
                    [Console]::SetCursorPosition(0, 3 + $b); Write-Host ($line + "${ESC}[K") -NoNewline
                }
                [Console]::SetCursorPosition(0, 3 + $boards.Count)
                Write-Host ((Build-Bottom) + "${ESC}[K") -NoNewline

                $bnav = (C-Purple "[`u{2191}`u{2193}]") + (C-Dim " Navigate   ") +
                        (C-Purple "[`u{21B5}]")          + (C-Dim " Select   ")   +
                        (C-Purple "[Esc]")               + (C-Dim " Cancel")
                [Console]::SetCursorPosition(0, 5 + $boards.Count); Write-Host (" $bnav" + "${ESC}[K") -NoNewline

                $key = [Console]::ReadKey($true)
                if     ($key.Key -eq "UpArrow"   -and $sel -gt 0)                 { $sel-- }
                elseif ($key.Key -eq "DownArrow" -and $sel -lt $boards.Count - 1) { $sel++ }
                elseif ($key.Key -eq "Home")  { $sel = 0 }
                elseif ($key.Key -eq "End")   { $sel = $boards.Count - 1 }
                elseif ($key.Key -eq "Enter") { $chosen = $boards[$sel]; break }
                elseif ($key.Key -eq "Escape" -or $key.Key -eq "Q") { break }
            }
        } finally {
            [Console]::CursorVisible = $savedVisible
            [Console]::Write("${ESC}[?1049l")
        }
        $chosen
    }

    # Combined arrow-key filter, styled like the dashboard: a Projects group on top and a Statuses
    # group below. Opt-in model - a checked [v] row is shown, unchecked is hidden (and dimmed).
    # Internally we track the two hidden sets (persisted as SkipProjects / SkipStatuses).
    #   $projects     = @{Number,Title} board list      $hideProjects = currently-hidden numbers
    #   $statuses     = status-name list                $hideStatuses = currently-hidden names
    # Space toggles, Enter applies (returns @{HideProjects,HideStatuses}), Esc cancels (returns $null).
    function Select-Filters($projects, $hideProjects, $statuses, $hideStatuses) {
        $hideProj = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($p in @($hideProjects)) { [void]$hideProj.Add([int]$p) }
        $hideStat = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($s in @($hideStatuses)) { [void]$hideStat.Add([string]$s) }

        # Flat entry list (projects then statuses) the cursor walks over.
        $entries = @()
        foreach ($p in @($projects)) { $entries += [pscustomobject]@{ Kind = 'project'; Key = [int]$p.Number; Label = [string]$p.Title } }
        foreach ($s in @($statuses)) { $entries += [pscustomobject]@{ Kind = 'status';  Key = [string]$s;     Label = [string]$s } }
        if ($entries.Count -eq 0) { return $null }

        $groups = @(
            [pscustomobject]@{ Name = 'Projects'; Kind = 'project'; Items = @($projects) },
            [pscustomobject]@{ Name = 'Statuses'; Kind = 'status';  Items = @($statuses) }
        )

        $sel = 0
        $savedVisible = [Console]::CursorVisible
        [Console]::Write("${ESC}[?1049h")
        [Console]::CursorVisible = $false
        $applied = $null
        try {
            while ($true) {
                $titleLine = (C-Pink "$BOLD  `u{25C6} $RESET") + (C-Purple "$BOLD`u{2009}F I L T E R$RESET")
                [Console]::SetCursorPosition(0, 0); Write-Host ($titleLine + "${ESC}[K") -NoNewline
                [Console]::SetCursorPosition(0, 1); Write-Host "${ESC}[K" -NoNewline

                $y = 2; $idx = 0
                foreach ($grp in $groups) {
                    if ($grp.Items.Count -eq 0) { continue }
                    $isProj = $grp.Kind -eq 'project'
                    $vis = 0
                    foreach ($it in $grp.Items) {
                        $hidden = if ($isProj) { $hideProj.Contains([int]$it.Number) } else { $hideStat.Contains([string]$it) }
                        if (-not $hidden) { $vis++ }
                    }
                    [Console]::SetCursorPosition(0, $y); Write-Host ((Build-Header $grp.Name $vis) + "${ESC}[K") -NoNewline; $y++
                    foreach ($it in $grp.Items) {
                        if ($isProj) { $isVisible = -not $hideProj.Contains([int]$it.Number); $name = [string]$it.Title }
                        else         { $isVisible = -not $hideStat.Contains([string]$it);     $name = [string]$it }
                        $cursor = if ($idx -eq $sel) { C-Pink "`u{25B6}" } else { " " }
                        $box    = if ($isVisible) { "[`u{2713}]" } else { "[ ]" }
                        $label  = "$box $name"
                        $labelMax = $inner - 4
                        if ($label.Length -gt $labelMax) { $label = $label.Substring(0, $labelMax - 1) + "`u{2026}" }
                        if    ($idx -eq $sel)    { $labelC = "$BOLD$label$RESET" }
                        elseif (-not $isVisible) { $labelC = C-Dim $label }
                        else                     { $labelC = $label }
                        $pad  = $inner - 4 - $label.Length
                        $line = (C-Purple "`u{2502}") + " " + $cursor + "  " + $labelC + (" " * $pad) + (C-Purple "`u{2502}")
                        [Console]::SetCursorPosition(0, $y); Write-Host ($line + "${ESC}[K") -NoNewline
                        $y++; $idx++
                    }
                    [Console]::SetCursorPosition(0, $y); Write-Host ((Build-Bottom) + "${ESC}[K") -NoNewline; $y++
                    [Console]::SetCursorPosition(0, $y); Write-Host "${ESC}[K" -NoNewline; $y++   # blank spacer
                }

                $bnav = (C-Purple "[`u{2191}`u{2193}]") + (C-Dim " Navigate   ") +
                        (C-Purple "[Space]")            + (C-Dim " Show / hide   ") +
                        (C-Purple "[`u{21B5}]")         + (C-Dim " Apply   ") +
                        (C-Purple "[Esc]")              + (C-Dim " Cancel")
                [Console]::SetCursorPosition(0, $y); Write-Host (" $bnav" + "${ESC}[K") -NoNewline

                $key = [Console]::ReadKey($true)
                if     ($key.Key -eq "UpArrow"   -and $sel -gt 0)                  { $sel-- }
                elseif ($key.Key -eq "DownArrow" -and $sel -lt $entries.Count - 1) { $sel++ }
                elseif ($key.Key -eq "Home")     { $sel = 0 }
                elseif ($key.Key -eq "End")      { $sel = $entries.Count - 1 }
                elseif ($key.Key -eq "Spacebar") {
                    $e = $entries[$sel]
                    if ($e.Kind -eq 'project') {
                        if ($hideProj.Contains([int]$e.Key)) { [void]$hideProj.Remove([int]$e.Key) } else { [void]$hideProj.Add([int]$e.Key) }
                    } else {
                        if ($hideStat.Contains([string]$e.Key)) { [void]$hideStat.Remove([string]$e.Key) } else { [void]$hideStat.Add([string]$e.Key) }
                    }
                }
                elseif ($key.Key -eq "Enter")  { $applied = [pscustomobject]@{ HideProjects = @($hideProj); HideStatuses = @($hideStat) }; break }
                elseif ($key.Key -eq "Escape") { break }
            }
        } finally {
            [Console]::CursorVisible = $savedVisible
            [Console]::Write("${ESC}[?1049l")
        }
        $applied
    }

    $doRefresh = $true
    while ($doRefresh) {
        $doRefresh = $false
        $tableRow  = [Console]::CursorTop

        # --- Fetch assigned issues + PRs. The three searches are independent, so run them
        #     concurrently (each in its own runspace) as a background job and spin while we wait. ---
        $searchJob = @("issues", "aprs", "rprs") | ForEach-Object -Parallel {
            $org    = $using:ORG
            $fields = "title,url,repository,number,updatedAt"
            switch ($_) {
                "issues" { $out = gh search issues --assignee="@me"        --owner=$org --state=open --json $fields --limit 100 }
                "aprs"   { $out = gh search prs    --assignee="@me"        --owner=$org --state=open --json $fields --limit 100 }
                "rprs"   { $out = gh search prs    --review-requested="@me" --owner=$org --state=open --json $fields --limit 100 }
            }
            [pscustomobject]@{ Key = $_; Json = ($out -join "`n") }
        } -ThrottleLimit 3 -AsJob
        $searchOut = Wait-WithSpinner $searchJob "Fetching issues and PRs..."

        $byKey = @{}; foreach ($s in $searchOut) { $byKey[$s.Key] = $s.Json }
        $issues      = $byKey["issues"] | ConvertFrom-Json
        $assignedPrs = $byKey["aprs"]   | ConvertFrom-Json
        $reviewPrs   = $byKey["rprs"]   | ConvertFrom-Json

        # PRs awaiting our review are other people's PRs: their project status isn't ours to
        # act on, so exempt them from the status-skip filter. An open review request always
        # matters; once the PR is merged/closed it drops out via --state=open above.
        $reviewUrls = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in @($reviewPrs)) { [void]$reviewUrls.Add($p.url) }

        # Merge assigned + review-requested PRs, de-duplicated by URL.
        $seenPr = [System.Collections.Generic.HashSet[string]]::new()
        $prs    = @()
        foreach ($p in (@($assignedPrs) + @($reviewPrs))) { if ($seenPr.Add($p.url)) { $prs += $p } }

        # --- Query each item's project status, chunked and run concurrently. ---
        $skipUrls     = [System.Collections.Generic.HashSet[string]]::new()
        $urlStatus    = @{}
        $seenStatuses = [System.Collections.Generic.HashSet[string]]::new()   # statuses seen on non-hidden boards, for [F]
        $seenProjects = [System.Collections.Generic.HashSet[int]]::new()      # project numbers seen on items, for [F]/[N]
        # Boards to ignore entirely. Rebuilt each refresh so [F] edits to SkipProjects take effect on re-render.
        $skipProjSet  = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($n in $SKIP_PROJECTS) { [void]$skipProjSet.Add([int]$n) }

        $allUrls = @(($issues + $prs) | Select-Object -ExpandProperty url -Unique)
        if ($allUrls.Count -gt 0) {
            $fragments = for ($i = 0; $i -lt $allUrls.Count; $i++) {
                $u = $allUrls[$i]
"  i${i}: resource(url: `"$u`") {
    ... on Issue {
      projectItems(first: 10) { nodes { project { number } fieldValues(first: 10) { nodes {
        ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } }
      } } } }
    }
    ... on PullRequest {
      projectItems(first: 10) { nodes { project { number } fieldValues(first: 10) { nodes {
        ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } }
      } } } }
    }
  }"
            }
            # Split the fragments into chunks fetched concurrently; GitHub processes the
            # chunks in parallel, roughly halving this round-trip. Each fragment keeps its
            # global alias (i0..iN), so the chunk responses merge back without re-indexing.
            $chunkSize = 15
            $chunks = for ($s = 0; $s -lt $fragments.Count; $s += $chunkSize) {
                , @($fragments[$s..([Math]::Min($s + $chunkSize - 1, $fragments.Count - 1))])
            }
            $statusJob = $chunks | ForEach-Object -Parallel {
                $query   = "{ " + ($_ -join "`n") + " }"
                $payload = [System.Text.Encoding]::UTF8.GetBytes((@{ query = $query } | ConvertTo-Json -Compress))
                $tmp     = [System.IO.Path]::GetTempFileName()
                try {
                    [System.IO.File]::WriteAllBytes($tmp, $payload)
                    gh api graphql --input $tmp 2>$null
                } finally {
                    Remove-Item $tmp -ErrorAction SilentlyContinue
                }
            } -ThrottleLimit 4 -AsJob
            $responses = Wait-WithSpinner $statusJob "Checking project status..."

            # Merge every chunk's data.* aliases into one lookup keyed by alias name.
            $data = @{}
            foreach ($resp in $responses) {
                if (-not $resp) { continue }
                try { $parsed = $resp | ConvertFrom-Json } catch { continue }
                if ($parsed.data) {
                    foreach ($p in $parsed.data.PSObject.Properties) { $data[$p.Name] = $p.Value }
                }
            }

            # Every board considered by default; boards in SkipProjects are ignored entirely (their
            # status never drives grouping and never hides the item). Status comes from the first
            # non-hidden board. Collect seen projects (for the [F]/[N] board lists) and seen statuses
            # (for the [F] status list, gathered only from non-hidden boards).
            for ($i = 0; $i -lt $allUrls.Count; $i++) {
                $url      = $allUrls[$i]
                $resource = $data["i$i"]
                if (-not $resource) { continue }
                $skip = $false; $firstStatus = $null
                $onAnyBoard = $false; $hasVisibleBoard = $false
                foreach ($node in @($resource.projectItems.nodes)) {
                    $onAnyBoard = $true
                    $pnum = [int]$node.project.number
                    if ($pnum) { [void]$seenProjects.Add($pnum) }
                    if ($skipProjSet.Contains($pnum)) { continue }   # ignore hidden boards
                    $hasVisibleBoard = $true
                    $s = ($node.fieldValues.nodes |
                        Where-Object { $_.field.name -eq "Status" } |
                        Select-Object -First 1).name
                    if ($s) { [void]$seenStatuses.Add([string]$s) }
                    if ($SKIP_STATUS -contains $s) { $skip = $true; break }
                    if ($s -and -not $firstStatus) { $firstStatus = $s }
                }
                if ($skip)              { [void]$skipUrls.Add($url) }
                elseif ($firstStatus)   { $urlStatus[$url] = $firstStatus }
                # On boards, but every one is hidden (SkipProjects): the item is
                # exclusive to boards you don't care about, so hide it entirely
                # rather than leaking it through as "No Status". Genuinely
                # board-less issues ($onAnyBoard = false) still show as No Status.
                elseif ($onAnyBoard -and -not $hasVisibleBoard) { [void]$skipUrls.Add($url) }
            }
        }

        # Derive the status group order from the visible boards' columns (backlog->done).
        $visibleBoards = @($seenProjects | Where-Object { -not $skipProjSet.Contains([int]$_) } | Sort-Object)
        $autoOrder = Get-StatusOrder $visibleBoards

        # --- Diagnose: dump raw data and exit ---
        if ($Diagnose) {
            [Console]::SetCursorPosition(0, $tableRow)
            [Console]::Write("${ESC}[J")
            Write-Host ""
            Write-Host ("  Projects seen on items:   " + (@($seenProjects | Sort-Object) -join ", ")) -ForegroundColor Cyan
            Write-Host ("  Hidden projects (Skip):   " + (@($SKIP_PROJECTS | Sort-Object) -join ", ")) -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Group order (from board columns):" -ForegroundColor Cyan
            $autoOrder.GetEnumerator() | Sort-Object Value | ForEach-Object {
                $ov = if ($null -ne $statusPriority[$_.Key]) { " (override $($statusPriority[$_.Key]))" } else { "" }
                Write-Host ("  {0,2}. {1}{2}" -f $_.Value, $_.Key, $ov) -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  Status map ($($urlStatus.Count) items):" -ForegroundColor Cyan
            $urlStatus.GetEnumerator() | Sort-Object Value, Key | ForEach-Object {
                Write-Host ("  [{0,-30}] {1}" -f $_.Value, $_.Key) -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  Skipped ($($skipUrls.Count) items):" -ForegroundColor DarkGray
            $skipUrls | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            Write-Host ""
            return
        }

        # --- Build issue and PR lists ---
        $rawIssues = @()
        $rawPRs    = @()
        foreach ($issue in $issues) {
            if ($skipUrls.Contains($issue.url)) { continue }
            $upd = [datetime]$issue.updatedAt
            $st  = if ($urlStatus.ContainsKey($issue.url)) { $urlStatus[$issue.url] } else { "No Status" }
            $rawIssues += [PSCustomObject]@{ Number=$issue.number; Title=$issue.title; Repo=$issue.repository.name; Url=$issue.url; Updated=$upd; Stale=($upd -lt $cutoff); Status=$st }
        }
        foreach ($pr in $prs) {
            if ($skipUrls.Contains($pr.url) -and -not $reviewUrls.Contains($pr.url)) { continue }
            $upd = [datetime]$pr.updatedAt
            $rawPRs += [PSCustomObject]@{ Number=$pr.number; Title=$pr.title; Repo=$pr.repository.name; Url=$pr.url; Updated=$upd; Stale=($upd -lt $cutoff) }
        }

        # --- Group issues by status, PRs as a final group ---
        # Order: a manual StatusPriority entry wins (optional override); otherwise the
        # board-derived column order; otherwise unranked statuses sit just above
        # "No Status", which is always last.
        $issueGroups = $rawIssues | Group-Object Status | Sort-Object {
            $p = $statusPriority[$_.Name]
            if ($null -eq $p) { $p = $autoOrder[$_.Name] }
            if ($null -ne $p) { $p } elseif ($_.Name -eq "No Status") { 999 } else { 100 }
        }, Name

        # --- Pre-build every frame line; record each item's primary-line index ---
        $all                = [System.Collections.Generic.List[object]]::new()
        $lines              = [System.Collections.Generic.List[string]]::new()
        $itemPrimaryLineIdx = [System.Collections.Generic.List[int]]::new()

        function Add-Group($label, $items) {
            if ($lines.Count -gt 0) { [void]$lines.Add("") }   # blank spacer between groups
            [void]$lines.Add((Build-Header $label $items.Count))
            foreach ($item in $items) {
                [void]$itemPrimaryLineIdx.Add($lines.Count)
                [void]$lines.Add((Build-Item $item $false))
                [void]$all.Add($item)
            }
            [void]$lines.Add((Build-Bottom))
        }

        foreach ($group in $issueGroups) {
            Add-Group $group.Name @($group.Group | Sort-Object Updated -Descending)
        }
        if ($rawPRs.Count -gt 0) {
            Add-Group "Pull Requests" @($rawPRs | Sort-Object Updated -Descending)
        }

        # --- Clear loading messages on the normal buffer ---
        [Console]::SetCursorPosition(0, $tableRow)
        [Console]::Write("${ESC}[J")
        if ($all.Count -eq 0) { Write-Host "  No open items assigned to you." -ForegroundColor DarkGray; return }

        # --- Interactive scrolling viewport (alternate screen buffer) -----------
        # Rendering only what fits in the window keeps every cursor row in
        # [0, WindowHeight); the list can be far taller than the terminal.
        $nav = (C-Purple "[`u{2191}`u{2193}]") + (C-Dim " Navigate   ") +
               (C-Purple "[`u{21B5}]")          + (C-Dim " Open   ")     +
               (C-Purple "[C]")                 + (C-Dim " Code   ")     +
               (C-Purple "[N]")                 + (C-Dim " New   ")      +
               (C-Purple "[F]")                 + (C-Dim " Filter   ")   +
               (C-Purple "[R]")                 + (C-Dim " Refresh   ")  +
               (C-Purple "[Q]")                 + (C-Dim " Quit")

        $savedVisible = [Console]::CursorVisible
        $sel = 0; $scroll = 0; $launchItem = $null; $newIssue = $false; $filter = $false
        [Console]::Write("${ESC}[?1049h")            # enter alternate screen
        [Console]::CursorVisible = $false
        try {
            while ($true) {
                $wh    = [Console]::WindowHeight
                $avail = [Math]::Max(1, $wh - 4)     # row 0 = title, row 1 = spacer, last 2 = footer

                # Keep the selected item PLUS one line of context above/below in view, so
                # the group header (line above the first item) and the box bottom border
                # (line below the last item) are reachable and scroll returns fully to top.
                $selLine      = $itemPrimaryLineIdx[$sel]
                $topNeeded    = [Math]::Max(0, $selLine - 1)
                $bottomNeeded = [Math]::Min($lines.Count - 1, $selLine + 1)
                if ($topNeeded    -lt $scroll)          { $scroll = $topNeeded }
                if ($bottomNeeded -ge $scroll + $avail) { $scroll = $bottomNeeded - $avail + 1 }
                $maxScroll = [Math]::Max(0, $lines.Count - $avail)
                if ($scroll -gt $maxScroll) { $scroll = $maxScroll }
                if ($scroll -lt 0)          { $scroll = 0 }

                $hint = ""
                if ($scroll -gt 0)                       { $hint += "   `u{2191}" }
                if (($scroll + $avail) -lt $lines.Count) { $hint += "   `u{2193}" }

                # Row 0: app title + scroll hint.  Row 1: blank spacer before the first group.
                # The group header box (built into $lines) is the only group label, so no
                # separate breadcrumb row is needed.
                $title = (C-Pink "$BOLD  `u{25C6} $RESET") +
                         (C-Purple "$BOLD`u{2009}W O R K   I T E M S$RESET")
                [Console]::SetCursorPosition(0, 0)
                Write-Host ($title + (C-Dim $hint) + "${ESC}[K") -NoNewline
                [Console]::SetCursorPosition(0, 1)
                Write-Host "${ESC}[K" -NoNewline

                # Viewport (rows 2 .. wh-3). Overlay the selected item highlighted.
                $selItem = Build-Item $all[$sel] $true
                for ($vr = 0; $vr -lt $avail; $vr++) {
                    $li = $scroll + $vr
                    if ($li -lt $lines.Count) {
                        $txt = if ($li -eq $selLine) { $selItem } else { $lines[$li] }
                    } else { $txt = "" }
                    [Console]::SetCursorPosition(0, 2 + $vr)
                    Write-Host ($txt + "${ESC}[K") -NoNewline
                }

                # Footer (last two rows)
                [Console]::SetCursorPosition(0, $wh - 2); Write-Host "${ESC}[K" -NoNewline
                [Console]::SetCursorPosition(0, $wh - 1); Write-Host (" $nav" + "${ESC}[K") -NoNewline

                $key = [Console]::ReadKey($true)
                if     ($key.Key -eq "UpArrow"   -and $sel -gt 0)              { $sel-- }
                elseif ($key.Key -eq "DownArrow" -and $sel -lt $all.Count - 1) { $sel++ }
                elseif ($key.Key -eq "Home")  { $sel = 0 }
                elseif ($key.Key -eq "End")   { $sel = $all.Count - 1 }
                elseif ($key.Key -eq "Enter") { Start-Process $all[$sel].Url }
                elseif ($key.Key -eq "C")     { $launchItem = $all[$sel]; break }
                elseif ($key.Key -eq "N")     { $newIssue = $true; break }
                elseif ($key.Key -eq "F")     { $filter = $true; break }
                elseif ($key.Key -eq "R")     { $doRefresh = $true; break }
                elseif ($key.Key -eq "Q" -or $key.Key -eq "Escape") { break }
            }
        } finally {
            [Console]::CursorVisible = $savedVisible
            [Console]::Write("${ESC}[?1049l")        # restore normal screen
        }

        # --- [C] Code: hand the selected item off to Claude Code ----------------
        # Launch an interactive Claude session rooted at $REPO_ROOT. The work for an issue
        # may live in a DIFFERENT repo than the one the issue is filed in, so Claude has to
        # determine the correct repo itself. Branch naming is intentionally left to the
        # target repo's own rules file rather than dictated here.
        if ($launchItem) {
            $it   = $launchItem
            $isPr = $it.Url -match "/pull/"
            $vars = @{ Number = $it.Number; Title = $it.Title; Repo = $it.Repo; Url = $it.Url; RepoRoot = $REPO_ROOT; Org = $ORG }
            $template = if ($isPr) { $PROMPTS.PullRequest } else { $PROMPTS.Issue }
            Start-Claude (Expand-Prompt $template $vars)
            return
        }

        # --- [N] New issue: pick a board, then let Claude gather details and create it ------
        # Boards offered are the ones your items are on (minus hidden), resolved to titles.
        if ($newIssue) {
            $boardNums = @($seenProjects | Where-Object { -not $skipProjSet.Contains([int]$_) })
            $boards    = @(Get-Boards $boardNums | Sort-Object Title)
            if ($boards.Count -eq 0) {
                Write-Host "  No boards found on your items to add to." -ForegroundColor Red
                return
            }
            $board = Select-Board $boards
            if (-not $board) { return }

            $vars = @{ BoardTitle = $board.Title; BoardNumber = $board.Number; Org = $ORG; RepoRoot = $REPO_ROOT }
            Start-Claude (Expand-Prompt $PROMPTS.NewIssue $vars)
            return
        }

        # --- [F] Filter: choose which projects and statuses are visible, then persist --------------
        # Opt-in checklist with two groups (projects on top, statuses below). Offers every project /
        # status seen on your items plus any already hidden (so something with no current items can
        # still be switched back on). Unchecked entries are saved to SkipProjects / SkipStatuses.
        if ($filter) {
            $projUniverse = @(@($seenProjects) + @($SKIP_PROJECTS)) | Where-Object { $_ } | Sort-Object -Unique
            $projBoards   = if (@($projUniverse).Count -gt 0) { @(Get-Boards $projUniverse | Sort-Object Title) } else { @() }
            $statUniverse = @(@($seenStatuses) + @($SKIP_STATUS)) | Where-Object { $_ } | Sort-Object -Unique
            if (@($projBoards).Count -gt 0 -or @($statUniverse).Count -gt 0) {
                $result = Select-Filters $projBoards $SKIP_PROJECTS @($statUniverse) $SKIP_STATUS
                if ($null -ne $result) {
                    $SKIP_PROJECTS    = @($result.HideProjects)
                    $SKIP_STATUS      = @($result.HideStatuses)
                    $cfg.SkipProjects = $SKIP_PROJECTS
                    $cfg.SkipStatuses = $SKIP_STATUS
                    try { $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8 } catch { }
                }
            }
            $doRefresh = $true
        }
    }
}
