# work-items — a themed terminal dashboard for the GitHub issues and PRs assigned to you.
#
# This is the macOS / zsh implementation. The Windows / PowerShell implementation lives in
# work-items.ps1 next to this file. Both implementations read and write the SAME two config
# files (~/.work-items.json and ~/.work-items.prompts.json) and follow one behaviour
# contract: identical keybindings, layout, grouping logic, and prompts. A feature added to
# one must be added to the other in the same change (see CLAUDE.md).
#
# Install: add this line to your ~/.zshrc — sourcing (not executing) matters, because the
# [C]/[N] hand-off uses a plain `cd` to leave your shell parked in RepoRoot afterwards,
# which only works from a sourced function:
#
#   source /path/to/work-items.zsh
#
# Dependencies: zsh 5.5+, the GitHub CLI (`gh`, authenticated, with the read:project
# scope), and `jq`. The [C]/[N] actions additionally use the `claude` CLI; everything
# else works without it.
#
# Helper functions are prefixed _wi_ to keep the user's shell namespace clean. They rely
# on zsh's dynamic scoping: locals declared in work-items (colours, $inner, $ORG, ...) are
# visible inside the helpers it calls, mirroring how the PS version's nested functions see
# their parent scope.

# Build a string of $1 copies of $2 in REPLY (borders and padding).
_wi_rep() {
    emulate -L zsh
    local -i n=$1
    REPLY=""
    (( n <= 0 )) && return 0
    printf -v REPLY '%*s' $n ''
    [[ $2 != " " ]] && REPLY=${REPLY// /$2}
    return 0
}

# Trim surrounding whitespace from $1 into REPLY.
_wi_trim() {
    emulate -L zsh
    REPLY=$1
    REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

# --- Frame builders (REPLY = the finished line) ---------------------------
_wi_header() { # $1 = label, $2 = count
    emulate -L zsh
    local text="$1 ($2)"
    local -i dashes=$(( inner - 4 - ${#text} ))
    (( dashes < 0 )) && dashes=0
    local d; _wi_rep $dashes "─"; d=$REPLY
    REPLY="${C_P}╭── ${B}${text}${R}${C_P} ${d}╮${R}"
}

_wi_bottom() {
    emulate -L zsh
    local d; _wi_rep $inner "─"; d=$REPLY
    REPLY="${C_P}╰${d}╯${R}"
}

_wi_item() { # $1 = number, $2 = title, $3 = stale (0/1), $4 = selected (0/1)
    emulate -L zsh
    # Single compact line: "│ {cursor} {id,5}  {title} │"  (prefix = 11 visible cols)
    local cursor=" "
    (( $4 )) && cursor="${C_K}▶${R}"
    local id; printf -v id '%5s' "$1"
    local -i titlemax=$(( inner - 11 ))
    local title=$2
    (( ${#title} > titlemax )) && title="${title[1,titlemax-1]}…"
    local titlec=$title
    if (( $4 )); then titlec="${B}${title}${R}"        # bold, default foreground
    elif (( $3 )); then titlec="${C_D}${title}${R}"; fi # faint = theme-relative dim
    local -i pad=$(( inner - 11 - ${#title} ))
    local sp; _wi_rep $pad " "; sp=$REPLY
    REPLY="${C_P}│${R} ${cursor}  ${C_Y}${id}${R}  ${titlec}${sp}${C_P}│${R}"
}

_wi_status_line() { print -r -- "  ${C_D}$1${R}"; }
_wi_err()         { print -r -- "  ${C_E}$1${R}"; }

# Read one keypress (decoding arrow/Home/End escape sequences) into REPLY:
# UP DOWN HOME END ENTER SPACE ESC, or the literal character.
_wi_readkey() {
    emulate -L zsh
    local k k2 k3 k4
    read -s -k 1 k || { REPLY=ESC; return 0 }
    case $k in
        $'\e')
            if read -s -t 0.05 -k 1 k2 2>/dev/null; then
                if [[ $k2 == "[" || $k2 == "O" ]]; then
                    read -s -t 0.05 -k 1 k3 2>/dev/null
                    case $k3 in
                        A) REPLY=UP ;;
                        B) REPLY=DOWN ;;
                        H) REPLY=HOME ;;
                        F) REPLY=END ;;
                        1|7) read -s -t 0.05 -k 1 k4 2>/dev/null; REPLY=HOME ;;
                        4|8) read -s -t 0.05 -k 1 k4 2>/dev/null; REPLY=END ;;
                        *) REPLY=OTHER ;;
                    esac
                else
                    REPLY=ESC
                fi
            else
                REPLY=ESC
            fi ;;
        $'\n'|$'\r') REPLY=ENTER ;;
        ' ')         REPLY=SPACE ;;
        *)           REPLY=$k ;;
    esac
    return 0
}

# Animate a spinner on the current line while background jobs run, then reap them.
# Keeps the load from looking hung; the line is cleared when the jobs finish.
_wi_spin() { # $1 = label, rest = pids
    setopt localoptions nomonitor nonotify
    local label=$1; shift
    local -a frames=( "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏" )
    local -i i=0 alive
    local pid
    while :; do
        alive=0
        for pid in "$@"; do
            kill -0 $pid 2>/dev/null && { alive=1; break }
        done
        (( alive )) || break
        print -rn -- $'\r'"  ${C_P}${frames[i % 10 + 1]}${R} $label"
        sleep 0.08
        (( ++i ))
    done
    local sp; _wi_rep $(( ${#label} + 6 )) " "; sp=$REPLY
    print -rn -- $'\r'"$sp"$'\r'
    wait "$@" 2>/dev/null
    return 0
}

# Fill {placeholder} tokens in a prompt template: $1 = template, then key/value pairs.
_wi_expand() {
    emulate -L zsh
    REPLY=$1; shift
    while (( $# >= 2 )); do
        REPLY=${REPLY//"{$1}"/$2}
        shift 2
    done
}

# Open a URL in the default browser.
_wi_open() {
    emulate -L zsh
    if command -v open >/dev/null 2>&1; then open "$1"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 &!
    fi
    return 0
}

# Launch an interactive Claude session rooted at the configured repo root. Uses a plain
# `cd` (not pushd/popd) ON PURPOSE: work-items is a sourced function, so the cd persists
# after it returns, leaving you in the repo root ready to keep working — and any
# directory-entry hook (e.g. a direnv-style credential loader) fires before claude starts.
_wi_start_claude() {
    if [[ ! -d $REPO_ROOT ]]; then _wi_err "$REPO_ROOT not found."; return 1; fi
    cd -- "$REPO_ROOT" || return 1
    claude "$1"
}

# JSON array builders (REPLY = compact JSON) for persisting config edits.
_wi_json_str_array() {
    emulate -L zsh
    if (( $# == 0 )); then REPLY='[]'
    else REPLY=$(printf '%s\n' "$@" | jq -R . | jq -s -c .); fi
}
_wi_json_num_array() {
    emulate -L zsh
    if (( $# == 0 )); then REPLY='[]'
    else REPLY=$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -s -c .); fi
}

_wi_save_config() {
    jq '.' <<<"$cfg" > "$config_path" 2>/dev/null
}

# Resolve a set of project numbers to boards (one aliased query, so closed/older boards
# resolve regardless of `gh project list` pagination). Fills bd_num / bd_title, sorted by
# title — both callers ([N] and [F]) want that order.
_wi_get_boards() { # $@ = project numbers
    bd_num=(); bd_title=()
    (( $# == 0 )) && return 0
    local frags="" n
    for n in "$@"; do
        frags+="p${n}: projectV2(number: $n) { number title } "
    done
    local q="{ organization(login: \"$ORG\") { $frags } }"
    jq -n --arg q "$q" '{query: $q}' > "$tmpdir/boards-q.json"
    local resp
    resp=$(gh api graphql --input "$tmpdir/boards-q.json" 2>/dev/null)
    [[ -z $resp ]] && return 0
    local bt bn
    while IFS=$'\x1f' read -r bt bn; do
        [[ -z $bn ]] && continue
        bd_title+=( "$bt" ); bd_num+=( $bn )
    done < <(jq -r '.data.organization | to_entries[] | .value | select(. != null) |
                    "\(.title)\u001f\(.number)"' <<<"$resp" | LC_ALL=C sort -t$'\x1f' -k1,1)
    return 0
}

# Fetch each board's "Status" single-select options in board (column) order and fold them
# into one status-name -> rank map (fills auto_order). This is how the group order is
# derived automatically from the boards themselves. Boards are merged in the given order,
# first-seen wins, so each board's own backlog->done flow is preserved; statuses unique to
# a later board are appended after the earlier boards'.
_wi_status_order() { # $@ = project numbers
    (( $# == 0 )) && return 0
    local frags="" n
    for n in "$@"; do
        frags+="p${n}: projectV2(number: $n) { field(name: \"Status\") { ... on ProjectV2SingleSelectField { options { name } } } } "
    done
    local q="{ organization(login: \"$ORG\") { $frags } }"
    jq -n --arg q "$q" '{query: $q}' > "$tmpdir/order-q.json"
    local resp
    resp=$(gh api graphql --input "$tmpdir/order-q.json" 2>/dev/null)
    [[ -z $resp ]] && return 0
    local -i rank=0
    local nm
    while IFS= read -r nm; do
        [[ -z $nm ]] && continue
        if [[ -z ${auto_order[$nm]:-} ]]; then
            auto_order[$nm]=$rank
            (( ++rank ))
        fi
    done < <(jq -r '.data.organization | to_entries[] | .value.field.options[]?.name // empty' <<<"$resp")
    return 0
}

# Arrow-key board picker, styled like the main dashboard (alt screen, boxed, pink cursor).
# Reads bd_num / bd_title; REPLY = chosen index into those arrays, or "" if cancelled.
_wi_select_board() {
    local -i sel=1 count=${#bd_title} b
    local chosen=""
    print -n -- $'\e[?1049h\e[?25l'
    {
        while :; do
            print -n -- $'\e[1;1H'"${C_K}${B}  ◆ ${R}${C_P}${B}"$' '"N E W   I S S U E${R}"$'\e[K'
            print -n -- $'\e[2;1H\e[K'

            _wi_header "Choose a board" $count
            print -n -- $'\e[3;1H'"$REPLY"$'\e[K'
            for (( b = 1; b <= count; b++ )); do
                local cursor=" "
                (( b == sel )) && cursor="${C_K}▶${R}"
                local name=${bd_title[b]}
                local -i namemax=$(( inner - 4 ))
                (( ${#name} > namemax )) && name="${name[1,namemax-1]}…"
                local namec=$name
                (( b == sel )) && namec="${B}${name}${R}"
                local -i pad=$(( inner - 4 - ${#name} ))
                local sp; _wi_rep $pad " "; sp=$REPLY
                print -n -- $'\e['"$((3 + b));1H${C_P}│${R} ${cursor}  ${namec}${sp}${C_P}│${R}"$'\e[K'
            done
            _wi_bottom
            print -n -- $'\e['"$((4 + count));1H${REPLY}"$'\e[K'

            local bnav="${C_P}[↑↓]${R}${C_D} Navigate   ${R}${C_P}[↵]${R}${C_D} Select   ${R}${C_P}[Esc]${R}${C_D} Cancel${R}"
            print -n -- $'\e['"$((6 + count));1H ${bnav}"$'\e[K'

            _wi_readkey
            case $REPLY in
                UP)       (( sel > 1 )) && (( sel-- )) ;;
                DOWN)     (( sel < count )) && (( ++sel )) ;;
                HOME)     sel=1 ;;
                END)      sel=$count ;;
                ENTER)    chosen=$sel; break ;;
                ESC|[Qq]) break ;;
            esac
        done
    } always {
        print -n -- $'\e[?25h\e[?1049l'
    }
    REPLY=$chosen
    return 0
}

# Combined arrow-key filter, styled like the dashboard: a Projects group on top and a
# Statuses group below. Opt-in model — a checked [✓] row is shown, unchecked is hidden
# (and dimmed). Reads fp_num / fp_title / fs_names plus the current SKIP_PROJECTS /
# SKIP_STATUS; Space toggles, Enter applies, Esc cancels.
# Output: wi_f_applied (0/1) and, when applied, wi_f_hp / wi_f_hs (the new hide-lists).
_wi_select_filters() {
    local -A hideP=() hideS=()
    local x
    for x in $SKIP_PROJECTS; do hideP[$x]=1; done
    for x in "${(@)SKIP_STATUS}"; do [[ -n $x ]] && hideS[$x]=1; done

    # Flat entry list (projects then statuses) the cursor walks over.
    local -a e_kind=() e_key=() e_label=()
    local -i i
    for (( i = 1; i <= ${#fp_num}; i++ )); do
        e_kind+=( project ); e_key+=( ${fp_num[i]} ); e_label+=( "${fp_title[i]}" )
    done
    for x in "${(@)fs_names}"; do
        [[ -z $x ]] && continue
        e_kind+=( status ); e_key+=( "$x" ); e_label+=( "$x" )
    done
    wi_f_applied=0; wi_f_hp=(); wi_f_hs=()
    (( ${#e_kind} == 0 )) && return 0

    local -i sel=1
    print -n -- $'\e[?1049h\e[?25l'
    {
        while :; do
            print -n -- $'\e[1;1H'"${C_K}${B}  ◆ ${R}${C_P}${B}"$' '"F I L T E R${R}"$'\e[K'
            print -n -- $'\e[2;1H\e[K'

            local -i y=3 idx=1
            local grp
            for grp in Projects Statuses; do
                local kind=project
                [[ $grp == Statuses ]] && kind=status
                local -a g_idx=()
                local -i j
                for (( j = 1; j <= ${#e_kind}; j++ )); do
                    [[ ${e_kind[j]} == $kind ]] && g_idx+=( $j )
                done
                (( ${#g_idx} == 0 )) && continue
                local -i visible=0
                for j in $g_idx; do
                    if [[ $kind == project ]]; then
                        [[ -z ${hideP[${e_key[j]}]:-} ]] && (( ++visible ))
                    else
                        [[ -z ${hideS[${e_key[j]}]:-} ]] && (( ++visible ))
                    fi
                done
                _wi_header $grp $visible
                print -n -- $'\e['"$y;1H${REPLY}"$'\e[K'; (( ++y ))
                for j in $g_idx; do
                    local -i isvis=1
                    if [[ $kind == project ]]; then
                        [[ -n ${hideP[${e_key[j]}]:-} ]] && isvis=0
                    else
                        [[ -n ${hideS[${e_key[j]}]:-} ]] && isvis=0
                    fi
                    local cursor=" "
                    (( idx == sel )) && cursor="${C_K}▶${R}"
                    local box="[ ]"
                    (( isvis )) && box="[✓]"
                    local label="$box ${e_label[j]}"
                    local -i labelmax=$(( inner - 4 ))
                    (( ${#label} > labelmax )) && label="${label[1,labelmax-1]}…"
                    local labelc=$label
                    if (( idx == sel )); then labelc="${B}${label}${R}"
                    elif (( ! isvis )); then labelc="${C_D}${label}${R}"; fi
                    local -i pad=$(( inner - 4 - ${#label} ))
                    local sp; _wi_rep $pad " "; sp=$REPLY
                    print -n -- $'\e['"$y;1H${C_P}│${R} ${cursor}  ${labelc}${sp}${C_P}│${R}"$'\e[K'
                    (( ++y )); (( ++idx ))
                done
                _wi_bottom
                print -n -- $'\e['"$y;1H${REPLY}"$'\e[K'; (( ++y ))
                print -n -- $'\e['"$y;1H"$'\e[K'; (( ++y ))   # blank spacer
            done

            local bnav="${C_P}[↑↓]${R}${C_D} Navigate   ${R}${C_P}[Space]${R}${C_D} Show / hide   ${R}${C_P}[↵]${R}${C_D} Apply   ${R}${C_P}[Esc]${R}${C_D} Cancel${R}"
            print -n -- $'\e['"$y;1H ${bnav}"$'\e[K'

            _wi_readkey
            case $REPLY in
                UP)    (( sel > 1 )) && (( sel-- )) ;;
                DOWN)  (( sel < ${#e_kind} )) && (( ++sel )) ;;
                HOME)  sel=1 ;;
                END)   sel=${#e_kind} ;;
                SPACE)
                    local kk=${e_key[sel]}
                    if [[ ${e_kind[sel]} == project ]]; then
                        if [[ -n ${hideP[$kk]:-} ]]; then unset "hideP[$kk]"; else hideP[$kk]=1; fi
                    else
                        if [[ -n ${hideS[$kk]:-} ]]; then unset "hideS[$kk]"; else hideS[$kk]=1; fi
                    fi ;;
                ENTER)
                    wi_f_applied=1
                    wi_f_hp=( ${(k)hideP} )
                    wi_f_hs=( "${(@k)hideS}" )
                    break ;;
                ESC) break ;;
            esac
        done
    } always {
        print -n -- $'\e[?25h\e[?1049l'
    }
    return 0
}

work-items() {
    emulate -L zsh
    setopt localoptions nomonitor nonotify
    zmodload zsh/datetime 2>/dev/null

    # --- Colour helpers. Two principles keep this readable on ANY terminal theme (light
    #     or dark): (1) accents use the standard 16-colour ANSI slots, which each terminal
    #     maps to its own scheme; (2) body text uses NO fixed colour — normal text is the
    #     terminal's default foreground and "dim" is the faint attribute. Same mapping as
    #     the PS version's C-Purple / C-Pink / C-Yellow / C-Dim helpers. ---
    local R=$'\e[0m' B=$'\e[1m'
    local C_P=$'\e[34m'   # borders & group headers -> ANSI blue
    local C_K=$'\e[35m'   # active cursor            -> ANSI magenta
    local C_Y=$'\e[33m'   # item IDs                 -> ANSI yellow
    local C_D=$'\e[2m'    # stale items, footer, hints -> faint (relative)
    local C_E=$'\e[31m'   # errors                   -> ANSI red

    local dep
    for dep in gh jq; do
        if ! command -v $dep >/dev/null 2>&1; then
            _wi_err "'$dep' not found — work-items needs the GitHub CLI (gh) and jq."
            return 1
        fi
    done

    local -i diagnose=0
    [[ ${1:-} == ((-|--)[Dd]iagnose) ]] && diagnose=1

    # --- Per-user configuration. Everything environment-specific (repo location, GitHub
    #     org, project numbers, status names) lives in ~/.work-items.json, NOT in this
    #     script. The file is created on first run; edit it to tune the rest. ---
    local config_path="$HOME/.work-items.json"
    local cfg=""
    [[ -f $config_path ]] && cfg=$(jq -c '.' "$config_path" 2>/dev/null)
    [[ -z $cfg ]] && cfg='{}'

    # Migrate: the old allow-list 'ProjectNumbers' is superseded by the 'SkipProjects' hide-list.
    local -i dirty=0
    if [[ $(jq 'has("ProjectNumbers")' <<<"$cfg") == true ]]; then
        cfg=$(jq -c 'del(.ProjectNumbers)' <<<"$cfg")
        dirty=1
    fi

    # Prompt once for any missing essential (repo root + org), then persist.
    local REPO_ROOT=$(jq -r '.RepoRoot // empty' <<<"$cfg")
    if [[ -z $REPO_ROOT ]]; then
        local in_root
        read "in_root?Path to the folder where your repositories are checked out: "
        _wi_trim "$in_root"; in_root=$REPLY
        in_root=${in_root#\"}; in_root=${in_root%\"}
        if [[ -z $in_root ]]; then _wi_err "No repository root set; aborting."; return 1; fi
        if [[ ! -e $in_root ]]; then _wi_err "'$in_root' does not exist; aborting."; return 1; fi
        cfg=$(jq -c --arg v "$in_root" '.RepoRoot = $v' <<<"$cfg")
        REPO_ROOT=$in_root
        dirty=1
    fi
    local ORG=$(jq -r '.Org // empty' <<<"$cfg")
    if [[ -z $ORG ]]; then
        local in_org
        read "in_org?GitHub organization (owner) to search: "
        _wi_trim "$in_org"; in_org=$REPLY
        if [[ -z $in_org ]]; then _wi_err "No organization set; aborting."; return 1; fi
        cfg=$(jq -c --arg v "$in_org" '.Org = $v' <<<"$cfg")
        ORG=$in_org
        dirty=1
    fi
    if (( dirty )); then
        # Seed the optional knobs so the saved file documents what can be tuned.
        cfg=$(jq -c '
            .SkipProjects   //= [] |
            .SkipStatuses   //= [] |
            .StatusPriority //= {} |
            .StaleDays      //= 7
        ' <<<"$cfg")
        _wi_save_config
        _wi_status_line "Saved $config_path - tune SkipProjects, SkipStatuses and StatusPriority there, or use [F] in the app."
    fi

    local -a SKIP_PROJECTS=( ${(f)"$(jq -r '.SkipProjects // [] | .[]' <<<"$cfg")"} )
    local -a SKIP_STATUS=( ${(f)"$(jq -r '.SkipStatuses // [] | .[]' <<<"$cfg")"} )
    local -A STATUS_PRIORITY=()
    local spk spv
    while IFS=$'\x1f' read -r spk spv; do
        [[ -n $spk ]] && STATUS_PRIORITY[$spk]=$spv
    done < <(jq -r '.StatusPriority // {} | to_entries[] | "\(.key)\u001f\(.value)"' <<<"$cfg")
    local -i stale_days=$(jq -r '.StaleDays // 7' <<<"$cfg")
    local -i cutoff=$(( EPOCHSECONDS - stale_days * 86400 ))

    # --- Claude hand-off prompts. Kept in ~/.work-items.prompts.json so devs can tweak
    #     the wording without touching this script. Placeholders in {curly braces} are
    #     filled at run time: {Number} {Title} {Repo} {Url} {RepoRoot} {Org} {BoardTitle}
    #     {BoardNumber}. Missing/blank entries are re-seeded from these defaults (so
    #     upgrades add new keys). Same defaults as the PS version. ---
    local prompts_path="$HOME/.work-items.prompts.json"
    local -A default_prompts=(
        [Issue]="I want to work on GitHub issue #{Number} (\"{Title}\"), filed in the '{Repo}' repository: {Url}. First move the issue to the 'In Progress' status on its project board. Note the code to implement this may live in a DIFFERENT repository than the one the issue is filed in. Read the issue, figure out which repository under {RepoRoot} is the right place to do the work, create a new branch there (follow that repo's branch-naming rules if it defines any), and start working on it."
        [PullRequest]="I want to work on GitHub pull request #{Number} (\"{Title}\"), filed in the '{Repo}' repository: {Url}. The matching repository is checked out somewhere under {RepoRoot} - find it, check out this PR's branch, and help me review and address it."
        [NewIssue]="I want to create a new GitHub issue and add it to the '{BoardTitle}' project board (project number {BoardNumber}) in the '{Org}' organization. Ask me - as a normal chat message, not a multiple-choice question - only for a description of the issue, then come up with a clear, concise title for it yourself. Use the board's default repository; do not ask me which repository to use. Create the issue with the gh CLI, assign it to me, add it to that board, and set its status to the board's default status. Confirm the title and details with me before creating anything."
    )
    local -a prompt_keys=( Issue PullRequest NewIssue )
    local prompts=""
    [[ -f $prompts_path ]] && prompts=$(jq -c '.' "$prompts_path" 2>/dev/null)
    [[ -z $prompts ]] && prompts='{}'
    local -i prompts_dirty=0
    local pk
    for pk in $prompt_keys; do
        local cur=$(jq -r --arg k "$pk" '.[$k] // ""' <<<"$prompts")
        if [[ -z ${cur//[[:space:]]/} ]]; then
            prompts=$(jq -c --arg k "$pk" --arg v "${default_prompts[$pk]}" '.[$k] = $v' <<<"$prompts")
            prompts_dirty=1
        fi
    done
    (( prompts_dirty )) && jq '{Issue, PullRequest, NewIssue}' <<<"$prompts" > "$prompts_path"
    local PROMPT_ISSUE=$(jq -r '.Issue' <<<"$prompts")
    local PROMPT_PR=$(jq -r '.PullRequest' <<<"$prompts")
    local PROMPT_NEW=$(jq -r '.NewIssue' <<<"$prompts")

    # Inner box width (content area between the two vertical borders). Adapts to terminal.
    local -i inner=$(( ${COLUMNS:-121} - 3 ))
    (( inner > 118 )) && inner=118
    (( inner < 40 ))  && inner=40

    local tmpdir
    tmpdir=$(mktemp -d) || return 1
    trap 'rm -rf -- "$tmpdir"' EXIT

    local -i do_refresh=1
    while (( do_refresh )); do
        do_refresh=0

        # --- Fetch assigned issues + PRs. The three searches are independent, so run
        #     them concurrently as background jobs and spin while we wait. ---
        local fields="title,url,repository,number,updatedAt"
        gh search issues --assignee=@me         --owner="$ORG" --state=open --json "$fields" --limit 100 > "$tmpdir/issues.json" 2>/dev/null &
        local -i p1=$!
        gh search prs    --assignee=@me         --owner="$ORG" --state=open --json "$fields" --limit 100 > "$tmpdir/aprs.json"   2>/dev/null &
        local -i p2=$!
        gh search prs    --review-requested=@me --owner="$ORG" --state=open --json "$fields" --limit 100 > "$tmpdir/rprs.json"   2>/dev/null &
        local -i p3=$!
        _wi_spin "Fetching issues and PRs..." $p1 $p2 $p3

        # PRs awaiting our review are other people's PRs: their project status isn't ours
        # to act on, so exempt them from the status-skip filter. An open review request
        # always matters; once the PR is merged/closed it drops out via --state=open.
        local -A review_urls=()
        local ru
        while IFS= read -r ru; do
            [[ -n $ru ]] && review_urls[$ru]=1
        done < <(jq -r '.[]?.url' "$tmpdir/rprs.json" 2>/dev/null)

        # Merge assigned + review-requested PRs, de-duplicated by URL.
        jq -s -c '[ (.[0] // [])[], (.[1] // [])[] ] | unique_by(.url)' \
            "$tmpdir/aprs.json" "$tmpdir/rprs.json" > "$tmpdir/prs.json" 2>/dev/null \
            || print '[]' > "$tmpdir/prs.json"

        # Read both lists into parallel arrays (one \x1f-separated record per item).
        local jq_rec='.[]? | [ (.number | tostring), .title, .repository.name, .url,
                               (.updatedAt | fromdateiso8601 | tostring) ] | join("\u001f")'
        local -a iss_num=() iss_title=() iss_repo=() iss_url=() iss_upd=()
        local rn rt rr ru2 rup
        while IFS=$'\x1f' read -r rn rt rr ru2 rup; do
            iss_num+=( $rn ); iss_title+=( "$rt" ); iss_repo+=( "$rr" ); iss_url+=( "$ru2" ); iss_upd+=( $rup )
        done < <(jq -r "$jq_rec" "$tmpdir/issues.json" 2>/dev/null)
        local -a pr_num=() pr_title=() pr_repo=() pr_url=() pr_upd=()
        while IFS=$'\x1f' read -r rn rt rr ru2 rup; do
            pr_num+=( $rn ); pr_title+=( "$rt" ); pr_repo+=( "$rr" ); pr_url+=( "$ru2" ); pr_upd+=( $rup )
        done < <(jq -r "$jq_rec" "$tmpdir/prs.json" 2>/dev/null)

        # --- Query each item's project status, chunked and run concurrently. ---
        local -A url_status=() skip_url=()
        local -A seen_status=()    # statuses seen on non-hidden boards, for [F]
        local -A seen_project=()   # project numbers seen on items, for [F]/[N]
        # Boards to ignore entirely. Rebuilt each refresh so [F] edits take effect on re-render.
        local -A skip_proj_set=()
        local sp2
        for sp2 in $SKIP_PROJECTS; do skip_proj_set[$sp2]=1; done

        local -a all_urls=( $iss_url $pr_url )
        all_urls=( ${(u)all_urls} )

        if (( ${#all_urls} > 0 )); then
            local -a fragments=()
            local -i fi2
            for (( fi2 = 1; fi2 <= ${#all_urls}; fi2++ )); do
                local u=${all_urls[fi2]}
                fragments+=( "i$((fi2 - 1)): resource(url: \"$u\") { ... on Issue { projectItems(first: 10) { nodes { project { number } fieldValues(first: 10) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } } } } } } } ... on PullRequest { projectItems(first: 10) { nodes { project { number } fieldValues(first: 10) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } } } } } } } }" )
            done

            # Split the fragments into chunks fetched concurrently (waves of 4, matching
            # the PS version's throttle); GitHub processes the chunks in parallel. Each
            # fragment keeps its global alias (i0..iN), so the chunk responses merge back
            # without re-indexing.
            local -i chunk_size=15 cs ce ci=0
            local -a qfiles=()
            for (( cs = 1; cs <= ${#fragments}; cs += chunk_size )); do
                ce=$(( cs + chunk_size - 1 ))
                (( ce > ${#fragments} )) && ce=${#fragments}
                local q="{ ${(j: :)fragments[cs,ce]} }"
                jq -n --arg q "$q" '{query: $q}' > "$tmpdir/q$ci.json"
                qfiles+=( "$tmpdir/q$ci.json" )
                (( ++ci ))
            done
            local -a resp_files=()
            local -i wi wj
            for (( wi = 1; wi <= ${#qfiles}; wi += 4 )); do
                local -a pids=()
                for (( wj = wi; wj < wi + 4 && wj <= ${#qfiles}; wj++ )); do
                    gh api graphql --input "${qfiles[wj]}" > "$tmpdir/r$wj.json" 2>/dev/null &
                    pids+=( $! )
                    resp_files+=( "$tmpdir/r$wj.json" )
                done
                _wi_spin "Checking project status..." $pids
            done

            # Merge every chunk's data.* aliases into one lookup keyed by alias name.
            local -a valid_files=()
            local rf
            for rf in $resp_files; do
                jq -e '.data' "$rf" >/dev/null 2>&1 && valid_files+=( "$rf" )
            done
            if (( ${#valid_files} > 0 )); then
                jq -s 'map(.data) | add' $valid_files > "$tmpdir/data.json"
            else
                print '{}' > "$tmpdir/data.json"
            fi

            # Every board considered by default; boards in SkipProjects are ignored
            # entirely (their status never drives grouping and never hides the item).
            # Status comes from the first non-hidden board. The jq pass below streams one
            # line per (item, board) pair, in item order; the loop replicates the PS
            # version's per-item walk, including its early-out once a skip-status is hit.
            local -A st_skip=() st_first=() st_onboard=() st_visible=()
            local rkey rpnum rstat
            while IFS=$'\x1f' read -r rkey rpnum rstat; do
                [[ -n ${st_skip[$rkey]:-} ]] && continue   # PS 'break': stop walking this item
                st_onboard[$rkey]=1
                (( rpnum )) && seen_project[$rpnum]=1
                [[ -n ${skip_proj_set[$rpnum]:-} ]] && continue   # ignore hidden boards
                st_visible[$rkey]=1
                [[ -n $rstat ]] && seen_status[$rstat]=1
                if [[ -n $rstat ]] && (( ${SKIP_STATUS[(Ie)$rstat]} )); then
                    st_skip[$rkey]=1
                    continue
                fi
                if [[ -n $rstat && -z ${st_first[$rkey]:-} ]]; then
                    st_first[$rkey]=$rstat
                fi
            done < <(jq -r 'to_entries[] | .key as $k | (.value.projectItems.nodes // [])[]? |
                            [ $k, (.project.number // 0 | tostring),
                              ([ .fieldValues.nodes[]? | select((.field.name? // "") == "Status") | .name ] | first // "") ]
                            | join("\u001f")' "$tmpdir/data.json" 2>/dev/null)

            local -i ui
            for (( ui = 1; ui <= ${#all_urls}; ui++ )); do
                local ukey="i$((ui - 1))" uurl=${all_urls[ui]}
                if [[ -n ${st_skip[$ukey]:-} ]]; then
                    skip_url[$uurl]=1
                elif [[ -n ${st_first[$ukey]:-} ]]; then
                    url_status[$uurl]=${st_first[$ukey]}
                elif [[ -n ${st_onboard[$ukey]:-} && -z ${st_visible[$ukey]:-} ]]; then
                    # On boards, but every one is hidden (SkipProjects): the item is
                    # exclusive to boards you don't care about, so hide it entirely rather
                    # than leaking it through as "No Status". Genuinely board-less items
                    # still show as No Status.
                    skip_url[$uurl]=1
                fi
            done
        fi

        # Derive the status group order from the visible boards' columns (backlog->done).
        local -a visible_boards=( ${(k)seen_project} )
        visible_boards=( ${visible_boards:|SKIP_PROJECTS} )
        visible_boards=( ${(no)visible_boards} )
        local -A auto_order=()
        _wi_status_order $visible_boards

        # --- Diagnose: dump raw data and exit ---
        if (( diagnose )); then
            local C_C=$'\e[36m'
            print
            local -a tmpl=( ${(k)seen_project} ); tmpl=( ${(no)tmpl} )
            print -r -- "  ${C_C}Projects seen on items:   ${(j:, :)tmpl}${R}"
            tmpl=( $SKIP_PROJECTS ); tmpl=( ${(no)tmpl} )
            print -r -- "  ${C_D}Hidden projects (Skip):   ${(j:, :)tmpl}${R}"
            print
            print -r -- "  ${C_C}Group order (from board columns):${R}"
            local dline
            for dline in ${(f)"$(local k; for k in "${(@k)auto_order}"; do print -r -- "${auto_order[$k]}"$'\x1f'"$k"; done | LC_ALL=C sort -t$'\x1f' -k1,1n)"}; do
                local nm=${dline#*$'\x1f'}
                local ov=""
                [[ -n ${STATUS_PRIORITY[$nm]:-} ]] && ov=" (override ${STATUS_PRIORITY[$nm]})"
                printf '  %2d. %s%s\n' "${dline%%$'\x1f'*}" "$nm" "$ov"
            done
            print
            print -r -- "  ${C_C}Status map (${#url_status} items):${R}"
            for dline in ${(f)"$(local k; for k in "${(@k)url_status}"; do print -r -- "${url_status[$k]}"$'\x1f'"$k"; done | LC_ALL=C sort -t$'\x1f' -k1,1 -k2,2)"}; do
                printf '  [%-30s] %s\n' "${dline%%$'\x1f'*}" "${dline#*$'\x1f'}"
            done
            print
            print -r -- "  ${C_D}Skipped (${#skip_url} items):${R}"
            local sk
            for sk in "${(@k)skip_url}"; do print -r -- "  ${C_D}$sk${R}"; done
            print
            return 0
        fi

        # --- Build the unified item list (issues first, then PRs), applying the skips ---
        local -a it_num=() it_title=() it_repo=() it_url=() it_upd=() it_stale=() it_status=() it_ispr=()
        local -i bi
        for (( bi = 1; bi <= ${#iss_url}; bi++ )); do
            local burl=${iss_url[bi]}
            [[ -n ${skip_url[$burl]:-} ]] && continue
            local -i bstale=0
            (( iss_upd[bi] < cutoff )) && bstale=1
            it_num+=( ${iss_num[bi]} ); it_title+=( "${iss_title[bi]}" ); it_repo+=( "${iss_repo[bi]}" )
            it_url+=( "$burl" ); it_upd+=( ${iss_upd[bi]} ); it_stale+=( $bstale )
            it_status+=( "${url_status[$burl]:-No Status}" ); it_ispr+=( 0 )
        done
        for (( bi = 1; bi <= ${#pr_url}; bi++ )); do
            local burl=${pr_url[bi]}
            if [[ -n ${skip_url[$burl]:-} && -z ${review_urls[$burl]:-} ]]; then continue; fi
            local -i bstale=0
            (( pr_upd[bi] < cutoff )) && bstale=1
            it_num+=( ${pr_num[bi]} ); it_title+=( "${pr_title[bi]}" ); it_repo+=( "${pr_repo[bi]}" )
            it_url+=( "$burl" ); it_upd+=( ${pr_upd[bi]} ); it_stale+=( $bstale )
            it_status+=( "" ); it_ispr+=( 1 )
        done

        # --- Group issues by status, PRs as a final group ---
        # Order: a manual StatusPriority entry wins (optional override); otherwise the
        # board-derived column order; otherwise unranked statuses sit just above
        # "No Status", which is always last.
        local -A group_seen=()
        local -a group_names=()
        local -i gi
        for (( gi = 1; gi <= ${#it_url}; gi++ )); do
            (( it_ispr[gi] )) && continue
            local gst=${it_status[gi]}
            if [[ -z ${group_seen[$gst]:-} ]]; then
                group_seen[$gst]=1
                group_names+=( "$gst" )
            fi
        done
        local -a sorted_groups=()
        if (( ${#group_names} > 0 )); then
            sorted_groups=( ${(f)"$(
                local gn
                for gn in "${(@)group_names}"; do
                    local p=""
                    if [[ -n ${STATUS_PRIORITY[$gn]:-} ]]; then p=${STATUS_PRIORITY[$gn]}
                    elif [[ -n ${auto_order[$gn]:-} ]]; then p=${auto_order[$gn]}
                    elif [[ $gn == "No Status" ]]; then p=999
                    else p=100; fi
                    print -r -- "$p"$'\x1f'"$gn"
                done | LC_ALL=C sort -s -t$'\x1f' -k1,1n -k2,2 | cut -d$'\x1f' -f2-
            )"} )
        fi

        # --- Pre-build every frame line; record each item's primary-line index ---
        local -a lines=() item_line=() all_items=()
        local gn2
        for gn2 in "${(@)sorted_groups}"; do
            local -a gidxs=()
            for (( gi = 1; gi <= ${#it_url}; gi++ )); do
                (( it_ispr[gi] )) && continue
                [[ ${it_status[gi]} == "$gn2" ]] && gidxs+=( $gi )
            done
            gidxs=( ${(f)"$(local x2; for x2 in $gidxs; do print -r -- "${it_upd[x2]}"$'\x1f'"$x2"; done | LC_ALL=C sort -s -t$'\x1f' -k1,1nr | cut -d$'\x1f' -f2)"} )
            _wi_add_group "$gn2" $gidxs
        done
        local -a pidxs=()
        for (( gi = 1; gi <= ${#it_url}; gi++ )); do
            (( it_ispr[gi] )) && pidxs+=( $gi )
        done
        if (( ${#pidxs} > 0 )); then
            pidxs=( ${(f)"$(local x2; for x2 in $pidxs; do print -r -- "${it_upd[x2]}"$'\x1f'"$x2"; done | LC_ALL=C sort -s -t$'\x1f' -k1,1nr | cut -d$'\x1f' -f2)"} )
            _wi_add_group "Pull Requests" $pidxs
        fi

        if (( ${#all_items} == 0 )); then
            _wi_status_line "No open items assigned to you."
            return 0
        fi

        # --- Interactive scrolling viewport (alternate screen buffer) -----------
        # Rendering only what fits in the window keeps every cursor row on screen; the
        # list can be far taller than the terminal.
        local nav="${C_P}[↑↓]${R}${C_D} Navigate   ${R}${C_P}[↵]${R}${C_D} Open   ${R}${C_P}[C]${R}${C_D} Code   ${R}${C_P}[N]${R}${C_D} New   ${R}${C_P}[F]${R}${C_D} Filter   ${R}${C_P}[R]${R}${C_D} Refresh   ${R}${C_P}[Q]${R}${C_D} Quit${R}"

        local -i sel=1 scroll=1 launch=0 newissue=0 filter=0
        print -n -- $'\e[?1049h\e[?25l'    # enter alternate screen, hide cursor
        {
            while :; do
                local -i wh=${LINES:-30}
                local -i avail=$(( wh - 4 ))    # row 1 = title, row 2 = spacer, last 2 = footer
                (( avail < 1 )) && avail=1

                # Keep the selected item PLUS one line of context above/below in view, so
                # the group header (line above the first item) and the box bottom border
                # (line below the last item) are reachable and scroll returns fully to top.
                local -i selline=${item_line[sel]}
                local -i top_needed=$(( selline - 1 ))
                (( top_needed < 1 )) && top_needed=1
                local -i bottom_needed=$(( selline + 1 ))
                (( bottom_needed > ${#lines} )) && bottom_needed=${#lines}
                (( top_needed < scroll )) && scroll=$top_needed
                (( bottom_needed >= scroll + avail )) && scroll=$(( bottom_needed - avail + 1 ))
                local -i max_scroll=$(( ${#lines} - avail + 1 ))
                (( max_scroll < 1 )) && max_scroll=1
                (( scroll > max_scroll )) && scroll=$max_scroll
                (( scroll < 1 )) && scroll=1

                local hint=""
                (( scroll > 1 )) && hint+="   ↑"
                (( scroll + avail - 1 < ${#lines} )) && hint+="   ↓"

                # Row 1: app title + scroll hint.  Row 2: blank spacer before the first group.
                print -n -- $'\e[1;1H'"${C_K}${B}  ◆ ${R}${C_P}${B}"$' '"W O R K   I T E M S${R}${C_D}${hint}${R}"$'\e[K'
                print -n -- $'\e[2;1H\e[K'

                # Viewport (rows 3 .. wh-2). Overlay the selected item highlighted.
                local -i selidx=${all_items[sel]}
                _wi_item ${it_num[selidx]} "${it_title[selidx]}" ${it_stale[selidx]} 1
                local selitem=$REPLY
                local -i vr li
                for (( vr = 0; vr < avail; vr++ )); do
                    li=$(( scroll + vr ))
                    local txt=""
                    if (( li <= ${#lines} )); then
                        if (( li == selline )); then txt=$selitem; else txt=${lines[li]}; fi
                    fi
                    print -n -- $'\e['"$((3 + vr));1H${txt}"$'\e[K'
                done

                # Footer (last two rows)
                print -n -- $'\e['"$((wh - 1));1H"$'\e[K'
                print -n -- $'\e['"$wh;1H ${nav}"$'\e[K'

                _wi_readkey
                case $REPLY in
                    UP)     (( sel > 1 )) && (( sel-- )) ;;
                    DOWN)   (( sel < ${#all_items} )) && (( ++sel )) ;;
                    HOME)   sel=1 ;;
                    END)    sel=${#all_items} ;;
                    ENTER)  _wi_open "${it_url[${all_items[sel]}]}" ;;
                    [Cc])   launch=1; break ;;
                    [Nn])   newissue=1; break ;;
                    [Ff])   filter=1; break ;;
                    [Rr])   do_refresh=1; break ;;
                    [Qq]|ESC) break ;;
                esac
            done
        } always {
            print -n -- $'\e[?25h\e[?1049l'    # restore cursor + normal screen
        }

        # --- [C] Code: hand the selected item off to Claude Code ----------------
        # The work for an issue may live in a DIFFERENT repo than the one it's filed in,
        # so Claude determines the correct repo itself. Branch naming is intentionally
        # left to the target repo's own rules file rather than dictated here.
        if (( launch )); then
            local -i lidx=${all_items[sel]}
            local template=$PROMPT_ISSUE
            [[ ${it_url[lidx]} == */pull/* ]] && template=$PROMPT_PR
            _wi_expand "$template" \
                Number "${it_num[lidx]}" Title "${it_title[lidx]}" Repo "${it_repo[lidx]}" \
                Url "${it_url[lidx]}" RepoRoot "$REPO_ROOT" Org "$ORG"
            _wi_start_claude "$REPLY"
            return 0
        fi

        # --- [N] New issue: pick a board, then let Claude gather details and create it ---
        # Boards offered are the ones your items are on (minus hidden), resolved to titles.
        if (( newissue )); then
            local -a board_nums=( ${(k)seen_project} )
            board_nums=( ${board_nums:|SKIP_PROJECTS} )
            local -a bd_num=() bd_title=()
            _wi_get_boards $board_nums
            if (( ${#bd_num} == 0 )); then
                _wi_err "No boards found on your items to add to."
                return 1
            fi
            _wi_select_board
            [[ -z $REPLY ]] && return 0
            local -i chosen=$REPLY
            _wi_expand "$PROMPT_NEW" \
                BoardTitle "${bd_title[chosen]}" BoardNumber "${bd_num[chosen]}" \
                Org "$ORG" RepoRoot "$REPO_ROOT"
            _wi_start_claude "$REPLY"
            return 0
        fi

        # --- [F] Filter: choose which projects and statuses are visible, then persist ---
        # Opt-in checklist with two groups (projects on top, statuses below). Offers every
        # project / status seen on your items plus any already hidden (so something with
        # no current items can still be switched back on). Unchecked entries are saved to
        # SkipProjects / SkipStatuses.
        if (( filter )); then
            local -a proj_universe=( ${(k)seen_project} $SKIP_PROJECTS )
            proj_universe=( ${(uno)proj_universe} )
            local -a bd_num=() bd_title=()
            _wi_get_boards $proj_universe
            local -a fp_num=( $bd_num ) fp_title=( "${(@)bd_title}" )
            local -a stat_universe=( "${(@k)seen_status}" "${(@)SKIP_STATUS}" )
            stat_universe=( "${(@uo)stat_universe}" )
            local -a fs_names=()
            local su
            for su in "${(@)stat_universe}"; do [[ -n $su ]] && fs_names+=( "$su" ); done
            if (( ${#fp_num} > 0 || ${#fs_names} > 0 )); then
                local -i wi_f_applied=0
                local -a wi_f_hp=() wi_f_hs=()
                _wi_select_filters
                if (( wi_f_applied )); then
                    SKIP_PROJECTS=( $wi_f_hp )
                    SKIP_STATUS=( "${(@)wi_f_hs}" )
                    _wi_json_num_array $SKIP_PROJECTS
                    local spj=$REPLY
                    _wi_json_str_array "${(@)SKIP_STATUS}"
                    local ssj=$REPLY
                    cfg=$(jq -c --argjson sp "$spj" --argjson ss "$ssj" \
                          '.SkipProjects = $sp | .SkipStatuses = $ss' <<<"$cfg")
                    _wi_save_config
                fi
            fi
            do_refresh=1
        fi
    done
    return 0
}

# Append one boxed group to the pre-built frame: header, one line per item, bottom border.
# $1 = label, remaining args = item indices (already sorted). Fills lines / item_line /
# all_items in the caller's scope.
_wi_add_group() {
    local label=$1; shift
    (( ${#lines} > 0 )) && lines+=( "" )   # blank spacer between groups
    _wi_header "$label" $#
    lines+=( "$REPLY" )
    local -i aidx
    for aidx in "$@"; do
        item_line+=( $(( ${#lines} + 1 )) )
        all_items+=( $aidx )
        _wi_item ${it_num[aidx]} "${it_title[aidx]}" ${it_stale[aidx]} 0
        lines+=( "$REPLY" )
    done
    _wi_bottom
    lines+=( "$REPLY" )
}
