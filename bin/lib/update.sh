# shellcheck shell=bash disable=SC2034
# update.sh: the plugin's own updates. Whether its origin has a newer version,
# and what that version changes.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# How old the last look at the origin may be before the panel looks again on
# its own. Opening the panel asks at most this often. "Check for updates" and
# `update-check --fetch` always ask.
UPDATE_MAX_AGE=${REPLICANT_UPDATE_MAX_AGE:-21600}

# The stamp is FETCH_HEAD inside the plugin's own .git, which the fetch writes
# anyway. A stamp of our own would be one more file for purge to name.
plugin_git() { git -C "$PLUGIN_DIR" "$@"; }

# plugin_is_checkout: this copy of the plugin is the top of a git work tree
# with an origin. A copy that is not cannot update itself.
plugin_is_checkout() {
  [[ "$(plugin_git rev-parse --show-toplevel 2>/dev/null)" == "$PLUGIN_DIR" ]] || return 1
  plugin_git remote get-url origin >/dev/null 2>&1
}

# plugin_is_installed: this copy is the one `omarchy plugin update` updates. A
# development checkout that the shell loads through a symlink is not.
plugin_is_installed() {
  local id
  id=$(jq -r '.id // ""' "$PLUGIN_DIR/manifest.json" 2>/dev/null)
  [[ -n "$id" && "$PLUGIN_DIR" == "$HOME/.config/omarchy/plugins/$id" ]]
}

# core_update_check [--fetch] [--json]: what the origin has that this copy does
# not. The origin is asked when --fetch is given, or when the last answer is
# older than UPDATE_MAX_AGE. `omarchy plugin update` fetches `origin HEAD`, so
# this asks the same question in the same way.
core_update_check() {
  local fetch=0 json=0 arg
  for arg in "$@"; do
    case "$arg" in --fetch) fetch=1 ;; --json) json=1 ;; esac
  done
  local current checkout=false installed=false latest="" behind=0 available=false
  local dirty=false fetched=false fetch_failed=false checked=0 origin="" commits='[]'
  current=$(running_version)
  if plugin_is_checkout; then
    checkout=true
    plugin_is_installed && installed=true
    origin=$(plugin_git remote get-url origin 2>/dev/null || true)
    local stamp now
    stamp="$(plugin_git rev-parse --absolute-git-dir 2>/dev/null)/FETCH_HEAD"
    now=$(date +%s)
    if (( fetch )) || [[ ! -f "$stamp" ]] || (( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) >= UPDATE_MAX_AGE )); then
      if GIT_TERMINAL_PROMPT=0 timeout 10 git -C "$PLUGIN_DIR" fetch --quiet origin HEAD >/dev/null 2>&1; then
        fetched=true
      else
        fetch_failed=true
      fi
    fi
    [[ -f "$stamp" ]] && checked=$(stat -c %Y "$stamp" 2>/dev/null || echo 0)
    if plugin_git rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1; then
      latest=$(plugin_git show FETCH_HEAD:manifest.json 2>/dev/null | jq -r '.version // ""' 2>/dev/null || true)
      behind=$(plugin_git rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)
      # Only a fast-forward is an update. A checkout with commits of its own is
      # somebody's work, and `omarchy plugin update` refuses to merge it.
      if (( behind > 0 )) && plugin_git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
        available=true
      fi
      commits=$(plugin_git log -n 30 --format='%h%x1f%s' HEAD..FETCH_HEAD 2>/dev/null |
        jq -Rsc 'split("\n") | map(select(length > 0) | split("\u001f") | {sha: .[0], subject: .[1]})')
    fi
    [[ -n "$(plugin_git status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty=true
  fi
  if (( json )); then
    jq -nc --arg current "$current" --arg latest "$latest" --arg origin "$origin" \
      --arg dir "$PLUGIN_DIR" --argjson checkout "$checkout" --argjson installed "$installed" \
      --argjson behind "${behind:-0}" --argjson available "$available" --argjson dirty "$dirty" \
      --argjson fetched "$fetched" --argjson fetch_failed "$fetch_failed" \
      --argjson checked "${checked:-0}" --argjson commits "$commits" \
      '{current:$current, latest:$latest, available:$available, behind:$behind,
        checkout:$checkout, installed:$installed, dirty:$dirty, dir:$dir, origin:$origin,
        fetched:$fetched, fetch_failed:$fetch_failed, checked:$checked, commits:$commits}'
    return 0
  fi
  if [[ "$checkout" != true ]]; then
    echo "Replicant $current. This copy is not a git checkout, so it cannot update itself."
    return 0
  fi
  [[ "$fetch_failed" == true ]] && echo "Could not reach $origin. The answer below is from the last check." >&2
  if [[ "$available" != true ]]; then
    echo "Replicant $current is up to date."
    return 0
  fi
  echo "Replicant ${latest:-a newer version} is available. This machine has $current ($(plural "$behind" commit) behind):"
  jq -r '.[] | "  " + .sha + "  " + .subject' <<<"$commits"
  if [[ "$installed" == true ]]; then
    echo "Update with: omarchy-replicant update"
  else
    echo "This copy runs from $PLUGIN_DIR, which is not the installed plugin. Update it with git pull."
  fi
}
