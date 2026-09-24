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
# back into the repo from the commit before it, the lines that commit removed
# from .replicant-track come back too, and each entry is then restored onto this
# machine with a .bak.<epoch> of whatever it replaces. The caller commits.
# RECOVERED holds the repo paths that came back, for that commit.
RECOVERED=()
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

  # The lines of .replicant-track that the commit removed. An untrack removes
  # the line and the copy in one commit, and the copy is useless without it:
  # the next save would prune it again.
  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done < <(comm -23 \
             <(git -C "$REPO_DIR" show "$sha^:.replicant-track" 2>/dev/null | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' | sort -u) \
             <(git -C "$REPO_DIR" show "$sha:.replicant-track" 2>/dev/null | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' | sort -u))

  echo "From ${sha:0:7} ($(git -C "$REPO_DIR" log -1 --format=%s "$sha" 2>/dev/null)):" >&2
  for p in "${files[@]}"; do echo "  + $p" >&2; done
  for line in ${lines[@]+"${lines[@]}"}; do echo "  + tracked again: $line" >&2; done
  if (( dry )); then skip "dry-run: nothing was touched. Repeat with --apply"; return 0; fi
  require_writable_schema || return 1

  if (( ${#lines[@]} )); then
    ensure_track_file
    local -a keep=()
    while IFS= read -r line; do keep+=("$line"); done < <(read_track_lines)
    for line in "${lines[@]}"; do
      printf '%s\n' ${keep[@]+"${keep[@]}"} | grep -qxF -- "$line" || keep+=("$line")
    done
    write_track_file ${keep[@]+"${keep[@]}"}
    load_user_manifest
  fi
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
  local txdir="$TX_DIR" candidate first more subject
  core_recover "$sha" 0 || { tx_abort "$txdir"; return 1; }
  first="${RECOVERED[0]}" more=$(( ${#RECOVERED[@]} - 1 ))
  subject="recover: $(rel_for_repo_path "$first")"
  (( more > 0 )) && subject+=", +$more more"
  subject+=" (from ${sha:0:7})"
  candidate=$(tx_shape_commit "$subject" "$txdir" -- .replicant-track .replicant/entries.json vault/index.age ${RECOVERED[@]+"${RECOVERED[@]}"}) || return 1
  [[ -n "$candidate" ]] || return 0
  tx_shape_finish "$txdir" || return 1
  return 0
}
