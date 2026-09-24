# shellcheck shell=bash disable=SC2034
# restore.sh: restoring: the plan per area, and how each area is put back.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

core_restore_command() {
  local dry="$1" all="$2" yes="$3" only="$4" cat centry label changed total_changed=0
  local -a pending=()
  [[ -d "$REPO_DIR/.git" ]] || { echo "no repo" >&2; return 1; }
  if [[ -n "$only" ]] && ! find_category "$only" >/dev/null; then
    echo "unknown area: $only" >&2; return 1
  fi
  for cat in "${CATEGORY_ORDER[@]}"; do
    [[ -n "$only" && "$only" != "$cat" ]] && continue
    centry=$(find_category "$cat") || continue
    label=$(category_field "$centry" 3)
    printf '\n== %s · %s\n' "$cat" "$label" >&2
    restore_area_extras "$cat" "$dry"
    mapfile -t pending < <(restore_pending "$cat")
    (( ${#pending[@]} )) || { echo "· nothing to change" >&2; continue; }
    restore_preview "${pending[@]}"
    if (( dry )); then echo "· dry-run: untouched. Repeat with --apply" >&2; continue; fi
    if (( ! all && ! yes )); then
      [[ -r /dev/tty ]] || { echo "$cat needs --yes" >&2; continue; }
      local resp
      read -rp "  apply $cat? [y/N] " resp </dev/tty 2>&1 || resp=""
      [[ "$resp" == [yY] ]] || { echo "· $cat skipped" >&2; continue; }
    fi
    changed=$(restore_apply "$cat" "${pending[@]}")
    total_changed=$((total_changed + changed))
  done
  if (( dry )); then echo "Dry-run; repeat with --apply" >&2
  else briefcache_invalidate; echo "restore complete; $total_changed file(s) written" >&2
  fi
}

# Parse the public restore options in the core so the CLI only forwards them.
core_restore_cli() {
  local dry=1 all=0 yes=0 only="" arg
  while (( $# )); do
    arg="$1"; shift
    case "$arg" in
      --apply) dry=0 ;;
      --dry-run) dry=1 ;;
      --all) all=1 ;;
      --yes|-y) yes=1 ;;
      --only) [[ $# -gt 0 ]] || { echo "--only needs an area" >&2; return 2; }; only="$1"; shift ;;
      *) echo "unknown option: $arg" >&2; return 2 ;;
    esac
  done
  if [[ -n "$only" ]] && ! find_category "$only" >/dev/null; then
    echo "unknown area: $only (areas: ${CATEGORY_ORDER[*]})" >&2
    return 1
  fi
  core_restore_command "$dry" "$all" "$yes" "$only"
}

core_reset_command() {
  local apply="$1" yes="$2" entry src rel crel resp failures=0 i
  local -a candidates=() rels=()
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    is_dir_entry "$rel" && continue
    [[ -f "$src" ]] || continue
    default_for_src "$src" >/dev/null || continue
    is_default_file "$src" && continue
    crel=$(config_rel_for_src "$src") || continue
    candidates+=("$rel"); rels+=("$crel")
  done
  (( ${#candidates[@]} )) || { echo "reset-all: nothing to reset" >&2; return 0; }
  echo "reset-all: ${#candidates[@]} non-default file(s)" >&2
  (( apply )) || { echo "Dry-run; repeat with --apply" >&2; return 0; }
  if (( ! yes )); then
    read -rp "Restore files to Omarchy defaults? [y/N] " resp </dev/tty 2>&1 || resp=""
    [[ "$resp" == [yY] ]] || { echo "reset-all cancelled" >&2; return 0; }
  fi
  for i in "${!rels[@]}"; do omarchy refresh config "${rels[$i]}" >/dev/null 2>&1 || failures=$((failures + 1)); done
  (( failures == 0 )) || { echo "reset-all: $failures failure(s)" >&2; return 1; }
  echo "reset-all complete" >&2
}

core_reset_cli() {
  local apply=0 yes=0 arg
  while (( $# )); do
    arg="$1"; shift
    case "$arg" in
      --apply) apply=1 ;;
      --dry-run) apply=0 ;;
      --yes|-y) yes=1 ;;
      *) echo "unknown option: $arg" >&2; return 2 ;;
    esac
  done
  core_reset_command "$apply" "$yes"
}

core_reset_one() {
  local id="$1" src rel
  [[ -n "$id" ]] || { echo "usage: reset <id>" >&2; return 1; }
  src=$(resolve_manifest_src "$id") || { echo "unknown id: $id" >&2; return 1; }
  is_dir_entry "$id" && { echo "$id is a directory; use restore-file" >&2; return 1; }
  default_for_src "$src" >/dev/null || { echo "$id has no Omarchy default" >&2; return 1; }
  rel=$(config_rel_for_src "$src") || { echo "$id is outside ~/.config" >&2; return 1; }
  command -v omarchy >/dev/null 2>&1 || { echo "omarchy not found" >&2; return 1; }
  omarchy refresh config "$rel" 2>&1 || return 1
  echo "reset $rel; previous version kept as .bak.<epoch>" >&2
}

# ─── Restore planning — derived from MANIFEST, never hand-listed ────────────
# The restore plan used to be a second, hand-written copy of the manifest inside
# the CLI. Adding a file to MANIFEST then silently did not restore it, which is
# the worst kind of backup bug: it looks like it worked right up until you need
# it. Everything below is computed from the one list.
#
# Mode is decided by where the file goes, not by what it is called:
# secrets are 600, anything under bin/ or a hooks/ directory has to stay
# executable, and everything else is 644.
restore_mode_for() {
  case "$1" in
    *.pub) echo 644; return ;;
    ssh/config) echo 600; return ;;
  esac
  # Anything the repo holds as a secret is restored as one, whatever it is
  # called. Keying on the name alone put a tracked API token back at 644.
  is_secret_rel "$1" && { echo 600; return; }
  case "$1" in
    bin/*|*/hooks/*|*.hook)  echo 755 ;;
    *)                       echo 644 ;;
  esac
}

# plan_for_category <category> — "repo-path|destination|mode" per line.
# Skips what the user switched off, what the repo does not have a copy of, and
# theme.name (a theme is replayed through omarchy-theme-set, not copied).
# The ids come from the registry, so the plan and the panel rows agree on what
# exists; the secrets tail below keeps its own loop, since v2 secrets restore
# through the vault and never through a repo path.
plan_for_category() {
  local want="$1" row id kind cat scope live repo
  local -a rf=()
  registry_build
  for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
    mapfile -t rf < <(row_split "$row" 9)
    id="${rf[0]}"; kind="${rf[1]}"; cat="${rf[3]}"; scope="${rf[4]}"; live="${rf[5]}"; repo="${rf[6]}"
    [[ "$kind" == "secret" ]] && continue
    [[ "$id" == "omarchy/theme.name" ]] && continue
    [[ "$cat" == "$want" ]] || continue
    [[ "$scope" == "off" ]] && continue
    # A directory keeps its trailing slash all the way through the plan, which
    # is how the restore loop knows to walk a tree instead of copying a file.
    if [[ "$kind" == "dir" ]]; then
      [[ -d "${repo%/}" ]] || continue
      printf '%s|%s|%s\n' "${repo%/}/" "${live%/}/" "$(restore_mode_for "$id")"
      continue
    fi
    [[ -f "$repo" ]] || continue
    printf '%s|%s|%s\n' "$repo" "$live" "$(restore_mode_for "$id")"
  done
  # A settings plugin that writes a Hyprland module keeps its own store: the
  # OmaSettings window writes hypr/omasettings.lua from plugins/omasettings.json.
  # Restoring Hyprland alone brought the module back without the store, so the
  # plugin's window showed the old values, and its next write put them back.
  if [[ "$want" == "hyprland" ]]; then
    local mrow mid mrel prel pscope plive prepo prow
    local -a prf=()
    for mrow in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
      mapfile -t prf < <(row_split "$mrow" 9)
      mid="${prf[0]}"
      [[ "${prf[1]}" == "secret" ]] && continue
      [[ "$mid" == hypr/*.lua ]] || continue
      mrel="$mid"
      prel="plugins/${mrel##*/}"; prel="${prel%.lua}.json"
      prow=$(registry_row_for "$prel" 2>/dev/null) || continue
      mapfile -t prf < <(row_split "$prow" 9)
      pscope="${prf[4]}"; plive="${prf[5]}"; prepo="${prf[6]}"
      [[ "$pscope" == "off" ]] && continue
      [[ -f "$prepo" ]] || continue
      printf '%s|%s|%s\n' "$prepo" "$plive" "$(restore_mode_for "$prel")"
    done
  fi
  [[ "$want" == "secrets" ]] || return 0
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    is_excluded "$rel" && continue
    repo_path="$SECRETS_DIR/$rel"
    [[ -f "$repo_path" ]] || continue
    printf '%s|%s|%s\n' "$repo_path" "$src" "$(restore_mode_for "$rel")"
  done
}

# What has to run for a restored category to actually take effect. Copying a
# file into ~/.config and calling it done is the difference between a backup
# tool and a restore tool.
apply_for_category() {
  case "$1" in
    shortcuts|hyprland) echo "hyprctl reload" ;;
    terminal)           echo "omarchy restart terminal" ;;
    system)             echo "systemctl daemon-reload" ;;
    *)                  echo "" ;;
  esac
}

# ─── Restore, one area at a time ────────────────────────────────────────────
# The mechanism of `restore`: what is pending in an area, what it would
# change, and how to put it back. The CLI keeps the policy: its options, the
# two confirmations and the messages around them.

# The CLI defines warn with the same look. This one is for the core alone.
declare -F warn >/dev/null || warn() { echo -e "\e[33m$*\e[0m" >&2; }

# restore_area_extras <area> <dry>: what an area needs besides its files. The
# theme rides with appearance, and it is applied, never copied. A third-party
# theme or plugin is only named: neither `omarchy theme install` nor `omarchy
# plugin add` takes a commit to pin, so fetching one stays an explicit command
# (the 2026-09 marketplace security review).
restore_area_extras() {
  local area="$1" dry="$2" name _ n=0
  case "$area" in
    appearance)
      while IFS=$'\t' read -r name _; do
        [[ -n "$name" ]] || continue
        n=$((n + 1))
        skip "$name — third-party theme, not auto-installed: omarchy-replicant install-theme $name"
      done < <(missing_themes)
      (( n == 0 )) && skip "every theme in the inventory is already installed"
      restore_active_theme "$dry" ;;
    plugins)
      while IFS=$'\t' read -r name _; do
        [[ -n "$name" ]] || continue
        n=$((n + 1))
        skip "$name — third-party plugin, not auto-installed: omarchy-replicant install-plugin $name"
      done < <(missing_plugins)
      (( n == 0 )) && skip "every plugin in the inventory is already installed" ;;
  esac
  return 0
}

# restore_active_theme <dry>: apply the theme the repo records, through
# omarchy-theme-set. The name is compared normalised: omarchy-theme-current
# answers "Enter The Matrix", and the file records "enter-the-matrix".
restore_active_theme() {
  local dry="$1" want current wnorm cnorm
  # Through repo_path_for, because theme.name can be scoped to a profile.
  want=$(head -n1 "$(repo_path_for omarchy/theme.name)" 2>/dev/null | tr -d '\r' || true)
  if [[ -z "$want" ]]; then skip "no theme recorded in the repo"; return 0; fi
  current=$(omarchy-theme-current 2>/dev/null || echo "")
  wnorm=$(tr -cd '[:alnum:]' <<<"${want,,}")
  cnorm=$(tr -cd '[:alnum:]' <<<"${current,,}")
  if [[ -n "$wnorm" && "$wnorm" == "$cnorm" ]]; then ok "$want (already applied)"; return 0; fi
  if (( dry )); then skip "dry-run: would apply theme '$want' (currently '${current:-unknown}')"; return 0; fi
  if command -v omarchy-theme-set >/dev/null 2>&1; then
    if omarchy-theme-set "$want" >/dev/null 2>&1; then ok "theme -> $want"
    else warn "could not apply theme '$want' — if it is not installed here: omarchy-replicant install-theme $want"; fi
  else
    warn "omarchy-theme-set not found"
  fi
}

# restore_pending <area>: "repo-path|destination|mode" for each entry that a
# restore would write. What already matches, or needs root, is said on stderr.
# Outside $HOME needs root, and a backup tool that asks for a password without
# a word is worse than one that prints the command.
restore_pending() {
  local area="$1" src dst mode
  while IFS='|' read -r src dst mode; do
    if [[ "$src" == */ ]]; then
      [[ -d "${src%/}" ]] || continue
      if tree_same "$src" "$dst"; then ok "${dst/#$HOME/\~} (already matches, $(tree_count "$src") files)"
      else printf '%s|%s|%s\n' "$src" "$dst" "$mode"; fi
      continue
    fi
    [[ -f "$src" ]] || continue
    if [[ "$dst" != "$HOME"/* ]]; then
      if [[ -f "$dst" ]] && cmp -s "$src" "$dst" 2>/dev/null; then ok "$dst (already matches)"
      else warn "$dst needs root — run: sudo install -m $mode $src $dst"; fi
      continue
    fi
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst" 2>/dev/null; then ok "${dst/#$HOME/\~} (already matches)"
    else printf '%s|%s|%s\n' "$src" "$dst" "$mode"; fi
  done < <(plan_for_category "$area")
}

# restore_preview <entry>...: what each pending entry would change, on stderr.
restore_preview() {
  local e src dst mode
  for e in "$@"; do
    IFS='|' read -r src dst mode <<<"$e"
    echo "  ── ${dst/#$HOME/\~}" >&2
    if [[ "$src" == */ ]]; then
      tree_diff_summary "$src" "$dst" | sed 's/^/      /' >&2
    elif [[ -f $dst ]]; then
      diff -u --label system --label repo "$dst" "$src" 2>/dev/null | sed -n '3,40p' | sed 's/^/      /' >&2 || true
    else
      echo "      (doesn't exist: would be created)" >&2
    fi
  done
}

# restore_apply <area> <entry>...: write each entry, keeping a .bak.<epoch> of
# what it replaces, then run what makes the area take effect. Hyprland does not
# re-read its Lua on its own, and a restored terminal config is invisible until
# the terminal is told. Prints the number of entries written, on stdout.
restore_apply() {
  require_writable_schema || return 1
  briefcache_invalidate
  local area="$1" e src dst mode changed=0 apply errs DRY=0
  shift
  for e in "$@"; do
    IFS='|' read -r src dst mode <<<"$e"
    if [[ "$src" == */ ]]; then install_tree "$src" "$dst" "$mode" >&2
    else install_file "$src" "$dst" "$mode" >&2; fi
    changed=$((changed + 1))
  done
  apply=$(apply_for_category "$area")
  if (( changed > 0 )) && [[ -n "$apply" ]]; then
    echo "  → $apply" >&2
    bash -c "$apply" >/dev/null 2>&1 || warn "'$apply' failed — you may need to run it yourself"
    if [[ "$apply" == "hyprctl reload" ]]; then
      errs=$(hyprctl configerrors 2>/dev/null | grep -v '^no errors' || true)
      if [[ -n "$errs" ]]; then warn "Hyprland reported config errors after the reload:"; echo "$errs" >&2; fi
    fi
  fi
  printf '%s\n' "$changed"
}

# core_restore_file <rel> — put one tracked file back from the repo, with the
# same .bak.<epoch> every other write makes. The per-file counterpart of
# `reset`, which goes to Omarchy's default instead.
core_restore_file() {
  require_writable_schema || return 1
  briefcache_invalidate
  local rel="$1" src repo_path mode
  src=$(resolve_manifest_src "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  if is_secret_rel "$rel" && repo_has_vault; then
    vault_restore_entry "$rel" || return 1
    return 0
  fi
  repo_path=$(repo_copy_for_rel "$rel")
  if is_dir_entry "$rel"; then
    [[ -d "${repo_path%/}" ]] || { echo "$rel is not saved in your repo yet" >&2; return 1; }
    if tree_same "$repo_path" "$src"; then
      echo "$rel already matches the copy in your repo" >&2; return 0
    fi
    DRY=0 install_tree "$repo_path" "$src" "$(restore_mode_for "$rel")"
    local dapply; dapply=$(apply_for_category "$(category_for_rel "$rel")")
    [[ -n "$dapply" ]] && bash -c "$dapply" >/dev/null 2>&1 || true
    return 0
  fi
  [[ -f "$repo_path" ]] || { echo "$rel is not saved in your repo yet" >&2; return 1; }
  if [[ -f "$src" ]] && cmp -s "$repo_path" "$src"; then
    echo "$rel already matches the copy in your repo" >&2
    return 0
  fi
  mode=$(restore_mode_for "$rel")
  # Outside $HOME needs root. install_file failed there on the permission.
  # root_apply asks through pkexec or passwordless sudo, runs the apply step
  # in the same call, and otherwise prints the command and fails.
  if [[ "$src" != "$HOME"/* ]]; then
    root_apply "$src" "$repo_path" "$(apply_for_category "$(category_for_rel "$rel")")"
    return
  fi
  DRY=0 install_file "$repo_path" "$src" "$mode"
  local apply; apply=$(apply_for_category "$(category_for_rel "$rel")")
  [[ -n "$apply" ]] && bash -c "$apply" >/dev/null 2>&1 || true
  return 0
}
