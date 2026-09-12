# shellcheck shell=bash disable=SC2034
# backups.sh: the .bak.<epoch> safety net: listing, undo, and the backups that setting edits make.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── the safety net, made visible ───────────────────────────────────────────
# Every write to the real machine leaves the previous version beside it as
# <file>.bak.<epoch>. That net existed from the first release and nothing could
# see it: `purge` was the only code that knew how to find one, and purge deletes
# the whole plugin. Eleven of them were sitting on this machine, unnamed and
# unreachable, which makes them a mess rather than a net — a backup you cannot
# find is not a backup.
#
# list_backups [rel] — one line per backup, newest first:
#     <rel> \t <live path> \t <backup path> \t <epoch> \t <same|differs|gone>
#
# The trailing slash comes off FIRST. install_tree backs a directory up as
# `<dir>.bak.<epoch>` beside it, so globbing "$src".bak.* on a tracked directory
# looks INSIDE the directory and finds nothing — the bug hard rule 8 was written
# for, and the reason this lives in one function instead of two copies.
list_backups() {
  local only="${1:-}" entry src rel b epoch state
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    rel="${entry##*:}"
    [[ -n "$only" && "$rel" != "$only" ]] && continue
    src="${entry%%:*}"; src="${src%/}"
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      epoch="${b##*.bak.}"
      [[ "$epoch" =~ ^[0-9]+$ ]] || continue
      if [[ ! -e "$src" ]]; then state=gone
      elif [[ -d "$b" ]]; then
        tree_same "$src" "$b" && state=same || state=differs
      elif cmp -s "$src" "$b" 2>/dev/null; then state=same
      else state=differs
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$src" "$b" "$epoch" "$state"
    done < <(ls -1d "$src".bak.* 2>/dev/null || true)
  done | sort -t$'\t' -k4,4nr
}

# build_backups_json — what the panel renders. One entry per backup, carrying
# the id it belongs to so the panel can put an Undo next to the right name.
build_backups_json() {
  list_backups | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {
      id: .[0], src: .[1], path: .[2],
      epoch: (.[3]|tonumber? // 0), state: .[4],
      name: (.[2] | split("/") | last)
    })'
}

# backup_before_write <file> — the .bak.<epoch> every write owes the user,
# minus the litter. Editing one setting is a small, repeated act (dragging the
# density slider is a dozen writes), and one backup per write buried the real
# config under a heap of near-identical copies in the same directory. Keep the
# three most recent per file: enough to walk back a bad afternoon, few enough
# that `ls ~/.config/omarchy` still reads.
BACKUPS_KEPT=${REPLICANT_BACKUPS_KEPT:-3}
# The backups that this function made, one path per line. Pruning uses this
# list and never the glob alone: `<file>.bak.*` also matches the backup that a
# restore made (install_file) and the ones that `omarchy refresh config` makes.
# The glob made three edits to a setting after a restore delete the undo for
# that restore.
SETTING_BACKUPS_FILE="$REPLICANT_HOME/setting-backups"
backup_before_write() {
  local file="$1" b old kept
  [[ -f "$file" ]] || return 0
  b="$file.bak.$(date +%s)"
  cp -a "$file" "$b" || return 1
  mkdir -p "$REPLICANT_HOME" 2>/dev/null || return 0
  printf '%s\n' "$b" >> "$SETTING_BACKUPS_FILE"
  # shellcheck disable=SC2012,SC2010  # names are ours: <file>.bak.<epoch>, no spaces
  while read -r old; do
    [[ -n "$old" ]] && rm -f -- "$old"
  done < <(ls -1t -- "$file".bak.* 2>/dev/null | grep -Fxf "$SETTING_BACKUPS_FILE" | tail -n +$((BACKUPS_KEPT + 1)))
  # Forget what no longer exists, so that the list cannot grow without end.
  kept=$(sort -u "$SETTING_BACKUPS_FILE" | while read -r old; do
           if [[ -e "$old" ]]; then printf '%s\n' "$old"; fi
         done)
  printf '%s\n' "$kept" | sed '/^$/d' > "$SETTING_BACKUPS_FILE"
}

# core_undo <rel> — put the newest .bak.<epoch> back, and take the version it
# replaces as the new backup.
#
# A SWAP, not a restore, and that is the whole design. Rule 2 says every write to
# the real machine keeps what it overwrote; obeying it naively here would leave a
# second backup behind on every undo, so undoing twice grows the pile it exists
# to drain. Consuming the backup and writing one in its place obeys the rule and
# stays at net zero — and it means undo can be undone, which is the one thing
# anybody pressing it wants to be sure of.
#
# It deliberately does NOT run the category's apply step. `restore-file` does,
# because it is putting the saved setup back; undo is "that was wrong, give me
# the previous minute" and reloading Hyprland from under a user who has just
# realised they made a mistake is not a favour. The caller says what to run.
core_undo() {
  local rel="$1" src line b epoch tmp now
  src=$(resolve_manifest_src "$rel") || { echo "unknown id: $rel" >&2; return 1; }
  src="${src%/}"
  line=$(list_backups "$rel" | head -1)
  [[ -n "$line" ]] || { echo "no .bak.<epoch> next to $rel — nothing to undo" >&2; return 1; }
  IFS=$'\t' read -r _ _ b epoch _ <<<"$line"
  [[ -e "$b" ]] || { echo "the backup named for $rel is gone: $b" >&2; return 1; }
  now=$(date +%s)
  # An epoch-named path this second is already taken if you undo twice inside one
  # second, which the tests do. Make it unique rather than silently clobbering
  # the very thing this function promises to keep.
  tmp="$src.bak.$now"
  while [[ -e "$tmp" ]]; do now=$((now + 1)); tmp="$src.bak.$now"; done
  if [[ -e "$src" ]]; then
    run mv -T -- "$src" "$tmp" || return 1
    skip "${src/#$HOME/\~} — the version you are replacing is now .bak.$now"
  fi
  run mv -T -- "$b" "$src" || return 1
  ok "${src/#$HOME/\~} restored from .bak.$epoch"
  return 0
}
