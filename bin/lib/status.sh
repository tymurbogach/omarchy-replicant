# shellcheck shell=bash disable=SC2034
# status.sh: the JSON that the panel and the bar read, the diff and the log.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

build_configs_json() {
  invalidate_git_cache
  # One jq for the whole list. Same reason as build_settings_json: this runs on
  # every panel refresh and there are forty-odd rows.
  local entry src rel label category exists is_default has_default default_src config_rel
  local dirty unpushed sync_state saved synced source scope unsaved is_dir nfiles size incoming
  local regrow ev
  # Every row below comes from the registry and the one evaluator: the scope,
  # the repo path, the comparison and the precedence live there, not here.
  registry_build
  {
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"; label="$rel"
    regrow=$(registry_row_for "$rel") || { printf 'registry: no row for %s\n' "$rel" >&2; continue; }
    ev=$(state_eval "$regrow")
    local -a vf=()
    mapfile -t vf < <(row_split "$ev" 17)
    category="${vf[3]}"; scope="${vf[4]}"
    exists="${vf[9]}"; saved="${vf[10]}"; is_default="${vf[11]}"
    dirty="${vf[12]}"; unsaved="${vf[13]}"; unpushed="${vf[14]}"; incoming="${vf[15]}"
    sync_state="${vf[16]}"
    is_dir=false; nfiles=0; size=0
    is_dir_entry "$rel" && is_dir=true
    if [[ "$exists" == true ]]; then
      if [[ "$is_dir" == true ]]; then
        nfiles=$(tree_count "$src")
        size=$(find "${src%/}" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
      else
        size=$(stat -c '%s' -- "$src" 2>/dev/null || echo 0)
      fi
    fi
    has_default=false; default_src=""
    if [[ "$is_dir" == false ]] && default_src=$(default_for_src "$src" 2>/dev/null) && [[ -n "$default_src" ]]; then has_default=true; fi
    config_rel=""
    [[ "$is_dir" == false ]] && config_rel=$(config_rel_for_src "$src" 2>/dev/null || true)
    synced=true
    [[ "$scope" == "off" ]] && synced=false
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
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$label" "$src" "$category" "$exists" "$is_default" "$has_default" \
      "$config_rel" "$dirty" "$unpushed" "$sync_state" "$saved" "$synced" "$source" "$scope" "$unsaved" \
      "$is_dir" "$nfiles" "$size" "$incoming"
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
      is_dir: (.[16]|flag), nfiles: (.[17]|tonumber? // 0), size: (.[18]|tonumber? // 0),
      incoming: (.[19]|flag)
    })'
}

# Secrets get their own shape, and deliberately never their own content. What
# the panel needs is "is it here, is it saved, are the permissions right" — a
# preview of an SSH private key on screen is a way to leak it over a shoulder or
# a screen share. In version 1 the panel also read the NAMES of variables in an
# env file. In version 2 even the names stay inside the vault: the JSON carries
# only a count, never names or values.
build_secrets_json() {
  invalidate_git_cache
  local entry src rel exists mode kind dirty unpushed saved synced sync_state vars nvars unsaved incoming locked
  local regrow ev
  local -a vf=()
  # The verdict comes from the one evaluator; only names, counts and modes
  # stay here, since they never leave the live file for the JSON.
  registry_build
  {
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    regrow=$(registry_row_for "$rel") || { printf 'registry: no row for %s\n' "$rel" >&2; continue; }
    ev=$(state_eval "$regrow")
    mapfile -t vf < <(row_split "$ev" 17)
    exists="${vf[9]}"; saved="${vf[10]}"
    dirty="${vf[12]}"; unsaved="${vf[13]}"; unpushed="${vf[14]}"; incoming="${vf[15]}"
    sync_state="${vf[16]}"; locked="${vf[8]}"
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
    # Version 2 never reports variable names. The count stays: it says how
    # many entries an env file holds without naming any of them. A locked
    # row reports no count either, since even the live names are not shown
    # without the key.
    if [[ "$(repo_data_version 2>/dev/null)" == 2 ]]; then
      if [[ "$locked" == "true" ]]; then
        vars=""; nvars=0
      else
        vars=""
      fi
    fi
    synced=true
    is_excluded "$rel" && synced=false
    [[ "$synced" == false ]] && sync_state="off"
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
      "$rel" "$src" "$exists" "$mode" "$kind" "$dirty" "$unpushed" "$saved" \
      "$synced" "$sync_state" "$vars" "$nvars" "$incoming" "$locked"
  done
  } | jq -Rsc '
    def flag: . == "true";
    split("\n") | map(select(length > 0) | split("\u001f") | {
      id: .[0], src: .[1], exists: (.[2]|flag), mode: .[3], kind: .[4],
      dirty: (.[5]|flag), unpushed: (.[6]|flag), saved: (.[7]|flag),
      synced: (.[8]|flag), sync_state: .[9],
      vars: (if .[10] == "" then [] else (.[10]|split(",")) end),
      var_count: ((.[11]|tonumber?) // 0),
      incoming: (.[12]|flag), locked: (.[13]|flag)
    })'
}

# build_entries_json: the version 2 wire contract. The compatibility arrays
# above remain for one release, but new consumers read this single list.
# Secret paths stay private while the vault is locked.
build_entries_json() {
  invalidate_git_cache
  registry_build
  local row ev id kind source category scope live repo locked exists saved is_default
  local dirty unpushed incoming sync_state is_dir nfiles size label mapped_source
  local -a vf=()
  {
    for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
      id=$(registry_field "$row" 1); kind=$(registry_field "$row" 2)
      source=$(registry_field "$row" 3); category=$(registry_field "$row" 4)
      scope=$(registry_field "$row" 5); live=$(registry_field "$row" 6)
      repo=$(registry_field "$row" 7); locked=$(registry_field "$row" 9)
      ev=$(state_eval "$row")
      mapfile -t vf < <(row_split "$ev" 17)
      exists="${vf[9]}"; is_default="${vf[11]}"; dirty="${vf[12]}"
      unpushed="${vf[14]}"; incoming="${vf[15]}"; sync_state="${vf[16]}"
      [[ "$sync_state" == locked ]] && locked=true
      is_dir=false; nfiles=0; size=0
      [[ "$kind" == dir ]] && is_dir=true
      if [[ "$is_dir" == true && "$exists" == true ]]; then
        nfiles=$(tree_count "$live" 2>/dev/null || echo 0)
        size=$(find "${live%/}" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
      elif [[ "$exists" == true && "$kind" != secret ]]; then
        size=$(stat -c '%s' -- "$live" 2>/dev/null || echo 0)
      fi
      # state_eval cannot inspect an encrypted index without the key. The
      # index itself still proves that a locked v2 secret has a saved copy.
      saved="${vf[10]}"
      if [[ "$kind" == secret && "$locked" == true && -f "$REPO_DIR/vault/index.age" ]]; then
        saved=true
      fi
      label="$id"
      [[ "$source" == auto ]] && label="${AUTO_LABEL[$id]:-$id}"
      mapped_source=user
      [[ "$source" != user ]] && mapped_source=override
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "$id" "$label" "$live" "$kind" "$mapped_source" "$category" "$scope" \
        "$exists" "$saved" "$is_default" "$dirty" "$unpushed" "$incoming" "$sync_state" \
        "$is_dir" "$nfiles" "$size" "$locked" "$REMOTE_STATE"
    done
  } | jq -Rsc '
    def flag: . == "true";
    def row:
      split("\u001f") as $r |
      {id:$r[0], label:$r[1], src:$r[2], kind:$r[3], source:$r[4], category:$r[5],
       scope:$r[6], exists:($r[7]|flag), saved:($r[8]|flag), is_default:($r[9]|flag),
       dirty:($r[10]|flag), unpushed:($r[11]|flag), incoming:($r[12]|flag),
       sync_state:$r[13], is_dir:($r[14]|flag), nfiles:(($r[15]|tonumber?) // 0),
       size:(($r[16]|tonumber?) // 0), locked:(($r[17]|flag) or $r[13] == "locked"),
       remote_state:$r[18]}
      | if .kind == "secret" and .locked then del(.src) else . end;
    split("\n") | map(select(length > 0 and . != "false") | row)'
}

status_encryption_json() {
  local state=unconfigured v
  v=$(repo_data_version 2>/dev/null || echo 1)
  if [[ "$v" == 2 && -f "$REPO_DIR/.replicant/recipient.txt" ]]; then
    if vault_unlocked; then state=ready; else state=locked; fi
  fi
  jq -nc --arg state "$state" '{format:"age-pq-v1",state:$state}'
}

status_migration_json() {
  local v required=false warning=false data_version=null
  v=$(repo_data_version 2>/dev/null || echo unknown)
  [[ "$v" =~ ^[0-9]+$ ]] && data_version="$v"
  [[ "$v" == 1 ]] && required=true
  [[ -f "$REPLICANT_HOME/migration-warning" ]] && warning=true
  jq -nc --argjson data_version "$data_version" --argjson required "$required" --argjson warning "$warning" \
    '{data_version:$data_version,required:$required,legacy_warning:$warning}'
}

# core_changes: read-only review of the worktree. The CLI only delegates here
# and keeps ownership of its user-facing command syntax.
core_changes() {
  [[ -e "$REPO_DIR/.git" ]] || {
    echo "no repo yet — run 'create' or 'clone' first" >&2
    return 1
  }
  local pending staged
  pending=$(git -C "$REPO_DIR" status --short 2>/dev/null | head -n 100)
  if [[ -z "$pending" ]]; then
    echo "nothing pending — everything copied in is committed" >&2
  else
    printf '%s\n' "$pending"
  fi
  staged=$(git -C "$REPO_DIR" diff --cached --stat 2>/dev/null | head -n 100)
  if [[ -n "$staged" ]]; then
    echo "--- staged ---" >&2
    printf '%s\n' "$staged" >&2
  fi
  if [[ -n "$pending$staged" ]]; then
    echo "To save it: 'save --all -m \"why\"', or 'save --id <id> -m \"why\"' for one entry." >&2
  fi
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
  if [[ ! -e "$REPO_DIR/.git" ]]; then
    if (( json )); then echo '{"initialized":false}'; else echo "not initialized: run 'omarchy-replicant create --push', or 'clone <url>' for a repo you already have"; fi
    return 0
  fi
  # Best-effort refresh of origin/HEAD so unpushed/ahead/behind are accurate.
  # Never blocks when there is no network, and never runs more often than
  # FETCH_MAX_AGE unless explicitly asked.
  if (( force_fetch >= 0 )) && { (( force_fetch == 1 )) || should_fetch; }; then
    if timeout 3 git -C "$REPO_DIR" fetch --quiet 2>/dev/null; then
      REMOTE_FETCH_OK=1
    else
      REMOTE_FETCH_OK=0
    fi
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
  [[ "$ahead" =~ ^[0-9]+$ ]] || ahead=0
  [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
  REMOTE_STATE=$(remote_state_for "$remote" "$([[ "$REMOTE_FETCH_OK" == 1 ]] && echo true || echo false)" "$ahead" "$behind")
  # Content, not git: what is on this machine that the repo has not got, and
  # which of those differences came down from another machine. Both the bar icon
  # and the panel header read these, so they can never disagree. The brief path
  # below reuses the metadata cache; the full payload always evaluates bytes
  # directly and stays authoritative.
  local n_unsaved n_incoming n_locked n_missing needs_action=false
  # The cache serves the brief poll only: the condition short-circuits before
  # the read when this is a full status, so full evaluation never touches it.
  local cached_na=false
  if (( brief )) && read -r n_unsaved n_incoming n_locked n_missing cached_na < <(briefcache_read 2>/dev/null); then
    n_locked=${n_locked:-0}
    n_missing=${n_missing:-0}
    [[ "$cached_na" == "true" ]] && needs_action=true
  else
    read -r n_unsaved n_incoming n_locked n_missing < <(count_changes)
    n_locked=${n_locked:-0}
    n_missing=${n_missing:-0}
    # One flag for "anything asks for an action", so the bar and the panel test
    # one boolean instead of reimplementing the priority each.
    (( n_unsaved > 0 || n_incoming > 0 || n_locked > 0 || n_missing > 0 )) && needs_action=true
    (( brief )) && briefcache_write "$n_unsaved" "$n_incoming" "$n_locked" "$n_missing" "$needs_action" 2>/dev/null || true
  fi
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
      --argjson locked "$n_locked" --argjson missing "$n_missing" \
      --argjson needs_action "$needs_action" \
      '{initialized:true, brief:true, branch:$branch, remote:$remote,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind,
        unsaved:$unsaved, incoming:$incoming, locked:$locked, missing:$missing,
        needs_action:$needs_action,
        pending:$pending}'
    return 0
  fi
  if (( json )); then
    local configs_json secrets_json entries_json settings_json categories_json groups_json machines_json pending_reinstalls_json plugins_json
    configs_json=$(build_configs_json)
    secrets_json=$(build_secrets_json)
    entries_json=$(build_entries_json)
    settings_json=$(build_settings_json)
    categories_json=$(build_categories_json)
    groups_json=$(build_setting_groups_json)
    pending_reinstalls_json=$(build_pending_reinstalls_json)
    plugins_json=$(build_plugins_json)
    local counts_json encryption_json migration_json
    counts_json=$(jq -nc --argjson entries "$entries_json" \
      '{unsaved:([$entries[] | select(.sync_state == "unsaved")]|length),
        incoming:([$entries[] | select(.sync_state == "incoming")]|length),
        locked:([$entries[] | select(.sync_state == "locked")]|length),
        missing:([$entries[] | select(.sync_state == "missing")]|length),
        unpushed:([$entries[] | select(.unpushed == true)]|length),
        needs_action:([$entries[] | select(.sync_state == "unsaved" or .sync_state == "incoming" or .sync_state == "locked" or .sync_state == "missing" or .sync_state == "unpushed")]|length) > 0,
        ahead:0, behind:0}')
    counts_json=$(jq -nc --argjson c "$counts_json" --argjson a "$ahead" --argjson b "$behind" \
      '$c + {ahead:$a,behind:$b}')
    encryption_json=$(status_encryption_json)
    migration_json=$(status_migration_json)
    # Every machine that has ever saved into this repo, newest first. With one
    # machine it is a footnote; with two it is the answer to "did the desktop
    # actually push?", which is the whole reason the repo exists.
    machines_json=$(
      { for d in "$STATE_ROOT"/*/; do
          [[ -d "$d" ]] || continue
          local mname mwhen
          mname=$(basename "$d")
          mwhen=$(git -C "$REPO_DIR" log -1 --date=format:'%d %b %H:%M' --format='%ad' -- "state/$mname" 2>/dev/null || true)
          # The epoch too: the panel says "2 hours ago", which is the question.
          local mepoch; mepoch=$(git -C "$REPO_DIR" log -1 --format='%at' -- "state/$mname" 2>/dev/null || true)
          local mprof; mprof=$(profile_for_machine "$mname" 2>/dev/null || echo "")
          printf '%s\t%s\t%s\t%s\t%s\n' "$mname" "$mwhen" \
            "$( [[ "$mname" == "$MACHINE" ]] && echo true || echo false )" "$mprof" "${mepoch:-0}"
        done; } | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], last_save: .[1], current: (.[2] == "true"), profile: (.[3] // ""),
             last_epoch: (.[4] | tonumber? // 0)})'
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
      --arg remote_state "$REMOTE_STATE" \
      --arg repo_dir "$REPO_DIR" --arg machine "$MACHINE" --arg plugin_version "$plugin_version" \
      --arg home "$HOME" \
      --arg last_save "$last_save" --arg last_subject "$last_subject" \
      --argjson dirty "$dirty" --argjson untracked "$untracked" --argjson ahead "$ahead" --argjson behind "$behind" \
      --argjson unsaved "$n_unsaved" --argjson incoming "$n_incoming" \
      --argjson locked "$n_locked" --argjson missing "$n_missing" \
      --argjson needs_action "$needs_action" --argjson entries "$entries_json" \
      --argjson counts "$counts_json" --argjson encryption "$encryption_json" \
      --argjson migration "$migration_json" \
      --arg pending "$pending_groups" --argjson configs "$configs_json" --argjson secrets "$secrets_json" \
      --argjson settings "$settings_json" --argjson categories "$categories_json" \
      --argjson setting_groups "$groups_json" --argjson machines "$machines_json" \
      --arg profile "$(current_profile)" --argjson profiles "$profiles_json" \
      --argjson pending_reinstalls "$pending_reinstalls_json" --argjson plugins "$plugins_json" \
      '{initialized:true, schema_version:2, branch:$branch, remote:$remote, remote_name:$remote_name, remote_state:$remote_state,
        repo_dir:$repo_dir, machine:$machine, plugin_version:$plugin_version, home:$home,
        profile:$profile, profiles:$profiles,
        last_save:$last_save, last_subject:$last_subject,
        dirty:$dirty, untracked:$untracked, ahead:$ahead, behind:$behind, pending:$pending,
        unsaved:$unsaved, incoming:$incoming, locked:$locked, missing:$missing,
        needs_action:$needs_action, counts:$counts, encryption:$encryption, migration:$migration,
        entries:$entries, configs:$configs, secrets:$secrets, settings:$settings,
        categories:$categories, setting_groups:$setting_groups, machines:$machines,
        pending_reinstalls:$pending_reinstalls, plugins:$plugins}'
  else
    echo "branch: $branch"
    echo "remote: ${remote:-<none>}"
    echo "dirty: $dirty pending:$pending_groups ahead/behind: $ahead/$behind"
    # The two lines someone reading this in a terminal is actually looking for,
    # and the button each one asks for.
    (( n_unsaved > 0 ))  && echo "$(plural "$n_unsaved" file) changed here and not saved — 'savegame --auto'"
    (( n_incoming > 0 )) && echo "$(plural "$n_incoming" file) came from another machine — 'restore --apply'"
    (( n_locked > 0 )) && echo "$(plural "$n_locked" secret) locked — 'key import <source>' or 'key status'"
    (( n_missing > 0 )) && echo "$(plural "$n_missing" file) saved in your repo but not on this machine — 'restore --apply' or 'forget <id>'"
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
  # The verdict is the evaluator's; this function only renders it. A diff is
  # rendered in the panel, on screen, possibly while sharing it. An SSH
  # private key or a file of API tokens has no business being drawn there, so
  # secrets report whether they changed and never what changed. Public keys
  # are fine.
  # Not a name test. A user can track any file as a secret, under any name, and
  # the refusal has to follow the entry rather than the spelling.
  if [[ "$id" != *.pub ]] && is_secret_rel "$id"; then
    registry_build
    local regrow facts same_v locked_v repo_v
    same_v=false; locked_v=false; repo_v=false
    if regrow=$(registry_row_for "$id" 2>/dev/null); then
      local line k v
      while IFS='=' read -r k v; do
        case "$k" in
          same) same_v="$v" ;; locked) locked_v="$v" ;; repo) repo_v="$v" ;;
        esac
      done < <(state_facts "$regrow")
    fi
    if [[ "$(repo_data_version)" == 2 ]]; then
      case "$locked_v:$same_v" in
        *:true) echo "identical to the copy in your repo"; return 0 ;;
        true:*) echo "This secret is locked on this machine: import the key to compare it." ;;
        *) echo "This file differs from the copy in your repo." ;;
      esac
      echo
      echo "Its contents are not shown: it holds a key or a token, and a diff"
      echo "on screen is a diff on any screen share or over any shoulder."
      echo "Open it yourself if you need to see it."
      return 0
    fi
    repo_copy=$(repo_copy_for_rel "$id")
    if [[ ! -f "$repo_copy" ]]; then echo "not saved in your repo yet"; return 0; fi
    if [[ "$same_v" == true ]]; then
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
    registry_build
    local live_v=false repo_v=false same_v=false
    repo_copy=$(repo_copy_for_rel "$id")
    if regrow=$(registry_row_for "$id" 2>/dev/null); then
      local line k v
      while IFS='=' read -r k v; do
        case "$k" in
          live) live_v="$v" ;; repo) repo_v="$v" ;; same) same_v="$v" ;;
        esac
      done < <(state_facts "$regrow")
    fi
    [[ "$live_v" == true ]] || { echo "$src does not exist on this machine"; return 0; }
    [[ "$repo_v" == true ]] || { echo "not saved in the repo yet — press Save to GitHub to add it"; return 0; }
    if [[ "$same_v" == true ]]; then
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
    if [[ -f "$repo_copy" ]]; then
      registry_build
      if regrow=$(registry_row_for "$id" 2>/dev/null) \
        && [[ "$(state_facts "$regrow" | grep -c '^same=true$' || true)" == 0 ]]; then
        against="repo"
      else
        against="default"
      fi
    else
      against="default"
    fi
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
  [[ -e "$REPO_DIR/.git" ]] || { echo '[]'; return 0; }
  # Runs of the same subject collapse into one row with a count. A save writes
  # an inventory commit whenever a package list moved, so four of the six rows
  # said "state: … inventory" and the two that recorded a decision the user
  # actually made were what fell off the bottom. Read more than we show, so
  # collapsing lengthens the history instead of shortening the list.
  #
  # Each save also names the files it touched, so the panel can open a big one
  # and show them. A collapsed run names every file of the run once. Names only:
  # a path is on screen in the Configs tab already, and a secret's contents
  # never reach a commit, let alone this list.
  git -C "$REPO_DIR" log -n "$(( n * 4 ))" --date=format:'%d %b %H:%M' --name-status \
      --format=$'\x1e%H\x1f%ad\x1f%s\x1f%an\x1f%at' 2>/dev/null |
    jq -Rsc --argjson n "$n" '
      split("\u001e") | map(select(length > 0) | split("\n") | map(select(length > 0))
        | (.[0] | split("\u001f")) as $h
        | {sha: $h[0][0:7], date: $h[1], subject: $h[2], author: $h[3],
           epoch: ($h[4] | tonumber? // 0), count: 1,
           files: (.[1:] | map(split("\t") | {status: .[0][0:1], path: .[-1]}))})
      | reduce .[] as $c ([];
          if (length > 0 and .[-1].subject == $c.subject)
          then .[0:-1] + [.[-1] * {count: (.[-1].count + 1),
                                   files: ((.[-1].files + $c.files) | unique_by(.path))}]
          else . + [$c] end)
      | .[0:$n] | map(.nfiles = (.files | length) | .files = .files[0:60])'
}
