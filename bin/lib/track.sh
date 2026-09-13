# shellcheck shell=bash disable=SC2034
# track.sh: writing the user's own list: track and untrack.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── The user's list: writing it ────────────────────────────────────────────
write_track_file() {
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
# be a delete. Every writer calls this first.
ensure_track_file() {
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
  local -a keep=()
  while IFS= read -r entry; do keep+=("$entry"); done < <(read_track_lines)
  keep+=("$(track_line_for "$path" "$rel" "$kind")")
  write_track_file ${keep[@]+"${keep[@]}"}
  load_user_manifest
  echo "tracking ${path/#$HOME/\~} as $rel" >&2
}

# core_untrack <rel> — drop one entry from the user's list. Only the user's:
# a shipped core entry is switched off with `scope <rel> off`, which keeps the
# row (and the copy the repo holds) instead of making both disappear.
core_untrack() {
  local rel="$1" entry k line
  [[ -n "$rel" ]] || { echo "untrack: usage: untrack <id>" >&2; return 1; }
  if ! is_user_entry "$rel"; then
    for entry in "${MANIFEST[@]}" "${SECRETS_MANIFEST[@]}"; do
      [[ "${entry##*:}" == "$rel" ]] && {
        echo "untrack: $rel is one of the files the plugin ships with — use 'scope $rel off' to stop syncing it" >&2
        return 1; }
    done
    echo "untrack: $rel is not in your list" >&2; return 1
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
  # for a file nothing tracks.
  local copy; copy=$(repo_copy_for_rel "$rel")
  [[ -e "$copy" ]] && rm -rf -- "$copy"
  echo "$rel is no longer tracked (the copy in your repo was removed too)" >&2
}
