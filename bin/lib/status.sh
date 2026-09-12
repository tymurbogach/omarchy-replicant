# shellcheck shell=bash disable=SC2034
# status.sh: the JSON that the panel and the bar read, the diff and the log.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

build_configs_json() {
  invalidate_git_cache
  # One jq for the whole list. Same reason as build_settings_json: this runs on
  # every panel refresh and there are forty-odd rows.
  local entry src rel label category exists is_default has_default default_src config_rel
  local dirty unpushed sync_state saved synced source scope repo_path git_rel unsaved is_dir nfiles incoming
  # Fill the scope cache HERE, in this shell. scope_for is reached through
  # $(repo_path_for ...) for every row, and a cache filled inside that
  # substitution is discarded with it — the file was re-read fifty times over.
  read_scopes >/dev/null
  {
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"; label="$rel"
    category=$(category_for_rel "$rel")
    is_dir=false; nfiles=0
    is_dir_entry "$rel" && is_dir=true
    if [[ "$is_dir" == true ]]; then
      [[ -d "${src%/}" ]] && exists=true || exists=false
      [[ "$exists" == true ]] && nfiles=$(tree_count "$src")
    else
      [[ -f "$src" ]] && exists=true || exists=false
    fi
    has_default=false; default_src=""
    if [[ "$is_dir" == false ]] && default_src=$(default_for_src "$src" 2>/dev/null) && [[ -n "$default_src" ]]; then has_default=true; fi
    config_rel=""
    [[ "$is_dir" == false ]] && config_rel=$(config_rel_for_src "$src" 2>/dev/null || true)
    if [[ "$exists" == true && "$has_default" == true ]] && cmp -s "$src" "$default_src" 2>/dev/null; then
      is_default=true
    else
      is_default=false
    fi
    scope=$(scope_for "$rel")
    repo_path=$(repo_path_for "$rel")
    git_rel="${repo_path#"$REPO_DIR"/}"
    saved=false
    if [[ "$is_dir" == true ]]; then
      [[ -d "${repo_path%/}" ]] && saved=true
    else
      [[ -f "$repo_path" ]] && saved=true
    fi
    # "Unsaved" is a question about CONTENT: does the file on this machine differ
    # from the copy the repo holds? Asking git instead only ever sees files
    # core_backup has already copied in, so a file edited on the machine and
    # never saved reported itself as "saved on GitHub" — a backup tool claiming
    # a change was safe when it was nowhere.
    #
    # Comparing content is also what makes the warning self-healing: edit a file
    # and put it back, and cmp matches again, so the badge clears on its own with
    # no flag to go stale.
    #
    # A directory answers the same question the same way, file by file:
    # tree_same is cmp over the whole tree, so adding, editing or deleting
    # anything inside a tracked directory shows up, and undoing it clears.
    unsaved=false
    entry_differs "$src" "$repo_path" "$is_dir" && unsaved=true
    # Copied into the repo but not committed is unsaved too — same word, same
    # button. Content and git each catch a case the other misses.
    dirty=false
    path_dirty "$git_rel" && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "$git_rel" && unpushed=true
    # The same difference, pointing the other way. Only meaningful while the
    # file still differs, which is what makes it clear itself once the entry is
    # restored — or once the user knowingly saves over it.
    incoming=false
    [[ "$unsaved" == true ]] && is_incoming_rel "$rel" && incoming=true
    synced=true
    [[ "$scope" == "off" ]] && synced=false
    # off > missing > incoming > unsaved > default > unpushed > saved.
    #
    # incoming MUST outrank unsaved, and it is the only ordering that is about
    # safety rather than tidiness. Both mean "this file and its copy differ";
    # unsaved asks for Save and incoming asks for Restore, and pressing the
    # wrong one commits over work another machine did. When the direction is
    # known, it wins.
    #
    # unsaved MUST outrank default. Putting a customised file back to Omarchy's
    # default is itself a change that still needs saving, and it used to show the
    # calm "default" badge while the repo still held the old customised version —
    # the pending change hidden behind the tidiest-looking state.
    #
    # default outranks unpushed the other way round, and deliberately. Before the
    # first push nothing is on GitHub, so every untouched default file would
    # light up as "to push" and drown the handful of rows that actually changed.
    # Pushing is a repo-level act the header already prompts for; per file, what
    # matters is whether THIS machine has something the repo does not.
    if [[ "$synced" == false ]]; then sync_state="off"
    elif [[ "$exists" == false ]]; then sync_state="missing"
    elif [[ "$incoming" == true ]]; then sync_state="incoming"
    elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
    elif [[ "$is_default" == true ]]; then sync_state="default"
    elif [[ "$unpushed" == true ]]; then sync_state="unpushed"
    else sync_state="saved"
    fi
    # A shipped entry this machine has never had, and the repo has never held,
    # is not a row worth drawing. The core list is written for every Omarchy
    # user, so any one machine is expected to be missing part of it — showing
    # ghost rows for a terminal you don't use buries the files you do. It stays
    # in the list, so the day you create the file it appears; and one the repo
    # HAS a copy of always shows, because "it was here and now it isn't" is
    # exactly the kind of thing a backup tool must not hide.
    # Found automatically (another plugin's config, a module hyprland.lua
    # loads) is neither shipped nor the user's: no Untrack, and no ghost row.
    source=manifest
    if is_user_entry "$rel"; then source=user
    elif is_auto_entry "$rel"; then source=auto; label="${AUTO_LABEL[$rel]}"; fi
    if [[ "$source" != user && "$exists" == false && "$saved" == false ]]; then continue; fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$label" "$src" "$category" "$exists" "$is_default" "$has_default" \
      "$config_rel" "$dirty" "$unpushed" "$sync_state" "$saved" "$synced" "$source" "$scope" "$unsaved" \
      "$is_dir" "$nfiles" "$incoming"
  done
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], label: .[1], src: .[2],
      category: .[3], group: .[3],
      exists: (.[4]|flag), is_default: (.[5]|flag), has_default: (.[6]|flag),
      config_rel: .[7], dirty: (.[8]|flag), unpushed: (.[9]|flag),
      sync_state: .[10], saved: (.[11]|flag), synced: (.[12]|flag),
      source: .[13], scope: .[14], unsaved: (.[15]|flag),
      is_dir: (.[16]|flag), nfiles: (.[17]|tonumber? // 0),
      incoming: (.[18]|flag)
    })'
}

# Secrets get their own shape, and deliberately never their own content. What
# the panel needs is "is it here, is it saved, are the permissions right" — a
# preview of an SSH private key on screen is a way to leak it over a shoulder or
# a screen share, so the only thing read out of an env file is the NAMES of the
# variables it defines.
build_secrets_json() {
  invalidate_git_cache
  local entry src rel exists mode kind dirty unpushed saved synced sync_state vars nvars unsaved incoming
  {
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    [[ -f "$src" ]] && exists=true || exists=false
    mode=""
    [[ "$exists" == true ]] && mode=$(stat -c '%a' "$src" 2>/dev/null || echo "")
    case "$rel" in
      *.pub)  kind="public key" ;;
      ssh/*)  kind="private key" ;;
      env/*)  kind="environment" ;;
      *)      kind="secret" ;;
    esac
    vars=""; nvars=0
    if [[ "$exists" == true && "$rel" == env/* ]]; then
      vars=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*(?==)' "$src" 2>/dev/null \
             | sed -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]*//' | sort -u | paste -sd, - || true)
      [[ -z "$vars" ]] && vars=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$src" 2>/dev/null \
             | sed -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]*//' -e 's/=$//' | sort -u | paste -sd, - || true)
      [[ -n "$vars" ]] && nvars=$(printf '%s' "$vars" | tr ',' '\n' | grep -c .)
    fi
    saved=false
    [[ -f "$SECRETS_DIR/$rel" ]] && saved=true
    # Same content-first rule as the config rows. cmp reads both files but says
    # only whether they differ — no secret is read INTO a variable, printed, or
    # put in the JSON. Comparing is not revealing.
    unsaved=false
    entry_differs "$src" "$SECRETS_DIR/$rel" false && unsaved=true
    dirty=false
    path_dirty "secrets/$rel" && dirty=true
    [[ "$dirty" == true ]] && unsaved=true
    unpushed=false
    path_unpushed "secrets/$rel" && unpushed=true
    incoming=false
    [[ "$unsaved" == true ]] && is_incoming_rel "$rel" && incoming=true
    synced=true
    is_excluded "$rel" && synced=false
    if [[ "$synced" == false ]]; then sync_state="off"
    elif [[ "$exists" == false ]]; then sync_state="missing"
    elif [[ "$incoming" == true ]]; then sync_state="incoming"
    elif [[ "$unsaved" == true ]]; then sync_state="unsaved"
    elif [[ "$unpushed" == true ]]; then sync_state="unpushed"
    else sync_state="saved"
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$src" "$exists" "$mode" "$kind" "$dirty" "$unpushed" "$saved" \
      "$synced" "$sync_state" "$vars" "$nvars" "$incoming"
  done
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], src: .[1], exists: (.[2]|flag), mode: .[3], kind: .[4],
      dirty: (.[5]|flag), unpushed: (.[6]|flag), saved: (.[7]|flag),
      synced: (.[8]|flag), sync_state: .[9],
      vars: (if .[10] == "" then [] else (.[10]|split(",")) end),
      var_count: ((.[11]|tonumber?) // 0),
      incoming: (.[12]|flag)
    })'
}

# core_shortcuts — the keyboard, in two halves. Omarchy's model is "defaults,
# plus your overrides in hypr/bindings.lua", so the backup tracks the overrides
# (a snapshot of every active binding would go stale with the next update) while
# the panel shows both: what you changed, and what is actually bound right now.
core_shortcuts() {
  local own_file="$HOME/.config/hypr/bindings.lua"
  local own active
  own=$(awk '
    /^[[:space:]]*--/ { next }
    match($0, /o\.bind\(/) {
      line = $0
      n = split(line, parts, /"/)
      if (n >= 3) {
        key = parts[2]
        # o.bind(keys, description, command) — but the description is often
        # written as a bare `nil`, and then the second quoted string is the
        # COMMAND. Counting quotes alone labels every such binding with its own
        # command as its name.
        if (parts[3] ~ /,[[:space:]]*nil[[:space:]]*,/) {
          desc = ""
          cmd  = (n >= 5) ? parts[4] : ""
        } else {
          desc = (n >= 5) ? parts[4] : ""
          cmd  = (n >= 7) ? parts[6] : ""
        }
        printf "%s\t%s\t%s\tbind\n", key, desc, cmd
      }
      next
    }
    match($0, /hl\.unbind\(/) {
      n = split($0, parts, /"/)
      if (n >= 3) printf "%s\t%s\t%s\tunbind\n", parts[2], "removed", "", ""
    }
  ' "$own_file" 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
      | {key: .[0], description: .[1], command: .[2], kind: .[3]})') || true
  [[ -n "$own" ]] || own='[]'
  # `|| true` on both: with set -o pipefail, a missing bindings.lua or a failing
  # `omarchy menu keybindings` ended the whole command with no output at all.
  active=$(omarchy menu keybindings --print 2>/dev/null |
    sed -e 's/[[:space:]]*→[[:space:]]*/\t/' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
      | {key: (.[0] // "" | sub("[[:space:]]+$";"")), description: (.[1] // "")})') || true
  [[ -n "$active" ]] || active='[]'
  jq -nc --argjson own "$own" --argjson active "$active" --arg file "$own_file" \
    '{file:$file, own:$own, active:$active, own_count:($own|length), active_count:($active|length)}'
}

# How often status may hit the network on its own. The bar widget polls this
# every minute; fetching on every poll meant a git fetch a minute, forever, on
# a laptop. An explicit refresh (opening the panel, pressing the refresh
# button, finishing a write) passes --fetch and is never throttled.
FETCH_MAX_AGE=${REPLICANT_FETCH_MAX_AGE:-300}

should_fetch() {
  local stamp="$REPLICANT_HOME/.last-fetch" now age
  now=$(date +%s)
  [[ -f "$stamp" ]] || return 0
  age=$(( now - $(cat "$stamp" 2>/dev/null || echo 0) ))
  (( age >= FETCH_MAX_AGE ))
}

core_status() {
  # --brief answers only what the bar icon needs. The bar polls once a minute
  # and reads six numbers out of it; building forty kilobytes of file rows,
  # settings and categories for those six was most of the plugin's idle cost.
  # The full payload is built when the panel opens and after every write.
  local json=0 force_fetch=0 brief=0 arg
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      --fetch) force_fetch=1 ;;
      --no-fetch) force_fetch=-1 ;;
      --brief) brief=1 ;;
    esac
  done
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if (( json )); then echo '{"initialized":false}'; else echo "not initialized: run 'omarchy-replicant create --push', or 'clone <url>' for a repo you already have"; fi
    return 0
  fi
  # Best-effort refresh of origin/HEAD so unpushed/ahead/behind are accurate.
  # Never blocks when there is no network, and never runs more often than
  # FETCH_MAX_AGE unless explicitly asked.
  if (( force_fetch >= 0 )) && { (( force_fetch == 1 )) || should_fetch; }; then
    timeout 3 git -C "$REPO_DIR" fetch --quiet 2>/dev/null || true
    date +%s > "$REPLICANT_HOME/.last-fetch" 2>/dev/null || true
  fi
  local branch remote dirty untracked ahead behind
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  remote=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "")
  # One git status for both counts, not one each.
  local porcelain
  porcelain=$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)
  dirty=$(grep -c . <<<"$porcelain" || true)
  untracked=$(grep -c '^??' <<<"$porcelain" || true)
  ahead=0; behind=0
  if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    behind=$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  fi
  # Content, not git: what is on this machine that the repo has not got, and
  # which of those differences came down from another machine. Both the bar icon
  # and the panel header read these, so they can never disagree.
  local n_unsaved n_incoming
  read -r n_unsaved n_incoming < <(count_changes)
  local pending_groups=""
  path_dirty "config/"  && pending_groups="$pending_groups config"
  path_dirty "secrets/" && pending_groups="$pending_groups secrets"
  path_dirty "state/"   && pending_groups="$pending_groups state"
  if (( json && brief )); then
    jq -nc --arg branch "$branch" --arg remote "$remote" \
      --argjson dirty "$dirty" --argjson untracked "$untracked" \
      --argjson ahead "$ahead" --argjson behind "$behind" \
      --arg pending "$pending_groups" \
      --argjson unsaved "$n_unsaved" --argjson incoming "$n_incoming" \
      '{initialized:true, brief:true, branch:$branch, remote:$remote,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind,
        unsaved:$unsaved, incoming:$incoming,
        pending:$pending}'
    return 0
  fi
  if (( json )); then
    local configs_json secrets_json settings_json categories_json groups_json machines_json pending_reinstalls_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    settings_json=$(build_settings_json)
    categories_json=$(build_categories_json)
    groups_json=$(build_setting_groups_json)
    pending_reinstalls_json=$(build_pending_reinstalls_json)
    # Every machine that has ever saved into this repo, newest first. With one
    # machine it is a footnote; with two it is the answer to "did the desktop
    # actually push?", which is the whole reason the repo exists.
    machines_json=$(
      { for d in "$STATE_ROOT"/*/; do
          [[ -d "$d" ]] || continue
          local mname mwhen
          mname=$(basename "$d")
          mwhen=$(git -C "$REPO_DIR" log -1 --date=format:'%d %b %H:%M' --format='%ad' -- "state/$mname" 2>/dev/null || true)
          local mprof; mprof=$(profile_for_machine "$mname" 2>/dev/null || echo "")
          printf '%s\t%s\t%s\t%s\n' "$mname" "$mwhen" \
            "$( [[ "$mname" == "$MACHINE" ]] && echo true || echo false )" "$mprof"
        done; } | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], last_save: .[1], current: (.[2] == "true"), profile: (.[3] // "")})'
    )
    # Which profiles exist, and how many files each one is actually holding —
    # the answer to "did scoping that file to a profile do anything?".
    local profiles_json
    profiles_json=$(
      { local pr pn
        while IFS= read -r pr; do
          [[ -n "$pr" ]] || continue
          pn=$(find "$REPO_DIR/profiles/$pr/config" -type f 2>/dev/null | wc -l || true)
          printf '%s\t%s\t%s\n' "$pr" "$pn" "$( [[ "$pr" == "$(current_profile)" ]] && echo true || echo false )"
        done < <(list_profiles); } | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], files: (.[1]|tonumber? // 0), current: (.[2] == "true")})'
    )
    local remote_name="" last_save="" last_subject="" plugin_version=""
    [[ -n "$remote" ]] && remote_name="${remote##*/}" && remote_name="${remote_name%.git}"
    last_save=$(git -C "$REPO_DIR" log -1 --date=format:'%d %b %H:%M' --format='%ad' 2>/dev/null || true)
    last_subject=$(git -C "$REPO_DIR" log -1 --format='%s' 2>/dev/null || true)
    plugin_version=$(jq -r '.version // ""' "$PLUGIN_DIR/manifest.json" 2>/dev/null || true)
    jq -nc --arg branch "$branch" --arg remote "$remote" --arg remote_name "$remote_name" \
      --arg repo_dir "$REPO_DIR" --arg machine "$MACHINE" --arg plugin_version "$plugin_version" \
      --arg home "$HOME" \
      --arg last_save "$last_save" --arg last_subject "$last_subject" \
      --argjson dirty "$dirty" --argjson untracked "$untracked" --argjson ahead "$ahead" --argjson behind "$behind" \
      --argjson unsaved "$n_unsaved" --argjson incoming "$n_incoming" \
      --arg pending "$pending_groups" --argjson configs "$configs_json" --argjson secrets "$secrets_json" \
      --argjson settings "$settings_json" --argjson categories "$categories_json" \
      --argjson setting_groups "$groups_json" --argjson machines "$machines_json" \
      --arg profile "$(current_profile)" --argjson profiles "$profiles_json" \
      --argjson pending_reinstalls "$pending_reinstalls_json" \
      '{initialized:true, branch:$branch, remote:$remote, remote_name:$remote_name,
        repo_dir:$repo_dir, machine:$machine, plugin_version:$plugin_version, home:$home,
        profile:$profile, profiles:$profiles,
        last_save:$last_save, last_subject:$last_subject,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending,
        unsaved:$unsaved, incoming:$incoming,
        configs:$configs, secrets:$secrets, settings:$settings,
        categories:$categories, setting_groups:$setting_groups, machines:$machines,
        pending_reinstalls:$pending_reinstalls}'
  else
    echo "branch: $branch"
    echo "remote: ${remote:-<none>}"
    echo "dirty: $dirty pending:$pending_groups ahead/behind: $ahead/$behind"
    # The two lines someone reading this in a terminal is actually looking for,
    # and the button each one asks for.
    (( n_unsaved > 0 ))  && echo "$(plural "$n_unsaved" file) changed here and not saved — 'savegame --auto'"
    (( n_incoming > 0 )) && echo "$(plural "$n_incoming" file) came from another machine — 'restore --apply'"
    if (( dirty > 0 )); then git -C "$REPO_DIR" status --short 2>/dev/null | head -n 30; fi
  fi
}

# core_diff <id> [default|repo|auto] — plain unified diff on stdout, for the
# panel to render inline. The panel used to shell out to a floating terminal
# for this; a diff is something you read, not something you interact with, so
# it belongs in the panel next to the file it describes.
core_diff() {
  local id="$1" against="${2:-auto}" src repo_copy def
  src=$(resolve_manifest_src "$id") || { echo "unknown id: $id"; return 1; }
  # A diff is rendered in the panel, on screen, possibly while sharing it. An
  # SSH private key or a file of API tokens has no business being drawn there,
  # so secrets report whether they changed and never what changed. Public keys
  # are fine.
  # Not a name test. A user can track any file as a secret, under any name, and
  # the refusal has to follow the entry rather than the spelling.
  if [[ "$id" != *.pub ]] && is_secret_rel "$id"; then
    repo_copy=$(repo_copy_for_rel "$id")
    if [[ ! -f "$repo_copy" ]]; then echo "not saved in your repo yet"; return 0; fi
    if cmp -s "$src" "$repo_copy" 2>/dev/null; then
      echo "identical to the copy in your repo"
    else
      echo "This file differs from the copy in your repo."
      echo
      echo "Its contents are not shown: it holds a key or a token, and a diff"
      echo "on screen is a diff on any screen share or over any shoulder."
      echo "Open it yourself if you need to see it."
    fi
    return 0
  fi
  # A directory's "diff" is which files moved, not which bytes: a tree is too
  # big to render in the panel, and the useful answer is the file list.
  if is_dir_entry "$id"; then
    repo_copy=$(repo_copy_for_rel "$id")
    [[ -d "${src%/}" ]] || { echo "$src does not exist on this machine"; return 0; }
    [[ -d "${repo_copy%/}" ]] || { echo "not saved in the repo yet — press Save to GitHub to add it"; return 0; }
    if tree_same "$repo_copy" "$src"; then
      echo "identical to the copy in your repo — $(tree_count "$src") files"; return 0
    fi
    echo "# what is in your repo, next to what is on this machine"
    echo
    tree_diff_summary "$repo_copy" "$src"
    return 0
  fi
  [[ -f "$src" ]] || { echo "$src does not exist on this machine"; return 0; }
  repo_copy=$(repo_copy_for_rel "$id")
  def=$(default_for_src "$src" 2>/dev/null || true)

  if [[ "$against" == "auto" ]]; then
    if [[ -f "$repo_copy" ]] && ! cmp -s "$src" "$repo_copy"; then against="repo"; else against="default"; fi
  fi

  case "$against" in
    repo)
      [[ -f "$repo_copy" ]] || { echo "not saved in the repo yet — press Save to GitHub to add it"; return 0; }
      echo "# saved in your repo (-)  vs  this machine (+)"
      diff -u --label "repo" --label "this machine" "$repo_copy" "$src" || true
      ;;
    default)
      [[ -n "$def" ]] || { echo "no Omarchy default ships for this file — all of it is yours"; return 0; }
      if cmp -s "$src" "$def"; then echo "identical to Omarchy's default"; return 0; fi
      echo "# Omarchy default (-)  vs  this machine (+)"
      diff -u --label "omarchy default" --label "this machine" "$def" "$src" || true
      ;;
  esac
}

# core_log [n] — recent saves as JSON, for the panel's activity list.
core_log() {
  local n="${1:-8}"
  [[ -d "$REPO_DIR/.git" ]] || { echo '[]'; return 0; }
  # Runs of the same subject collapse into one row with a count. A save writes
  # an inventory commit whenever a package list moved, so four of the six rows
  # said "state: … inventory" and the two that recorded a decision the user
  # actually made were what fell off the bottom. Read more than we show, so
  # collapsing lengthens the history instead of shortening the list.
  git -C "$REPO_DIR" log -n "$(( n * 4 ))" --date=format:'%d %b %H:%M' \
      --pretty=format:'%H%x1f%ad%x1f%s%x1f%an' 2>/dev/null |
    jq -Rsc --argjson n "$n" 'split("\n") | map(select(length > 0) | split("\u001f")
             | {sha: .[0][0:7], date: .[1], subject: .[2], author: .[3], count: 1})
             | reduce .[] as $c ([];
                 if (length > 0 and .[-1].subject == $c.subject)
                 then .[0:-1] + [.[-1] * {count: (.[-1].count + 1)}]
                 else . + [$c] end)
             | .[0:$n]'
}
