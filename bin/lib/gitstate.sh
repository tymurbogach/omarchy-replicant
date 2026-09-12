# shellcheck shell=bash disable=SC2034
# gitstate.sh: one git call for the state of every row.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# path_unpushed <rel-path-inside-the-repo> — 0 (true) if that file's local HEAD
# differs from origin/<branch> (includes "never pushed at all": no upstream -> true)
# ─── One git call, not one per row ──────────────────────────────────────────
# Every row asked git twice — "is this dirty" and "is this unpushed" — and the
# second re-checked whether an upstream exists each time. Fifty rows came to a
# hundred and eighty git processes per panel refresh, and the panel refreshes
# every sixty seconds. Both questions are answered for the whole repo in one
# call each, and the per-row lookups are then plain string matching.
#
# Cached per process, which is safe because the only thing that reads them is
# status/JSON building. Anything that writes the repo runs in its own command.
GIT_CACHE_READY=0
GIT_DIRTY_SET=""
GIT_UNPUSHED_SET=""
# Cached for the length of one build, not one process. Two commands in the same
# process — which is exactly what the test suite is — must not see the first
# one's answer after the second has committed.
GIT_HAS_UPSTREAM=0
invalidate_git_cache() { GIT_CACHE_READY=0; GIT_DIRTY_SET=""; GIT_UNPUSHED_SET=""; GIT_HAS_UPSTREAM=0; }
load_git_cache() {
  (( GIT_CACHE_READY )) && return 0
  GIT_CACHE_READY=1
  [[ -d "$REPO_DIR/.git" ]] || return 0
  # -uall so an untracked DIRECTORY is listed as its files: git collapses one to
  # "config/nvim/" otherwise, and a per-file lookup would miss every file in it.
  # -z so a path with a space or a quote arrives intact; a rename yields both
  # of its sides, and counting both as dirty is the safe direction.
  local rec
  while IFS= read -r -d '' rec; do
    [[ ${#rec} -gt 3 ]] && rec="${rec:3}"
    [[ -n "$rec" ]] && GIT_DIRTY_SET+="$rec"$'\n'
  done < <(git -C "$REPO_DIR" status --porcelain -z -uall 2>/dev/null || true)
  if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    GIT_HAS_UPSTREAM=1
    GIT_UNPUSHED_SET=$(git -C "$REPO_DIR" diff --name-only '@{u}' 2>/dev/null || true)
  fi
}

# set_has <set> <path> — exact match, or prefix match when the path is a
# directory id (trailing slash), which is how a tracked tree asks "did anything
# under me change".
set_has() {
  local hay="$1" p="$2" line
  [[ -n "$hay" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$p" == */ ]]; then [[ "$line" == "$p"* ]] && return 0
    else [[ "$line" == "$p" ]] && return 0; fi
  done <<<"$hay"
  return 1
}

path_dirty() { load_git_cache; set_has "$GIT_DIRTY_SET" "$1"; }
# No upstream at all means nothing has ever been pushed, so everything is
# unpushed. Losing that case made a repo before its first push claim every file
# was already safe on GitHub.
path_unpushed() {
  load_git_cache
  (( GIT_HAS_UPSTREAM )) || return 0
  set_has "$GIT_UNPUSHED_SET" "$1"
}
