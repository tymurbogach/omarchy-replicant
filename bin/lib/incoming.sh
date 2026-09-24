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
  briefcache_invalidate
  return 0
}

# entry_differs lives in state.sh now, beside the evaluator that is its only
# remaining reader through state_facts (the builders and the backup hold
# decision call it there). This module keeps the incoming mark itself.

# count_changes — prints "<unsaved> <incoming> <locked> <missing>" over every
# tracked entry.
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
#
# Locked is the third number: a version 2 secret whose vault cannot be read on
# this machine. It is counted apart from unsaved so the bar can ask for the key
# instead of asking for a save. Missing is the fourth: a saved entry gone from
# this machine, which asks for restore or forget, never for calm.
# Older callers that read only two fields keep working: the first field stays
# the unsaved count.
count_changes() {
  local entry rel n_unsaved=0 n_incoming=0 n_locked=0 n_missing=0
  local regrow live same member locked scope repo k v
  local -a rf=()
  # Built once in this shell, so the loops below need no fork for each row.
  registry_build
  # Content only, like entry_differs always was: the git half (copied in, not
  # committed) already reaches the bar as `dirty` in the brief payload, and
  # adding it here would count one file twice.
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    rel="${entry##*:}"
    regrow=$(registry_row_for "$rel") || continue
    mapfile -t rf < <(row_split "$regrow" 9)
    scope="${rf[4]}"
    [[ "$scope" == "off" ]] && continue
    live=false; same=false; member=false; locked=false; repo=false; gitdirty=false
    while IFS='=' read -r k v; do
      case "$k" in
        live) live="$v" ;; same) same="$v" ;; repo) repo="$v" ;;
        incoming) member="$v" ;; locked) locked="$v" ;;
        git_dirty) gitdirty="$v" ;;
      esac
    done < <(state_facts "$regrow")
    if [[ "$locked" == true ]]; then n_locked=$(( n_locked + 1 )); continue; fi
    if [[ "$live" == false ]]; then
      # Only when the repo holds a copy: a shipped entry neither here nor in
      # the repo draws no row, and the bar stays quiet about it too.
      [[ "$repo" == true ]] && n_missing=$(( n_missing + 1 ))
      continue
    fi
    # Unsaved is either half, exactly as the badge precedence is: content that
    # differs, or a repo copy that is not committed yet. A file the repo has a
    # newer copy of is asking for Restore, not for Save, and counting it in
    # both totals put the same file behind two contradictory buttons.
    [[ "$same" == false || "$gitdirty" == true ]] || continue
    if [[ "$member" == true ]]; then n_incoming=$(( n_incoming + 1 ))
    else n_unsaved=$(( n_unsaved + 1 )); fi
  done
  printf '%s %s %s %s\n' "$n_unsaved" "$n_incoming" "$n_locked" "$n_missing"
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

