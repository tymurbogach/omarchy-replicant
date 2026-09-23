# shellcheck shell=bash disable=SC2034
# briefcache.sh: a local cache for the brief-status counts.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.
#
# The bar polls `status --json --brief` once a minute, and every poll ran the
# full content comparison (one cmp per file, one decrypt per secret). The full
# payload stays authoritative and never reads this cache. The brief payload
# reuses the last counts when nothing observable moved.
#
# What the cache holds: source file identity (device and inode), modification
# metadata (size and mtime), the ciphertext object ID of each secret blob plus
# the blob file's own size and mtime, the repo HEAD, the profile name, a hash
# of the incoming list, the public key state, and the previous counts. It never
# holds secret values, secret names beyond the tracked IDs the registry already
# lists, or plaintext hashes. A directory entry stores a hash of its file
# metadata listing (sizes, mtimes, paths), never contents.
#
# Limit: a content change that preserves size and mtime (touch -r) still hits
# the cache, so brief may report stale counts until the next invalidation. Full
# status compares bytes on every call and always sees it. That is the documented
# tradeoff of a metadata cache, and the timestamp test pins it.

# briefcache_file: the cache path. Machine-local on purpose, like incoming.
briefcache_file() {
  printf '%s\n' "$REPLICANT_HOME/cache/state-v2.json"
}

# briefcache_invalidate: drop the cache. Never fails, so callers under
# `set -e` need no guard. Every writer calls this; the HEAD, profile,
# incoming and key guards below catch anything a writer missed.
briefcache_invalidate() {
  local cache
  cache=$(briefcache_file)
  rm -f -- "$cache" 2>/dev/null || true
  return 0
}

# briefcache_key_state: public key state only. The recipient is public (it
# lives in the repo), and the derived identity recipient is public too. No key
# material ever reaches the cache.
briefcache_key_state() {
  local recf rec mine idf
  recf="$REPO_DIR/.replicant/recipient.txt"
  rec="norec"
  [[ -f "$recf" ]] && rec=$(tr -d '[:space:]' < "$recf" 2>/dev/null || echo "norec")
  [[ -z "$rec" ]] && rec="norec"
  idf="$REPLICANT_HOME/keys/identity.txt"
  mine="nokey"
  if [[ -f "$idf" ]] && command -v age-keygen >/dev/null 2>&1; then
    mine=$(age-keygen -y "$idf" 2>/dev/null || echo "badkey")
  fi
  printf '%s|%s\n' "$rec" "$mine"
}

# briefcache_file_sig <path>: identity and modification metadata of one file.
briefcache_file_sig() {
  local p="$1" sig
  [[ -n "$p" ]] || { printf 'absent\n'; return 0; }
  if sig=$(stat -c '%d:%i %s %Y' -- "$p" 2>/dev/null); then
    printf '%s\n' "$sig"
  else
    printf 'absent\n'
  fi
  return 0
}

# briefcache_tree_sig <dir>: metadata listing hash of a directory tree.
briefcache_tree_sig() {
  local d="$1" h
  d="${d%/}"
  [[ -d "$d" ]] || { printf 'absent-dir\n'; return 0; }
  if h=$(find "$d" -type f -printf '%s %T@ %p\n' 2>/dev/null | LC_ALL=C sort | sha256sum 2>/dev/null); then
    printf 'tree %s\n' "${h%% *}"
  else
    printf 'absent-dir\n'
  fi
  return 0
}

# briefcache_repo_head: the current commit, or a marker when there is none.
briefcache_repo_head() {
  local h
  if h=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null); then
    printf '%s\n' "$h"
  else
    printf 'nogit\n'
  fi
  return 0
}

# briefcache_incoming_hash: fingerprint of the incoming list.
briefcache_incoming_hash() {
  local h
  if [[ -f "$INCOMING_FILE" ]]; then
    if h=$(sha256sum -- "$INCOMING_FILE" 2>/dev/null); then
      printf '%s\n' "${h%% *}"
    else
      printf 'unreadable\n'
    fi
  else
    printf 'none\n'
  fi
  return 0
}

# briefcache_write <unsaved> <incoming> <locked> <missing> <needs_action>:
# snapshot the current fingerprints with the given counts. Best effort: a
# failure to write never fails the status call. Never writes secret values,
# names beyond tracked IDs, or plaintext hashes.
briefcache_write() {
  local n_unsaved="$1" n_incoming="$2" n_locked="$3" n_missing="$4" needs_action="$5"
  local cache cachedir tmp head prof inhash kstate
  cache=$(briefcache_file)
  cachedir=$(dirname -- "$cache")
  mkdir -p -- "$cachedir" 2>/dev/null || return 0
  head=$(briefcache_repo_head)
  prof=$(current_profile 2>/dev/null || echo "noprofile")
  inhash=$(briefcache_incoming_hash)
  kstate=$(briefcache_key_state)
  registry_build 2>/dev/null || return 0
  tmp=$(mktemp -- "$cachedir/.state-v2.XXXXXX") || return 0
  local entry rel regrow kind live repo blob live_sig repo_sig blob_sig
  local -a rf=()
  {
    for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
      rel="${entry##*:}"
      regrow=$(registry_row_for "$rel" 2>/dev/null) || continue
      mapfile -t rf < <(row_split "$regrow" 9)
      kind="${rf[1]}"; live="${rf[5]}"; repo="${rf[6]}"; blob="${rf[7]}"
      if [[ "$kind" == "dir" ]]; then
        live_sig=$(briefcache_tree_sig "$live")
      else
        live_sig=$(briefcache_file_sig "$live")
      fi
      if [[ -n "$blob" ]]; then
        repo_sig="vault:$blob"
        blob_sig=$(briefcache_file_sig "$repo")
      elif [[ "$kind" == "dir" ]]; then
        repo_sig=$(briefcache_tree_sig "$repo")
        blob_sig="-"
      else
        repo_sig=$(briefcache_file_sig "$repo")
        blob_sig="-"
      fi
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$rel" "$live_sig" "$repo_sig" "$blob" "$blob_sig"
    done
  } | jq -Rsc --arg head "$head" --arg prof "$prof" --arg inhash "$inhash" --arg kstate "$kstate" \
      --argjson unsaved "$n_unsaved" --argjson incoming "$n_incoming" \
      --argjson locked "$n_locked" --argjson missing "$n_missing" \
      --argjson needs_action "$needs_action" '
    split("\n") | map(select(length > 0) | split("\u001f")
      | {id: .[0], live_sig: .[1], repo_sig: .[2], blob: .[3], blob_sig: .[4]})
    | {version: 2, repo_head: $head, profile: $prof,
       incoming_hash: $inhash, key_state: $kstate,
       counts: {unsaved: $unsaved, incoming: $incoming, locked: $locked,
                missing: $missing, needs_action: $needs_action},
       entries: .}' > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 0; }
  mv -f -- "$tmp" "$cache" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null || true; return 0; }
  return 0
}

# briefcache_read: print "<unsaved> <incoming> <locked> <missing> <needs_action>"
# from the cache when every fingerprint still matches. Return 1 on any miss, so
# the caller falls back to the authoritative evaluation. Prints nothing on miss.
briefcache_read() {
  local cache head prof inhash kstate
  cache=$(briefcache_file)
  [[ -f "$cache" ]] || return 1
  local cver chead cprof cinhash ckstate
  cver=$(jq -r '.version // 0' -- "$cache" 2>/dev/null) || return 1
  [[ "$cver" == "2" ]] || return 1
  chead=$(jq -r '.repo_head // ""' -- "$cache" 2>/dev/null) || return 1
  cprof=$(jq -r '.profile // ""' -- "$cache" 2>/dev/null) || return 1
  cinhash=$(jq -r '.incoming_hash // ""' -- "$cache" 2>/dev/null) || return 1
  ckstate=$(jq -r '.key_state // ""' -- "$cache" 2>/dev/null) || return 1
  head=$(briefcache_repo_head)
  prof=$(current_profile 2>/dev/null || echo "noprofile")
  inhash=$(briefcache_incoming_hash)
  kstate=$(briefcache_key_state)
  [[ "$chead" == "$head" ]] || return 1
  [[ "$cprof" == "$prof" ]] || return 1
  [[ "$cinhash" == "$inhash" ]] || return 1
  [[ "$ckstate" == "$kstate" ]] || return 1
  registry_build 2>/dev/null || return 1
  local line cid clive crepo cblob cblobsig regrow kind live repo blob live_sig repo_sig blob_sig
  local -a rf=()
  local -A seen=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\x1f' read -r cid clive crepo cblob cblobsig <<<"$line"
    [[ -n "${cid:-}" ]] || return 1
    seen["$cid"]=1
    regrow=$(registry_row_for "$cid" 2>/dev/null) || return 1
    mapfile -t rf < <(row_split "$regrow" 9)
    kind="${rf[1]}"; live="${rf[5]}"; repo="${rf[6]}"; blob="${rf[7]}"
    if [[ "$kind" == "dir" ]]; then
      live_sig=$(briefcache_tree_sig "$live")
    else
      live_sig=$(briefcache_file_sig "$live")
    fi
    if [[ -n "$blob" ]]; then
      repo_sig="vault:$blob"
      blob_sig=$(briefcache_file_sig "$repo")
    elif [[ "$kind" == "dir" ]]; then
      repo_sig=$(briefcache_tree_sig "$repo")
      blob_sig="-"
    else
      repo_sig=$(briefcache_file_sig "$repo")
      blob_sig="-"
    fi
    [[ "$live_sig" == "$clive" ]] || return 1
    [[ "$repo_sig" == "$crepo" ]] || return 1
    [[ "$blob" == "$cblob" ]] || return 1
    [[ "$blob_sig" == "$cblobsig" ]] || return 1
  done < <(jq -r '.entries[] | [.id, .live_sig, .repo_sig, .blob, .blob_sig] | join("\u001f")' -- "$cache" 2>/dev/null) || return 1
  local entry rel
  for entry in "${TRACKED[@]}" "${TRACKED_SECRETS[@]}"; do
    rel="${entry##*:}"
    [[ -n "${seen[$rel]:-}" ]] || return 1
  done
  local u i l m na
  u=$(jq -r '.counts.unsaved' -- "$cache" 2>/dev/null) || return 1
  i=$(jq -r '.counts.incoming' -- "$cache" 2>/dev/null) || return 1
  l=$(jq -r '.counts.locked' -- "$cache" 2>/dev/null) || return 1
  m=$(jq -r '.counts.missing' -- "$cache" 2>/dev/null) || return 1
  na=$(jq -r '.counts.needs_action' -- "$cache" 2>/dev/null) || return 1
  printf '%s %s %s %s %s\n' "$u" "$i" "$l" "$m" "$na"
  return 0
}
