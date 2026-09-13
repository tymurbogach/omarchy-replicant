# shellcheck shell=bash disable=SC2034
# incoming.sh: what another machine changed, and what differs on this one.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# ─── incoming: what another machine changed and this one has not caught up ──
# Read through one assoc array, filled once. Every row in the panel asks, so a
# per-row re-read of the file is fifty reads of the same six lines.
declare -gA INCOMING=()
INCOMING_LOADED=0
read_incoming() {
  (( INCOMING_LOADED )) && return 0
  INCOMING_LOADED=1
  INCOMING=()
  [[ -f "$INCOMING_FILE" ]] || return 0
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    INCOMING["$line"]=1
  done < "$INCOMING_FILE"
  return 0
}

# is_incoming_rel <rel> — 0 when the last pull brought a newer copy of this
# entry. The CALLER still has to check the file actually differs: an entry that
# has since been restored, or deliberately saved over, matches again and must
# stop claiming anything. That is the same self-healing rule the unsaved badge
# follows, and it is why no pass has to remember to clear this flag.
is_incoming_rel() {
  read_incoming
  [[ -n "${INCOMING[$1]:-}" ]]
}

# record_incoming <rel>... — replace the list with exactly these entries.
# Called by `pull`, which is the one moment the direction of a difference is
# known for certain.
record_incoming() {
  mkdir -p "$REPLICANT_HOME" 2>/dev/null || return 0
  if (( $# == 0 )); then rm -f "$INCOMING_FILE" 2>/dev/null || true
  else printf '%s\n' "$@" | sort -u > "$INCOMING_FILE"
  fi
  INCOMING_LOADED=0
  return 0
}

# entry_differs <src> <repo-copy> <is-dir> — 0 when what is on this machine is
# not what the repo holds. This is the CONTENT half of "unsaved", factored out
# because two callers need it: the row payload the panel draws, and the cheap
# count the bar icon polls. A second copy of this comparison is exactly how a
# badge and a bar icon come to disagree about the same file.
#
# A file that is not on this machine does NOT differ — that is "missing", a
# different row and a different answer.
entry_differs() {
  local src="$1" repo_path="$2" is_dir="${3:-false}"
  if [[ "$is_dir" == true ]]; then
    [[ -d "${src%/}" ]] || return 1
    tree_same "$src" "$repo_path" && return 1
    return 0
  fi
  [[ -f "$src" ]] || return 1
  [[ -f "$repo_path" ]] || return 0
  cmp -s "$src" "$repo_path" 2>/dev/null && return 1
  return 0
}

# count_changes — prints "<unsaved> <incoming>" over every tracked entry.
#
# The bar icon used to read repoState.dirty, which counts what git sees in the
# REPO working tree — files core_backup has already copied in. Edit a config and
# never save it and the icon sat at the calm "in sync" hexagon all day, which is
# the one thing this plugin exists to tell you. The panel was fixed for this in
# 0.6.1 and the bar was not.
#
# It answers with content only. The git half ("copied in, not committed") is
# already in the brief payload as `dirty`, and the icon ORs the two. Fifty cmps
# take a few milliseconds; building the full row payload for the same answer
# took 1.4 s of CPU once a minute.
count_changes() {
  local entry src rel repo_path is_dir n_unsaved=0 n_incoming=0 scope prof
  # Built once in this shell, so the loops below need no fork for each row.
  SCOPE_MAP_READY=0; load_scope_map
  prof=$(current_profile)
  read_incoming
  for entry in "${TRACKED[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    scope_into scope "$rel"
    [[ "$scope" == "off" ]] && continue
    is_dir=false; is_dir_entry "$rel" && is_dir=true
    repo_path_into repo_path "$rel" "$prof"
    entry_differs "$src" "$repo_path" "$is_dir" || continue
    # Exclusive, exactly as the badge precedence is: a file the repo has a newer
    # copy of is asking for Restore, not for Save, and counting it in both
    # totals put the same file behind two contradictory buttons.
    if [[ -n "${INCOMING[$rel]:-}" ]]; then n_incoming=$(( n_incoming + 1 ))
    else n_unsaved=$(( n_unsaved + 1 )); fi
  done
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    scope_into scope "$rel"
    [[ "$scope" == "off" ]] && continue
    entry_differs "$src" "$SECRETS_DIR/$rel" false || continue
    if [[ -n "${INCOMING[$rel]:-}" ]]; then n_incoming=$(( n_incoming + 1 ))
    else n_unsaved=$(( n_unsaved + 1 )); fi
  done
  printf '%s %s\n' "$n_unsaved" "$n_incoming"
}

# Used by the omarchy-replicant CLI wrapper
# core_incoming <before-rev> <after-rev> — which tracked entries a pull moved.
# Written down for the panel and printed for the caller.
#
# It lives here rather than in the CLI for the reason everything else does: the
# mapping from a repo path back to the row a person can press a button on is
# business logic, and owning_rel is the only thing that knows a file three
# levels inside a tracked directory belongs to the directory's row.
core_incoming() {
  local before="$1" after="$2" p rel
  local -a rels=()
  while IFS= read -r p; do
    case "$p" in
      config/*)            rel="${p#config/}" ;;
      secrets/*)           rel="${p#secrets/}" ;;
      # Only THIS machine's profile. profiles/laptop/... is the laptop's own copy
      # of a file that is kept per profile precisely so the two machines do not
      # share it — reporting it as incoming here would tell the desktop to
      # restore the laptop's monitor layout onto itself.
      profiles/*/config/*) rel="${p#profiles/}"
                           [[ "${rel%%/*}" == "$(current_profile)" ]] || continue
                           rel="${rel#*/config/}" ;;
      *)                   continue ;;   # state/, .replicant-*: not rows anyone acts on
    esac
    rels+=("$(owning_rel "$rel")")
  done < <(git -C "$REPO_DIR" diff --name-only "$before" "$after" 2>/dev/null)
  if (( ${#rels[@]} == 0 )); then record_incoming; return 0; fi
  local -a uniq=()
  # shellcheck disable=SC2207
  uniq=($(printf '%s\n' "${rels[@]}" | sort -u))
  record_incoming "${uniq[@]}"
  printf '%s\n' "${uniq[@]}"
}

