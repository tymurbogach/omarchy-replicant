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
