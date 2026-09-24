# shellcheck shell=bash disable=SC2034
# track.sh: writing the user's own list: track and untrack.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── The user's list: writing it ────────────────────────────────────────────
# Refused on version 3: user entries live in .replicant/entries.json and the
# vault index, and no track file is ever created there.
write_track_file() {
  if repo_is_v3; then
    echo "track: refusing to write the legacy track file in a version 3 repo" >&2
    return 1
  fi
  local -a keep=("$@")
  {
    echo "# Files and directories YOU want backed up, on top of the ones the"
    echo "# plugin ships with. One per line:"
    echo "#"
    echo "#   ~/.local/bin/my-script                  name in the repo derived"
    echo "#   ~/.config/foo/bar.conf = foo/bar.conf   name in the repo given"
    echo "#   ~/.config/nvim/                         a directory (trailing slash)"
    echo "#   secret ~/Projects/app/.env                   stored 600, never rendered"
    echo "#"
    echo "# This file lives in the repo, so both your machines honour it."
    echo "# Written by the panel and by 'omarchy-replicant track'; safe to edit."
    print_lines "${keep[@]}"
  } > "$USER_TRACK_FILE"
}

# Same contract as ensure_scope_file, for the same reason: load_user_manifest
# has a read-only fallback so nothing stops being tracked the moment you
# upgrade, but a read-modify-write against a list the fallback invented would
# be a delete. Every legacy writer calls this first. On version 3 it is a
# no-op: user entries live in .replicant/entries.json and the vault index, and
# no track file is ever created.
ensure_track_file() {
  repo_is_v3 && return 0
  [[ -f "$USER_TRACK_FILE" ]] && return 0
  mkdir -p "$(dirname "$USER_TRACK_FILE")" 2>/dev/null || true
  local -a seed=() entry
  for entry in "${LEGACY_PERSONAL[@]}"; do
    legacy_personal_present "$entry" && seed+=("$(track_line_for "${entry%%:*}" "${entry##*:}" config)")
  done
  for entry in "${LEGACY_PERSONAL_SECRETS[@]}"; do
    [[ -f "${entry%%:*}" || -f "$SECRETS_DIR/${entry##*:}" ]] &&
      seed+=("$(track_line_for "${entry%%:*}" "${entry##*:}" secret)")
  done
  write_track_file ${seed[@]+"${seed[@]}"}
  (( ${#seed[@]} )) &&
    echo "  · ${#seed[@]} entry(ies) that used to be hardcoded are now yours, in .replicant-track" >&2
  load_user_manifest
  return 0
}

# One line of .replicant-track, written the way a human would: the derived name
# is left implicit, so the file only ever states what it has to.
track_line_for() {
  local src="$1" rel="$2" kind="${3:-config}" pretty="${1/#$HOME/\~}" line
  line="$pretty"
  [[ "$(derive_rel "$src")" == "$rel" ]] || line="$pretty = $rel"
  [[ "$kind" == secret ]] && line="secret $line"
  printf '%s\n' "$line"
}

# core_track <path> [rel] [--secret] — add one path to the user's list.
core_track() {
  require_writable_schema || return 1
  local path="" rel="" kind=config arg
  for arg in "$@"; do
    case "$arg" in
      --secret) kind=secret ;;
      -*) ;;
      *) if [[ -z "$path" ]]; then path="$arg"; else rel="$arg"; fi ;;
    esac
  done
  [[ -n "$path" ]] || { echo "track: usage: track <path> [name-in-repo] [--secret]" >&2; return 1; }
  case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
  [[ "$path" == /* ]] || path="$PWD/$path"
  # A trailing slash is how the user says "directory", but so is the file
  # system: asking it means `track ~/.config/nvim` does the obvious thing.
  [[ -d "${path%/}" ]] && path="${path%/}/"
  [[ -e "${path%/}" ]] || { echo "track: $path does not exist on this machine" >&2; return 1; }
  [[ -L "${path%/}" ]] && { echo "track: $path is a symlink — track what it points at instead" >&2; return 1; }
  [[ -n "$rel" ]] || rel=$(derive_rel "$path")
  if [[ "$path" == */ ]]; then rel="${rel%/}/"; fi

  local entry esrc
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    esrc="${entry%%:*}"
    if [[ "$esrc" == "$path" || "${entry##*:}" == "$rel" ]]; then
      echo "track: already tracked as '${entry##*:}'" >&2; return 0
    fi
    # A file inside a tracked directory is already tracked BY it. Accepting it
    # again gave two entries the same path in the repo, so the panel drew the
    # row twice and untracking the file would have deleted the copy the
    # directory still owns.
    if [[ "$esrc" == */ && "$path" == "$esrc"* ]]; then
      echo "track: already covered by the tracked directory '${entry##*:}'" >&2; return 0
    fi
    # And the other way round: a directory that swallows something already
    # listed would take over its copy without anyone saying so.
    if [[ "$path" == */ && "$esrc" == "$path"* ]]; then
      echo "track: '$rel' would swallow '${entry##*:}', which is tracked on its own" >&2
      echo "       untrack that first, or track a narrower directory" >&2
      return 1
    fi
  done

  # Tracking a big tree is a foot-gun with a quiet failure mode: it works, and
  # the repo grows by a hundred megabytes nobody meant to push. Say the number
  # rather than guessing an acceptable one.
  if [[ "$path" == */ ]]; then
    local n; n=$(tree_count "$path")
    if (( n > 400 )); then
      echo "track: ${path/#$HOME/\~} holds $n files — that is a lot to put in a git repo." >&2
      echo "       If it is a git clone (a theme, a plugin), it is already recorded by URL." >&2
      echo "       Track a narrower directory, or the handful of files you actually edit." >&2
      return 1
    fi
    (( n > 100 )) && echo "track: note — ${path/#$HOME/\~} holds $n files" >&2
  fi

  ensure_track_file
  if repo_is_v3; then
    v3_track_entry "$path" "$rel" "$kind" || return 1
    load_user_manifest
    briefcache_invalidate
    echo "tracking ${path/#$HOME/\~} as $rel" >&2
    return 0
  fi
  local -a keep=()
  while IFS= read -r entry; do keep+=("$entry"); done < <(read_track_lines)
  keep+=("$(track_line_for "$path" "$rel" "$kind")")
  write_track_file ${keep[@]+"${keep[@]}"}
  load_user_manifest
  briefcache_invalidate
  echo "tracking ${path/#$HOME/\~} as $rel" >&2
}

# v3_track_entry <path> <rel> <config|secret>: record one user entry in the
# canonical v3 stores. Config and directory entries go to entries.json with
# the currently resolved scope; secrets go straight to the encrypted vault
# index, which is their only record. Fails before mutation when validation
# fails, and leaves the stores untouched then.
v3_track_entry() {
  local path="$1" rel="$2" kind="$3"
  if [[ "$kind" == secret ]]; then
    vault_identity_ok || return 1
    local idx
    idx=$(vault_index_decrypt) || return 1
    [[ -z "$(vault_index_blob "$idx" "$rel")" ]] || {
      echo "track: already tracked as '$rel'" >&2; return 0; }
    idx=$(vault_save_entry "$path" "$rel" "$idx" user) || return 1
    vault_index_write "$idx" || return 1
    return 0
  fi
  local dirkind=config scope
  [[ "$path" == */ ]] && dirkind=dir
  scope=$(scope_for "$rel")
  v3_entries_upsert "$rel" "$path" "$dirkind" "$scope" user || return 1
  return 0
}

# core_untrack <rel> — drop one entry from the user's list. Only the user's:
# a shipped core entry is switched off with `scope <rel> off`, which keeps the
# row (and the copy the repo holds) instead of making both disappear.
core_untrack() {
  require_writable_schema || return 1
  local rel="$1" entry k line was_secret=false
  [[ -n "$rel" ]] || { echo "untrack: usage: untrack <id>" >&2; return 1; }
  if ! is_user_entry "$rel"; then
    for entry in "${MANIFEST[@]}" "${SECRETS_MANIFEST[@]}"; do
      [[ "${entry##*:}" == "$rel" ]] && {
        echo "untrack: $rel is one of the files the plugin ships with — use 'scope $rel off' to stop syncing it" >&2
        return 1; }
    done
    echo "untrack: $rel is not in your list" >&2; return 1
  fi
  # Before the list surgery below: untracking removes the very entry that
  # makes is_secret_rel true, so the vault branch after it would never fire.
  is_secret_rel "$rel" && was_secret=true
  if repo_is_v3; then
    v3_untrack_entry "$rel" "$was_secret" || return 1
    load_user_manifest
    briefcache_invalidate
    echo "$rel is no longer tracked (the copy in your repo was removed too)" >&2
    return 0
  fi
  ensure_track_file
  local -a keep=()
  while IFS= read -r line; do
    IFS=$'\t' read -r k _ entry < <(parse_track_line "$line")
    [[ "${entry:-}" == "$rel" ]] || keep+=("$line")
  done < <(read_track_lines)
  write_track_file ${keep[@]+"${keep[@]}"}
  load_user_manifest
  # The repo copy goes with it — core_backup's prune pass would remove it on
  # the next save anyway, and leaving it until then means the panel shows a row
  # for a file nothing tracks. Encrypted secrets live in the vault instead of
  # next to the configs, so they leave through it.
  if [[ "$was_secret" == true ]] && repo_has_vault; then
    vault_drop_entry "$rel" || return 1
  else
    local copy; copy=$(repo_copy_for_rel "$rel")
    [[ -e "$copy" ]] && rm -rf -- "$copy"
  fi
  briefcache_invalidate
  echo "$rel is no longer tracked (the copy in your repo was removed too)" >&2
}

# v3_untrack_entry <rel> <was-secret>: drop one user entry from the canonical
# v3 stores. A shipped entry is refused above; only the user's own records go.
v3_untrack_entry() {
  local rel="$1" was_secret="$2" copy
  if [[ "$was_secret" == true ]]; then
    vault_drop_entry "$rel" || return 1
    return 0
  fi
  v3_require_valid_entries || return 1
  local rec
  rec=$(jq -r --arg id "$rel" '.[$id] // empty | [.path, .kind, .scope, .source] | @tsv' \
    "$REPO_DIR/.replicant/entries.json" 2>/dev/null || true)
  [[ -n "$rec" ]] || { echo "untrack: $rel is not in your list" >&2; return 1; }
  [[ "$(cut -f4 <<<"$rec")" == user ]] || { echo "untrack: $rel is not in your list" >&2; return 1; }
  v3_entries_remove "$rel" || return 1
  copy=$(repo_copy_for_rel "$rel")
  [[ -e "$copy" ]] && rm -rf -- "$copy"
  return 0
}

# core_forget <rel>: a file is gone from this machine, and its copy leaves the
# repo too. One of the user's own entries is untracked. A shipped entry keeps
# its place in the plugin's list, so it shows again if the file comes back.
# Git history keeps the copy either way, and `recover` brings it back.
core_forget() {
  require_writable_schema || return 1
  local rel="$1" src copy
  [[ -n "$rel" ]] || { echo "forget: usage: forget <id>" >&2; return 1; }
  src=$(resolve_manifest_src "$rel") || { echo "forget: unknown id: $rel" >&2; return 1; }
  # Forgetting a file that is still here would last until the next save, which
  # copies it in again. The two tools for that case say what they do.
  if [[ -e "${src%/}" ]]; then
    if is_user_entry "$rel"; then
      echo "forget: ${src/#$HOME/\~} is still on this machine. To stop saving it: untrack $rel" >&2
    else
      echo "forget: ${src/#$HOME/\~} is still on this machine. To stop saving it: scope $rel off" >&2
    fi
    return 1
  fi
  if is_user_entry "$rel"; then core_untrack "$rel"; return; fi
  if is_secret_rel "$rel" && repo_has_vault; then
    vault_drop_entry "$rel" || return 1
    briefcache_invalidate
    echo "$rel is gone from your repo too. Git history keeps it: 'recover' brings it back" >&2
    return 0
  fi
  copy=$(repo_copy_for_rel "$rel")
  [[ -e "${copy%/}" ]] || { echo "forget: $rel has no copy in your repo, so there is nothing to forget" >&2; return 1; }
  rm -rf -- "${copy%/}"
  briefcache_invalidate
  echo "$rel is gone from your repo too. Git history keeps it: 'recover' brings it back" >&2
}
