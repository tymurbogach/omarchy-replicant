# shellcheck shell=bash disable=SC2034
# history.sh: files that left the repo, and bringing them back from git history.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# The repo paths that hold copies this machine can bring back: the shared tree,
# the secrets and this profile's tree. Another profile's tree belongs to another
# machine, so its deletions are not this machine's to undo.
history_pathspec() {
  printf '%s\n' config secrets "profiles/$(current_profile)/config"
}

# rel_for_repo_path <repo-path>: the id-like path of a copy. config/x, secrets/x
# and profiles/<p>/config/x are all x.
rel_for_repo_path() {
  local p="$1"
  case "$p" in
    config/*)            printf '%s\n' "${p#config/}" ;;
    secrets/*)           printf '%s\n' "${p#secrets/}" ;;
    profiles/*/config/*) p="${p#profiles/*/config/}"; printf '%s\n' "$p" ;;
    *)                   printf '%s\n' "$p" ;;
  esac
}

# deleted_rows [limit]: "<sha>\t<epoch>\t<date>\t<subject>\t<repo-path>" for
# each copy that a commit deleted and that the repo does not hold now. A path
# deleted twice is named once, at its newest deletion. A move between scopes is
# a rename to git, so it is not a deletion here.
deleted_rows() {
  local limit="${1:-200}" line sha epoch date subject
  [[ -e "$REPO_DIR/.git" ]] || return 0
  git -C "$REPO_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0
  local -A in_head=() seen=()
  local -a specs=()
  mapfile -t specs < <(history_pathspec)
  while IFS= read -r line; do in_head[$line]=1; done \
    < <(git -C "$REPO_DIR" ls-tree -r --name-only HEAD -- "${specs[@]}" 2>/dev/null)
  sha=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == $'\x1e'* ]]; then
      IFS=$'\x1f' read -r sha epoch date subject <<<"${line#$'\x1e'}"
      continue
    fi
    [[ -n "$sha" ]] || continue
    [[ -n "${in_head[$line]:-}" || -n "${seen[$line]:-}" ]] && continue
    seen[$line]=1
    printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$epoch" "$date" "$subject" "$line"
  done < <(git -C "$REPO_DIR" log -n "$limit" --diff-filter=D --name-only \
             --date=format:'%d %b %H:%M' --format=$'\x1e%H\x1f%at\x1f%ad\x1f%s' \
             -- "${specs[@]}" 2>/dev/null)
}

# core_deleted [--json]: the copies that left the repo, grouped by the commit
# that removed them, newest first. The panel lists these with a Bring back
# button for each commit.
core_deleted() {
  local as_json=0; [[ "${1:-}" == "--json" ]] && as_json=1
  if (( as_json )); then
    deleted_rows | jq -Rsc '
      split("\n") | map(select(length > 0) | split("\t")
        | {sha: .[0], epoch: (.[1]|tonumber? // 0), date: .[2], subject: .[3], path: .[4]})
      | group_by(.sha) | map({sha: .[0].sha, short: .[0].sha[0:7], epoch: .[0].epoch,
          date: .[0].date, subject: .[0].subject, count: length,
          files: (map(.path) | sort)})
      | sort_by(-.epoch) | .[0:20]'
    return 0
  fi
  local sha epoch date subject path last="" n=0
  while IFS=$'\t' read -r sha epoch date subject path; do
    if [[ "$sha" != "$last" ]]; then
      printf '\n%s  %s  %s\n' "${sha:0:7}" "$date" "$subject"
      last="$sha"; n=$((n + 1))
    fi
    printf '    %s\n' "$path"
  done < <(deleted_rows)
  if (( n == 0 )); then echo "Nothing has been deleted from your repo."; return 0; fi
  echo
  echo "Bring one back with: omarchy-replicant recover <sha> --apply"
}

# core_recover <sha> <dry>: undo the deletions of one commit. The copies come
# back into the repo from the commit before it, the entries that commit
# removed come back too, and each entry is then restored onto this machine
# with a .bak.<epoch> of whatever it replaces. The caller commits.
# RECOVERED holds the repo paths that came back, for that commit.
RECOVERED=()
# recover_entries <sha>: reinsert the .replicant/entries.json rows that
# <sha> removed. An untrack removes the row and the copy in one commit, and
# the copy is useless without it: the next save would prune it again.
recover_entries() {
  local sha="$1" parent child removed id obj current tmp new_current
  parent=$(git -C "$REPO_DIR" show "$sha^:.replicant/entries.json" 2>/dev/null || printf '{}\n')
  child=$(git -C "$REPO_DIR" show "$sha:.replicant/entries.json" 2>/dev/null || printf '{}\n')
  removed=$(jq -r --argjson p "$parent" --argjson c "$child" -n '
    ($p | keys) - ($c | keys) | .[]' 2>/dev/null || true)
  [[ -n "$removed" ]] || return 0
  current=$(cat -- "$REPO_DIR/.replicant/entries.json" 2>/dev/null || printf '{}\n')
  tmp=$(mktemp) || return 1
  local changed=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # Already back (recovered earlier, or re-tracked since): leave it alone.
    if jq -e --arg id "$id" 'has($id)' <<<"$current" >/dev/null 2>&1; then continue; fi
    obj=$(jq -c --arg id "$id" '.[$id]' <<<"$parent" 2>/dev/null || true)
    [[ -n "$obj" && "$obj" != "null" ]] || continue
    # No `continue` inside the substitution below: it would exit only the
    # subshell and silently keep a half-merged registry. A merge failure fails
    # the recovery instead of quietly dropping the entry.
    new_current=$(jq -c --arg id "$id" --argjson o "$obj" '.[$id] = $o' <<<"$current" 2>/dev/null || true)
    if [[ -z "$new_current" ]]; then
      rm -f -- "$tmp"
      echo "recover: could not merge $id" >&2
      return 1
    fi
    current="$new_current"
    echo "  + tracked again: $id" >&2
    changed=1
  done <<<"$removed"
  if (( changed )); then
    printf '%s\n' "$current" | jq . > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; echo "recover: could not rebuild entries.json" >&2; return 1; }
    validate_entries "$tmp" || { rm -f -- "$tmp"; echo "recover: recovered entries fail validation" >&2; return 1; }
    mv -f -- "$tmp" "$REPO_DIR/.replicant/entries.json"
    ENTRIES_VALID=0
    load_user_manifest
  else
    rm -f -- "$tmp"
  fi
  return 0
}
# recover_vault <sha>: merge the vault secrets that <sha> removed back
# into the current index and restore their blob files. Needs the key: without
# it the index does not decrypt, and the copies stay in the repo only.
recover_vault() {
  local sha="$1" pdir cdir
  vault_identity_ok >/dev/null 2>&1 || {
    echo "  · vault is locked — secrets stay in the repo only until the key is imported" >&2
    return 0
  }
  pdir=$(mktemp -d) || return 1
  cdir=$(mktemp -d) || { rm -rf -- "$pdir"; return 1; }
  local parent_idx="" child_idx="" removed="" current=""
  if git -C "$REPO_DIR" show "$sha^:vault/index.age" > "$pdir/index.age" 2>/dev/null; then
    parent_idx=$(age -d -i "$(vault_identity_file)" -o - "$pdir/index.age" 2>/dev/null || true)
  fi
  if git -C "$REPO_DIR" show "$sha:vault/index.age" > "$cdir/index.age" 2>/dev/null; then
    child_idx=$(age -d -i "$(vault_identity_file)" -o - "$cdir/index.age" 2>/dev/null || true)
  fi
  rm -rf -- "$pdir" "$cdir"
  [[ -n "$parent_idx" ]] || return 0
  [[ -n "$child_idx" ]] || child_idx='{"version":2,"secrets":[]}'
  removed=$(jq -r --argjson p "$parent_idx" --argjson c "$child_idx" -n '
    (($p.secrets // []) | map(.id)) - (($c.secrets // []) | map(.id)) | .[]' 2>/dev/null || true)
  [[ -n "$removed" ]] || return 0
  current=$(vault_index_decrypt 2>/dev/null || true)
  [[ -n "$current" ]] || { echo "recover: vault is locked — secrets stay in the repo only" >&2; return 0; }
  local id obj blob changed=0 new_current
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if jq -e --arg id "$id" '.secrets[] | select(.id == $id)' <<<"$current" >/dev/null 2>&1; then continue; fi
    obj=$(jq -c --arg id "$id" '.secrets[] | select(.id == $id)' <<<"$parent_idx" 2>/dev/null || true)
    [[ -n "$obj" ]] || continue
    blob=$(jq -r '.blob // empty' <<<"$obj" 2>/dev/null || true)
    if [[ -n "$blob" ]]; then
      mkdir -p -- "$(vault_blobs_dir)" 2>/dev/null || true
      if [[ ! -f "$(vault_blobs_dir)/$blob.age" ]]; then
        git -C "$REPO_DIR" show "$sha^:vault/blobs/$blob.age" > "$(vault_blobs_dir)/$blob.age" 2>/dev/null || {
          echo "  · secret $id: blob missing in history" >&2
          continue
        }
      fi
    fi
    # Same fail-closed merge as recover_entries: no `continue` inside the
    # substitution, which would exit only the subshell and silently drop the
    # secret from the merged index.
    new_current=$(jq -c --argjson o "$obj" '.secrets += [$o]' <<<"$current" 2>/dev/null || true)
    if [[ -z "$new_current" ]]; then
      echo "recover: could not merge secret $id" >&2
      return 1
    fi
    current="$new_current"
    echo "  + secret tracked again: $id" >&2
    changed=1
  done <<<"$removed"
  if (( changed )); then
    vault_index_write "$current" || { echo "recover: could not write the vault index" >&2; return 1; }
    load_user_manifest
  fi
  return 0
}
core_recover() {
  local want="$1" dry="${2:-1}" sha
  RECOVERED=()
  [[ -n "$want" ]] || { echo "recover: usage: recover <sha> [--apply]" >&2; return 1; }
  sha=$(git -C "$REPO_DIR" rev-parse -q --verify "$want^{commit}" 2>/dev/null) || {
    echo "recover: $want is not a commit in your repo" >&2; return 1; }
  local -a files=()
  local s _e _d _subj p
  while IFS=$'\t' read -r s _e _d _subj p; do
    [[ "$s" == "$sha" ]] && files+=("$p")
  done < <(deleted_rows)
  (( ${#files[@]} )) || { echo "recover: ${sha:0:7} deleted nothing that is still missing" >&2; return 1; }

  echo "From ${sha:0:7} ($(git -C "$REPO_DIR" log -1 --format=%s "$sha" 2>/dev/null)):" >&2
  for p in "${files[@]}"; do echo "  + $p" >&2; done
  if (( dry )); then
    # Preview the rows this commit removed, without touching the worktree.
    # On --apply the real recover_entries below prints the same lines once.
    if repo_is_ready 2>/dev/null; then
      local _pe _ce _rid
      _pe=$(git -C "$REPO_DIR" show "$sha^:.replicant/entries.json" 2>/dev/null || printf '{}\n')
      _ce=$(git -C "$REPO_DIR" show "$sha:.replicant/entries.json" 2>/dev/null || printf '{}\n')
      while IFS= read -r _rid; do
        [[ -n "$_rid" ]] || continue
        echo "  + tracked again: $_rid" >&2
      done < <(jq -r --argjson p "$_pe" --argjson c "$_ce" -n '($p | keys) - ($c | keys) | .[]' 2>/dev/null || true)
    fi
    skip "dry-run: nothing was touched. Repeat with --apply"; return 0
  fi
  require_ready_schema || return 1

  # The row in entries.json and the vault secret come back too, or the next
  # save prunes the copy again.
  recover_entries "$sha" || return 1
  recover_vault "$sha" || return 1
  git -C "$REPO_DIR" checkout -q "$sha^" -- "${files[@]}" || { echo "recover: git could not restore the copies" >&2; return 1; }
  RECOVERED=("${files[@]}")

  # Each copy back onto the machine, through the entry that owns it. A file
  # that nothing tracks any more stays in the repo only, and is named.
  local -A done_rel=()
  local rel owner
  for p in "${files[@]}"; do
    rel=$(rel_for_repo_path "$p")
    owner=$(owning_rel "$rel")
    if ! resolve_manifest_src "$owner" >/dev/null 2>&1; then
      skip "$rel is not tracked any more: it is back in the repo only"
      continue
    fi
    [[ -n "${done_rel[$owner]:-}" ]] && continue
    done_rel[$owner]=1
    if core_restore_file "$owner"; then ok "$owner is back on this machine"
    else warn "$owner is back in the repo, but not on this machine"; fi
  done
  return 0
}

# core_recover_transact <sha>: apply one recovery as one transaction. The
# copies come back through core_recover (repo and live machine), then exactly
# those paths plus the lists commit once with the recovery subject.
core_recover_transact() {
  local sha="${1:-}"
  [[ -n "$sha" ]] || { echo "usage: recover <sha> [--apply]" >&2; return 2; }
  local msg="recover: $sha"
  tx_shape_begin "recover" "$msg" || return 1
  local txdir="$TX_DIR" candidate first more subject p
  local -a store_paths=()
  while IFS= read -r p; do [[ -n "$p" ]] && store_paths+=("$p"); done < <(tx_shape_policy_paths)
  core_recover "$sha" 0 || { tx_abort "$txdir"; return 1; }
  first="${RECOVERED[0]}" more=$(( ${#RECOVERED[@]} - 1 ))
  subject="recover: $(rel_for_repo_path "$first")"
  (( more > 0 )) && subject+=", +$more more"
  subject+=" (from ${sha:0:7})"
  candidate=$(tx_shape_commit "$subject" "$txdir" -- "${store_paths[@]}" ${RECOVERED[@]+"${RECOVERED[@]}"}) || return 1
  [[ -n "$candidate" ]] || return 0
  tx_shape_finish "$txdir" || return 1
  return 0
}
