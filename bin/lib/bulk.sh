# shellcheck shell=bash disable=SC2034
# bulk.sh: validation and application helpers for atomic multi-entry commands.
# The CLI runs these helpers in a temporary repository before it fast-forwards
# the active repository.
BULK_LARGE_LIMIT_BYTES="${BULK_LARGE_LIMIT_BYTES:-10485760}"

bulk_require_ids() {
  local id
  (( $# > 0 )) || { echo "bulk: no entries selected" >&2; return 1; }
  local -A seen=()
  registry_build || return 1
  for id in "$@"; do
    [[ -n "$id" && -z "${seen[$id]:-}" ]] || {
      echo "bulk: duplicate or empty entry id: $id" >&2; return 1; }
    seen["$id"]=1
    registry_row_for "$id" >/dev/null || {
      echo "bulk: unknown entry: $id" >&2; return 1; }
  done
}

bulk_validate_scope() {
  local want="$1" id kind
  shift
  case "$want" in shared|profile|off) ;; *) echo "bulk: invalid scope: $want" >&2; return 1 ;; esac
  bulk_require_ids "$@" || return 1
  for id in "$@"; do
    kind=$(registry_field "$(registry_row_for "$id")" 2)
    if [[ "$kind" == secret && "$want" == profile ]]; then
      echo "bulk: secret entries cannot use the profile scope: $id" >&2
      return 1
    fi
  done
}

bulk_validate_track_path() {
  local path="$1" kind="${2:-config}" real count
  [[ "$kind" == config || "$kind" == secret ]] || { echo "bulk: invalid tracking kind: $kind" >&2; return 1; }
  case "$path" in -*|*\$'\n'*|*\$'\t'*) echo "bulk: invalid path" >&2; return 1 ;; esac
  real="${path/#\~/$HOME}"
  [[ "$real" == /* ]] || real="$PWD/$real"
  real=$(realpath -m -- "$real")
  [[ "$real" != "$REPLICANT_HOME" && "$real" != "$REPLICANT_HOME/"* ]] || {
    echo "bulk: paths inside the data repository are not trackable: $path" >&2; return 1; }
  [[ -e "${real%/}" ]] || { echo "bulk: path does not exist: $path" >&2; return 1; }
  [[ ! -L "${real%/}" ]] || { echo "bulk: symlinks are not trackable: $path" >&2; return 1; }
  [[ -f "${real%/}" || -d "${real%/}" ]] || { echo "bulk: path is not a file or directory: $path" >&2; return 1; }
  [[ -r "${real%/}" ]] || { echo "bulk: path is not readable: $path" >&2; return 1; }
  if [[ -d "${real%/}" ]]; then
    if find "${real%/}" -xdev ! -readable -print -quit 2>/dev/null | grep -q .; then
      echo "bulk: directory contains unreadable files: $path" >&2; return 1
    fi
    if find "${real%/}" -xdev -type d -name .git -print -quit 2>/dev/null | grep -q .; then
      echo "bulk: nested repositories are not trackable: $path" >&2; return 1
    fi
    if find "${real%/}" -xdev \( -type s -o -type b -o -type c -o -type p -o -type l \) -print -quit 2>/dev/null | grep -q .; then
      echo "bulk: trees with special files or symlinks are not trackable: $path" >&2; return 1
    fi
    count=$(find "${real%/}" -xdev -type f 2>/dev/null | wc -l)
    (( count <= 400 )) || { echo "bulk: directory contains more than 400 files: $path" >&2; return 1; }
    if find "${real%/}" -xdev -type f -exec file --brief --mime-type -- {} + 2>/dev/null | grep -q '^application/'; then
      echo "bulk: binary files are not trackable: $path" >&2; return 1
    fi
  else
    count=$(stat -c '%s' -- "${real%/}" 2>/dev/null || echo 0)
    if (( count > BULK_LARGE_LIMIT_BYTES )) && [[ "${BULK_ALLOW_LARGE:-0}" != 1 ]]; then
      echo "bulk: file exceeds 10 MiB; use --allow-large: $path" >&2; return 1
    fi
    if file --brief --mime-type -- "${real%/}" 2>/dev/null | grep -q '^application/'; then
      echo "bulk: binary files are not trackable: $path" >&2; return 1
    fi
  fi
}

bulk_require_secret_ready() {
  repo_has_vault || {
    echo "bulk: encrypted secret operations require a version 2 or 3 repository" >&2
    return 1
  }
  vault_identity_ok
}

bulk_apply() {
  local action="$1"; shift
  case "$action" in
    save)
      bulk_require_ids "$@" || return 1
      local id
      for id in "$@"; do
        if is_secret_rel "$id"; then
          bulk_require_secret_ready || return 1
          break
        fi
      done
      for id in "$@"; do snapshot_one "$id" || return 1; done
      ;;
    scope)
      local scope="$1"; shift
      bulk_validate_scope "$scope" "$@" || return 1
      core_scope_bulk "$scope" "$@"
      ;;
    track)
      local kind="$1"; shift
      local path
      if [[ "$kind" == secret ]]; then bulk_require_secret_ready || return 1; fi
      for path in "$@"; do bulk_validate_track_path "$path" "$kind" || return 1; done
      for path in "$@"; do
        if [[ "$kind" == secret ]]; then core_track "$path" --secret
        else core_track "$path"; fi
      done
      ;;
    convert-secret)
      bulk_require_ids "$@" || return 1
      bulk_require_secret_ready || return 1
      local id src
      for id in "$@"; do
        src=$(resolve_manifest_src "$id") || { echo "bulk: unknown entry: $id" >&2; return 1; }
        is_user_entry "$id" || { echo "bulk: only user entries can become secrets: $id" >&2; return 1; }
        is_secret_rel "$id" && { echo "bulk: entry is already secret: $id" >&2; return 1; }
      done
      for id in "$@"; do
        src=$(resolve_manifest_src "$id")
        core_untrack "$id" || return 1
        core_track "$src" "$id" --secret || return 1
        snapshot_one "$id" >/dev/null || return 1
      done
      ;;
    untrack)
      bulk_require_ids "$@" || return 1
      local id
      for id in "$@"; do is_user_entry "$id" || { echo "bulk: only user entries can be untracked: $id" >&2; return 1; }; done
      for id in "$@"; do core_untrack "$id" || return 1; done
      ;;
    *) echo "bulk: unknown action: $action" >&2; return 2 ;;
  esac
}

# core_bulk_transact <action> <scope> <kind> <allow_large: 0|1> -- <entries...>:
# apply one validated multi-entry action as one transaction. The CLI parses
# and confirms (including every --yes gate); this owns the worktree, the
# candidate commit, the push and the activation. The active repository changes
# only after the candidate commit exists. One validated selection, one commit.
core_bulk_transact() {
  local action="${1:-}" scope="${2:-}" kind="${3:-}" allow_large="${4:-0}"
  shift 4 || { echo "bulk: usage: bulk-transact <action> <scope> <kind> <allow_large> -- <entries>" >&2; return 2; }
  [[ "${1:-}" == "--" ]] && shift
  local -a args=("$@")
  [[ -n "$action" && ${#args[@]} -gt 0 ]] || { echo "bulk: no entries selected" >&2; return 1; }
  tx_begin "bulk-$action" "bulk: $action ${#args[@]} entries" "${args[@]}" || return 1
  local txdir="$TX_DIR" txrepo="$TX_REPO" base="$TX_BASE" branch candidate rc=0
  branch=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo main)
  local -a core_args=("$action")
  case "$action" in
    scope) core_args+=("$scope" "${args[@]}") ;;
    track) core_args+=("$kind" "${args[@]}") ;;
    *) core_args+=("${args[@]}") ;;
  esac
  if [[ "$allow_large" == 1 ]]; then export BULK_ALLOW_LARGE=1; fi
  if REPLICANT_TX_REPO="$txrepo" bash "$REAL_CORE" bulk-apply "${core_args[@]}"; then
    :
  else
    rc=$?
    tx_remove "$txdir"
  fi
  if (( rc == 0 )); then
    git -C "$txrepo" add -A >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )) && git -C "$txrepo" diff --cached --quiet; then
      echo "bulk: nothing changed" >&2
      tx_remove "$txdir"
    elif (( rc == 0 )); then
      REPLICANT_TX_REPO="$txrepo" bash "$REAL_CORE" bulk-scan "$txrepo" >/dev/null || rc=$?
      if (( rc == 0 )); then
        git -C "$txrepo" commit -q -m "bulk: $action ${#args[@]} entries" || rc=$?
      fi
      if (( rc == 0 )); then
        local pack_kib
        pack_kib=$(git -C "$txrepo" count-objects -v 2>/dev/null | awk '$1 == "size-pack:" { print $2; exit }')
        if [[ "${pack_kib:-0}" =~ ^[0-9]+$ ]] && (( pack_kib > 102400 )); then
          echo "bulk: warning: Git pack exceeds 100 MiB" >&2
        fi
      fi
      candidate=$(git -C "$txrepo" rev-parse HEAD 2>/dev/null || true)
      (( rc == 0 )) && [[ -n "$candidate" ]] && tx_mark_committed "$txdir" "$candidate" "$base" "bulk-$action" "bulk: $action ${#args[@]} entries" "${args[@]}"
      if (( rc == 0 )) && git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$txrepo" push -q origin "HEAD:refs/heads/$branch" || rc=$?
      fi
      if (( rc == 0 )) && [[ -n "$candidate" && "$candidate" != "$base" ]]; then
        git -C "$REPO_DIR" fetch -q --no-tags "$txrepo" HEAD || rc=$?
        (( rc == 0 )) && git -C "$REPO_DIR" merge --ff-only -q FETCH_HEAD || rc=$?
      fi
      if (( rc == 0 )); then
        tx_meta_write "$txdir" fast-forwarded "$base" "bulk-$action" "bulk: $action ${#args[@]} entries" "${args[@]}" \
          || echo "bulk: warning: the fast-forward landed but the journal did not update" >&2
        tx_remove "$txdir"
      fi
    fi
  fi
  unset BULK_ALLOW_LARGE
  (( rc == 0 )) || { echo "bulk: operation failed; active repository was not changed; transaction: $txdir" >&2; return "$rc"; }
  briefcache_invalidate 2>/dev/null || true
  echo "bulk: $action completed in one commit" >&2
}
