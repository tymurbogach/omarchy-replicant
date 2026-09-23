# shellcheck shell=bash disable=SC2034
# crypto.sh: encrypted secrets for v2 repos. Sourced by replicant-core.sh,
# which sets the paths it uses. It defines functions and data and runs nothing.
#
# One shared post-quantum age identity lives at $REPLICANT_HOME/keys/, never
# in the repo. The repo holds only the public recipient
# (.replicant/recipient.txt), one encrypted blob per secret
# (vault/blobs/<id>.age), and the encrypted index (vault/index.age) that maps
# each secret id to its scope and blob. Blob IDs are random and opaque: two
# identical files get different blobs, and no id reveals a path or a name.
#
# Plaintext only ever exists in temp files outside the repo, listed in
# _VAULT_TEMPS (declared here, so the global-leak test sees it before and
# after) and dropped explicitly on every return, plus chained INT/TERM/HUP
# traps for real signals. Nothing secret reaches stdout, stderr, git, or
# the JSON.

declare -g -a _VAULT_TEMPS=()

# _vault_note_temp <file>: register a plaintext temp for trap cleanup.
# _vault_drop_temp <file>: remove it now and forget it.
# _vault_drop_tree <dir>: the same for a work directory (rm cannot).
# _vault_keep_temp <file>: forget it WITHOUT removing: the file outlives this
# call on purpose (the staged copy a printed sudo command names).
_vault_note_temp() { _VAULT_TEMPS+=("$1"); }
_vault_drop_temp() {
  local f="$1" rest=() t
  for t in ${_VAULT_TEMPS[@]+"${_VAULT_TEMPS[@]}"}; do
    [[ "$t" == "$f" ]] || rest+=("$t")
  done
  _VAULT_TEMPS=(${rest[@]+"${rest[@]}"})
  rm -f -- "$f"
}
_vault_drop_tree() {
  local d="$1" rest=() t
  for t in ${_VAULT_TEMPS[@]+"${_VAULT_TEMPS[@]}"}; do
    [[ "$t" == "$d" || "$t" == "$d"/* ]] || rest+=("$t")
  done
  _VAULT_TEMPS=(${rest[@]+"${rest[@]}"})
  rm -rf -- "$d"
}
_vault_keep_temp() {
  local f="$1" rest=() t
  for t in ${_VAULT_TEMPS[@]+"${_VAULT_TEMPS[@]}"}; do
    [[ "$t" == "$f" ]] || rest+=("$t")
  done
  _VAULT_TEMPS=(${rest[@]+"${rest[@]}"})
}
_vault_clean_temps() {
  if (( ${#_VAULT_TEMPS[@]} )); then
    rm -f -- "${_VAULT_TEMPS[@]}" 2>/dev/null || true
  fi
  _VAULT_TEMPS=()
}
# _vault_drop_restore_plain: the restore temp in whichever shape this call
# made it (a staged file outside $HOME, or a file inside a temp dir beside
# the destination). Reads the caller's locals through dynamic scope, the way
# every module here shares names with its callers.
_vault_drop_restore_plain() {
  _vault_drop_temp "$plain"
  [[ -n "${restdir:-}" ]] && _vault_drop_tree "$restdir"
}
# vault_arm_traps: clean the temps on interrupt, terminate or hangup,
# chaining whatever trap the caller already had for those signals (a suite's
# cleanup must survive this). Idempotent: a second call sees its own marker
# and stops.
#
# EXIT is deliberately never trapped here. A command-substitution subshell
# $(...) runs its inherited EXIT trap when it finishes, so chaining the
# caller's EXIT cleanup would fire it early: in the test suites that means
# rm -rf of the whole fixture tree in the middle of a save (reproduced:
# every file vanished right after the first vault write). Normal-path
# cleanup is explicit drops on every return instead, and the suite pins an
# empty temp list after the flows.
vault_arm_traps() {
  local cur
  cur=$(trap -p INT 2>/dev/null || true)
  [[ "$cur" == *_vault_clean_temps* ]] && return 0
  local sig prev
  for sig in INT TERM HUP; do
    prev=$(trap -p "$sig" | sed -e "s/^trap -- '//" -e "s/' $sig\$//")
    if [[ -n "$prev" ]]; then
      # shellcheck disable=SC2064
      trap "_vault_clean_temps; $prev" "$sig"
    else
      trap '_vault_clean_temps' "$sig"
    fi
  done
}

# vault_drop_entry <rel>: remove one secret from the vault: its index row and
# its blob file. Used by untrack and forget; the CLI commits the result.
vault_drop_entry() {
  local rel="$1" idx blob blobs
  idx=$(vault_index_decrypt) || return 1
  blob=$(vault_index_blob "$idx" "$rel")
  if [[ -z "$blob" ]]; then
    printf 'vault: %s is not saved in your repo\n' "$rel" >&2
    return 1
  fi
  idx=$(jq -c --arg id "$rel" '.secrets |= map(select(.id != $id))' <<<"$idx") || return 1
  vault_index_write "$idx" || return 1
  blobs=$(vault_blobs_dir)
  rm -f -- "$blobs/$blob.age"
  printf 'vault: %s forgotten\n' "$rel" >&2
}

# core_key <subcommand> [...]: the key command family. Usage errors exit 2,
# like an unknown core command.
core_key() {
  local sub="${1:-}"
  (( $# )) && shift
  case "$sub" in
    init)   key_init "$@" ;;
    export) key_export "$@" ;;
    import) key_import "$@" ;;
    status) key_status "$@" ;;
    rotate) key_rotate "$@" ;;
    *) echo "key: usage: key init | key export <absolute-destination> | key import <source> | key status | key rotate" >&2; return 2 ;;
  esac
}

# vault_paths: the three locations, printed for callers that need them.
vault_identity_file() { printf '%s\n' "$REPLICANT_HOME/keys/identity.txt"; }
vault_recipient_file() { printf '%s\n' "$REPO_DIR/.replicant/recipient.txt"; }
vault_index_file() { printf '%s\n' "$REPO_DIR/vault/index.age"; }
vault_blobs_dir() { printf '%s\n' "$REPO_DIR/vault/blobs"; }

# crypto_require_age: the encrypt/decrypt binary, or the exact next step.
crypto_require_age() {
  command -v age >/dev/null 2>&1 || {
    printf 'replicant: age is not installed — omarchy pkg add age\n' >&2
    return 1
  }
}
# crypto_require_keygen_pq: generation needs age-keygen WITH post-quantum
# support, not just any age-keygen. A key made without -pq would silently
# downgrade every secret it ever touches, so this fails loudly instead.
crypto_require_keygen_pq() {
  command -v age-keygen >/dev/null 2>&1 || {
    printf 'replicant: age-keygen is not installed — omarchy pkg add age\n' >&2
    return 1
  }
  local probe_dir
  probe_dir=$(mktemp -d) || return 1
  # age -o refuses an existing file, so the output names a path inside a fresh
  # dir rather than a mktemp file.
  if ( umask 077; age-keygen -pq -o "$probe_dir/key" >/dev/null 2>&1 ) && grep -q '^# public key: age1pq1' "$probe_dir/key" 2>/dev/null; then
    rm -rf -- "$probe_dir"
  else
    rm -rf -- "$probe_dir"
    printf 'replicant: age-keygen here cannot make post-quantum keys — upgrade age past 1.3 (omarchy pkg add age), then retry\n' >&2
    return 1
  fi
}

# vault_recipient: the repo's public recipient, or why there is none.
vault_recipient() {
  local f
  f=$(vault_recipient_file)
  [[ -f "$f" ]] || { printf 'replicant: no recipient in this repo — run key init first\n' >&2; return 1; }
  local r
  r=$(tr -d '[:space:]' < "$f" 2>/dev/null || true)
  [[ "$r" == age1* ]] || { printf 'replicant: the recipient in .replicant/recipient.txt is not an age key\n' >&2; return 1; }
  printf '%s\n' "$r"
}

# vault_identity_ok: the triple check before any secret mutation or read.
# The key must exist, be parseable, and match the repo's recipient. Anything
# else fails with the exact remediation: this is the locked state of phase B.
vault_identity_ok() {
  crypto_require_age || return 1
  local idf rec mine
  idf=$(vault_identity_file)
  [[ -f "$idf" ]] || { printf 'replicant: no secret key on this machine — run key import <source>, then retry\n' >&2; return 1; }
  mine=$(age-keygen -y "$idf" 2>/dev/null || true)
  [[ "$mine" == age1* ]] || { printf 'replicant: the key at keys/identity.txt is not a valid age identity — run key status, then re-import\n' >&2; return 1; }
  rec=$(vault_recipient) || return 1
  [[ "$mine" == "$rec" ]] || { printf 'replicant: this key does not match the repo recipient — run key import with the shared identity, then retry\n' >&2; return 1; }
  local mode
  mode=$(stat -c '%a' "$idf" 2>/dev/null || echo "")
  if [[ "$mode" != "600" ]]; then
    chmod 600 "$idf" 2>/dev/null || true
    printf 'replicant: note — keys/identity.txt was not mode 600, fixed\n' >&2
  fi
  return 0
}
# vault_unlocked: the silent form, for status paths that render locked rows.
vault_unlocked() { vault_identity_ok >/dev/null 2>&1; }

# vault_new_blob_id: 128 random bits as 32 hex chars, never derived from the
# secret. /dev/urandom rather than openssl, so encryption needs no new tool.
vault_new_blob_id() {
  local id i
  for i in 1 2 3; do
    id=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' || true)
    [[ "$id" =~ ^[0-9a-f]{32}$ ]] && { printf '%s\n' "$id"; return 0; }
  done
  printf 'replicant: no entropy for a blob id\n' >&2
  return 1
}

# vault_index_decrypt: the index as JSON on stdout. A missing index is an
# empty registry, not an error: no secret saved yet. Anything else that fails
# (no key, tampered file) fails, and the caller treats it as locked.
vault_index_decrypt() {
  vault_identity_ok || return 1
  local idx
  idx=$(vault_index_file)
  if [[ ! -f "$idx" ]]; then
    printf '{"version":1,"secrets":[]}\n'
    return 0
  fi
  local idf plaindir plain
  idf=$(vault_identity_file)
  plaindir=$(mktemp -d) || return 1
  plain="$plaindir/plain"
  _vault_note_temp "$plaindir"
  vault_arm_traps
  if ! age -d -i "$idf" -o "$plain" "$idx" 2>/dev/null; then
    _vault_drop_tree "$plaindir"
    printf 'replicant: vault/index.age does not decrypt with this key\n' >&2
    return 1
  fi
  jq -e '.version == 1 and (.secrets | type) == "array"' "$plain" >/dev/null 2>&1 || {
    _vault_drop_tree "$plaindir"
    printf 'replicant: vault/index.age is not a secret index\n' >&2
    return 1
  }
  cat -- "$plain"
  _vault_drop_tree "$plaindir"
}
# vault_index_blob <index-json> <id>: the blob id for a secret, or nothing.
vault_index_blob() {
  jq -r --arg id "$2" '.secrets[] | select(.id == $id) | .blob // empty' <<<"$1" 2>/dev/null || true
}
# vault_index_scope <index-json> <id>: the recorded scope, or nothing.
vault_index_scope() {
  jq -r --arg id "$2" '.secrets[] | select(.id == $id) | .scope // empty' <<<"$1" 2>/dev/null || true
}

# vault_save_entry <src> <rel> <index-json>: encrypt one live secret into the
# vault. Prints the (possibly unchanged) index JSON. An unchanged plaintext
# keeps its ciphertext byte for byte, so git stays quiet when nothing moved.
vault_save_entry() {
  local src="$1" rel="$2" idx="$3" rec blob blobs plain
  rec=$(vault_recipient) || return 1
  blobs=$(vault_blobs_dir)
  mkdir -p "$blobs" || return 1
  blob=$(vault_index_blob "$idx" "$rel")
  if [[ -n "$blob" && -f "$blobs/$blob.age" ]]; then
    local plaindir plain
    plaindir=$(mktemp -d) || return 1
    plain="$plaindir/plain"
    _vault_note_temp "$plaindir"
    vault_arm_traps
    local idf
    idf=$(vault_identity_file)
    if age -d -i "$idf" -o "$plain" "$blobs/$blob.age" 2>/dev/null; then
      if cmp -s "$src" "$plain" 2>/dev/null; then
        _vault_drop_tree "$plaindir"
        printf '%s\n' "$idx"
        return 0
      fi
    else
      # A blob that does not decrypt is corruption or tampering, and the live
      # file is this machine's truth: re-encrypt it under the same id. Git
      # history keeps the tampered ciphertext as evidence either way.
      printf '  · vault blob for %s does not decrypt — re-encrypting from this machine\n' "$rel" >&2
    fi
    _vault_drop_tree "$plaindir"
  else
    blob=$(vault_new_blob_id) || return 1
  fi
  local encdir staged
  encdir=$(mktemp -d) || return 1
  staged="$encdir/blob.age"
  _vault_note_temp "$encdir"
  vault_arm_traps
  age -r "$rec" -o "$staged" "$src" 2>/dev/null || {
    _vault_drop_tree "$encdir"
    printf 'replicant: could not encrypt %s\n' "$rel" >&2
    return 1
  }
  mv -f -- "$staged" "$blobs/$blob.age"
  _vault_drop_tree "$encdir"
  local scope
  scope_into scope "$rel"
  jq -c --arg id "$rel" --arg scope "$scope" --arg blob "$blob" \
    '.secrets |= (map(select(.id != $id)) + [{id: $id, scope: $scope, blob: $blob}])' <<<"$idx"
}

# vault_empty: true when the repo holds no vault at all: no index and no
# blobs. Only then may a keyless save proceed (see below).
vault_empty() {
  local blobs b
  [[ -f "$(vault_index_file)" ]] && return 1
  blobs=$(vault_blobs_dir)
  for b in "$blobs"/*.age; do
    [[ -f "$b" ]] && return 1
  done
  return 0
}

# vault_save_all: the v2 half of the backup's secret pass. Without a usable
# key nothing secret mutates — except the very first save, which has no vault
# to protect yet: it saves the config and says to run key init and save
# again. (Requiring the key there too would deadlock init, which needs a repo
# before key init can record its recipient.)
vault_save_all() {
  local why
  why=$(vault_identity_ok 2>&1) || {
    if vault_empty; then
      printf '  · no secret key on this machine — secrets skipped: run key init (first machine) or key import <source>, then save again\n' >&2
      return 0
    fi
    printf '%s\n' "$why" >&2
    return 1
  }
  [[ -n "$why" ]] && printf '%s\n' "$why" >&2
  local idx rec entry src rel
  idx=$(vault_index_decrypt) || return 1
  rec=$(vault_recipient) || return 1
  local -a errs=() new_blobs=()
  local scopied=0 old_blob new_blob
  for entry in "${TRACKED_SECRETS[@]}"; do
    src="${entry%%:*}"; rel="${entry##*:}"
    is_excluded "$rel" && continue
    if [[ -f $src && ! -r $src ]]; then
      printf '  · %s is readable by root only — skipped this save\n' "${src/#$HOME/\~}" >&2
      continue
    elif [[ -f $src ]]; then
      old_blob=$(vault_index_blob "$idx" "$rel")
      if idx=$(vault_save_entry "$src" "$rel" "$idx"); then
        new_blob=$(vault_index_blob "$idx" "$rel")
        [[ -n "$old_blob" ]] || new_blobs+=("$(vault_blobs_dir)/$new_blob.age")
        scopied=$((scopied + 1))
      else
        errs+=("$rel")
      fi
    else
      printf '  · missing: %s\n' "${src/#$HOME/\~}" >&2
    fi
  done
  if (( ${#errs[@]} )); then
    # Blobs written for brand-new secrets above are referenced by nothing now
    # that the index is not landing: remove them rather than littering the
    # repo with ciphertext no registry will ever name.
    if (( ${#new_blobs[@]} )); then
      rm -f -- "${new_blobs[@]}" 2>/dev/null || true
    fi
    printf 'replicant: %s secret(s) failed to save\n' "${#errs[@]}" >&2
    return 1
  fi
  vault_index_write "$idx" || return 1
  printf '  %s\n' "$(plural "$scopied" secret) encrypted into the vault" >&2
}

# vault_index_write <index-json>: encrypt the index, preserving the current
# ciphertext when the registry did not change.
vault_index_write() {
  local idx="$1" cur canon_old canon_new rec tmp enc
  idx=$(jq -c -S '{version: 1, secrets: (.secrets | sort_by(.id))}' <<<"$1") || return 1
  if cur=$(vault_index_decrypt 2>/dev/null); then
    canon_old=$(jq -c -S '{version: 1, secrets: (.secrets | sort_by(.id))}' <<<"$cur" 2>/dev/null || true)
    [[ "$canon_old" == "$idx" ]] && return 0
  fi
  rec=$(vault_recipient) || return 1
  tmp=$(mktemp) || return 1
  _vault_note_temp "$tmp"
  vault_arm_traps
  printf '%s\n' "$idx" > "$tmp"
  enc=$(vault_index_file)
  mkdir -p "$(dirname "$enc")"
  age -r "$rec" -o "$enc.new" "$tmp" 2>/dev/null || {
    _vault_drop_temp "$tmp"
    rm -f "$enc.new"
    printf 'replicant: could not encrypt the secret index\n' >&2
    return 1
  }
  mv -f -- "$enc.new" "$enc"
  _vault_drop_temp "$tmp"
}

# vault_blob_same <blobfile> <src>: 0 when the live file matches the
# decrypted blob, 1 when it differs or the blob does not decrypt. No index
# involved: status rows call this after resolving the blob themselves, so one
# status run decrypts the index once.
vault_blob_same() {
  local blobfile="$1" src="$2" plaindir plain idf
  [[ -f "$blobfile" && -f "$src" ]] || return 1
  plaindir=$(mktemp -d) || return 1
  plain="$plaindir/plain"
  _vault_note_temp "$plaindir"
  vault_arm_traps
  idf=$(vault_identity_file)
  if ! age -d -i "$idf" -o "$plain" "$blobfile" 2>/dev/null; then
    _vault_drop_tree "$plaindir"
    return 1
  fi
  if cmp -s "$src" "$plain" 2>/dev/null; then
    _vault_drop_tree "$plaindir"
    return 0
  fi
  _vault_drop_tree "$plaindir"
  return 1
}

# vault_restore_entry <rel>: decrypt one secret back onto the machine. The
# plaintext lands in a mode 600 temp beside the destination (or in the staged
# dir for paths outside $HOME, where the privileged step may outlive this
# call), the current file is backed up, and an atomic rename finishes it.
vault_restore_entry() {
  local rel="$1" src idx blob blobs plain staged backup apply restdir
  restdir=""
  vault_identity_ok || return 1
  idx=$(vault_index_decrypt) || return 1
  blob=$(vault_index_blob "$idx" "$rel")
  src=$(resolve_manifest_src "$rel") || { printf 'unknown id: %s\n' "$rel" >&2; return 1; }
  blobs=$(vault_blobs_dir)
  if [[ -z "$blob" || ! -f "$blobs/$blob.age" ]]; then
    printf '%s is not saved in your repo yet\n' "$rel" >&2
    return 1
  fi
  if [[ "$src" != "$HOME"/* ]]; then
    mkdir -p "$REPLICANT_HOME/staged" || return 1
    staged="$REPLICANT_HOME/staged/$(printf '%s' "$rel" | tr -c 'A-Za-z0-9._-' '_')"
    plain="$staged"
  else
    # Same filesystem as the destination, so the final rename is atomic.
    # age -o refuses an existing file, hence a fresh dir, not a mktemp file.
    restdir=$(mktemp -d -p "$(dirname "$src")" 2>/dev/null || mktemp -d) || return 1
    plain="$restdir/plain"
    _vault_note_temp "$restdir"
  fi
  _vault_note_temp "$plain"
  vault_arm_traps
  local idf
  idf=$(vault_identity_file)
  if ! age -d -i "$idf" -o "$plain" "$blobs/$blob.age" 2>/dev/null; then
    _vault_drop_restore_plain
    printf 'replicant: vault blob for %s does not decrypt — the live file is untouched\n' "$rel" >&2
    return 1
  fi
  chmod 600 "$plain" 2>/dev/null || true
  if [[ -f "$src" ]] && cmp -s "$plain" "$src" 2>/dev/null; then
    _vault_drop_restore_plain
    printf '%s already matches the copy in your repo\n' "$rel" >&2
    return 0
  fi
  if [[ "$src" != "$HOME"/* ]]; then
    # Through root_apply, which prints a sudo command naming the staged file
    # when nothing can ask for root. The staged copy then has to outlive this
    # call (like ini_set's), so a failure keeps it instead of dropping it.
    apply=$(apply_for_category "$(category_for_rel "$rel")")
    root_apply "$src" "$plain" "$apply"
    local rc=$?
    if (( rc == 0 )); then _vault_drop_temp "$plain"; else _vault_keep_temp "$plain"; fi
    return $rc
  fi
  if [[ -e "$src" ]]; then
    backup="$src.bak.$(date +%s)"
    cp -a -- "$src" "$backup" || { _vault_drop_restore_plain; return 1; }
  fi
  mv -T -- "$plain" "$src" || { _vault_drop_restore_plain; return 1; }
  chmod 600 "$src" 2>/dev/null || true
  _vault_drop_restore_plain
  apply=$(apply_for_category "$(category_for_rel "$rel")")
  [[ -n "$apply" ]] && bash -c "$apply" >/dev/null 2>&1 || true
  return 0
}

# key_init: one shared post-quantum identity for this setup, plus the repo's
# recipient. Refuses to overwrite an existing identity (rotate is the way to
# replace one) and refuses v1 repos (their secrets live in plaintext under
# secrets/ until the section 9 migration).
key_init() {
  crypto_require_keygen_pq || return 1
  [[ -e "$REPO_DIR/.git" ]] || { printf 'key: no repo here — run create, clone or init first\n' >&2; return 1; }
  [[ "$(repo_data_version)" == 2 ]] || {
    printf 'key: this repo uses the version 1 layout, which keeps secrets in plaintext under secrets/ — encrypted secrets need a version 2 repo\n' >&2
    return 1
  }
  local idf recf
  idf=$(vault_identity_file)
  [[ -f "$idf" ]] && { printf 'key: keys/identity.txt already exists — use key status to inspect it, key rotate to replace it\n' >&2; return 1; }
  mkdir -p "$(dirname "$idf")"
  chmod 700 "$(dirname "$idf")"
  ( umask 077; age-keygen -pq -o "$idf" 2>/dev/null ) || {
    rm -f -- "$idf"
    printf 'key: generation failed\n' >&2
    return 1
  }
  chmod 600 "$idf"
  local rec
  rec=$(age-keygen -y "$idf" 2>/dev/null || true)
  [[ "$rec" == age1pq1* ]] || {
    rm -f -- "$idf"
    printf 'key: the generated identity is not post-quantum — upgrade age, then retry\n' >&2
    return 1
  }
  recf=$(vault_recipient_file)
  printf '%s\n' "$rec" > "$recf"
  briefcache_invalidate
  printf 'key: identity created at keys/identity.txt (0600), recipient %s recorded — run savegame to encrypt your secrets\n' "$rec" >&2
}

# key_export <absolute-destination>: a backup of the identity outside the repo
# and the state dir, verified by deriving its recipient twice.
key_export() {
  local dest="$1" idf mine theirs
  [[ -n "$dest" ]] || { printf 'key: usage: key export <absolute-destination>\n' >&2; return 1; }
  [[ "$dest" == /* ]] || { printf 'key: the destination must be absolute: %s\n' "$dest" >&2; return 1; }
  case "$dest" in
    "$REPO_DIR"/*|"$REPLICANT_HOME"/*)
      printf 'key: refusing to export into the data repo or the state dir — pick a path outside both\n' >&2
      return 1 ;;
  esac
  idf=$(vault_identity_file)
  [[ -f "$idf" ]] || { printf 'key: no identity here — run key init or key import first\n' >&2; return 1; }
  mkdir -p "$(dirname "$dest")" || return 1
  install -m 600 "$idf" "$dest" || return 1
  mine=$(age-keygen -y "$idf" 2>/dev/null || true)
  theirs=$(age-keygen -y "$dest" 2>/dev/null || true)
  [[ -n "$theirs" && "$mine" == "$theirs" ]] || {
    rm -f -- "$dest"
    printf 'key: the export does not verify — removed again\n' >&2
    return 1
  }
  printf 'key: exported and verified (recipient %s)\n' "$theirs" >&2
}

# key_import <source>: adopt the shared identity on a new machine. It must
# parse and, when the repo already names a recipient, match it: anything else
# leaves every secret locked and says so.
key_import() {
  local src="$1" idf recf mine rec
  [[ -n "$src" && -f "$src" ]] || { printf 'key: usage: key import <source> (a file holding the shared identity)\n' >&2; return 1; }
  crypto_require_age || return 1
  mine=$(age-keygen -y "$src" 2>/dev/null || true)
  [[ "$mine" == age1* ]] || { printf 'key: %s is not a valid age identity\n' "$src" >&2; return 1; }
  recf=$(vault_recipient_file)
  if [[ -f "$recf" ]]; then
    rec=$(tr -d '[:space:]' < "$recf" 2>/dev/null || true)
    [[ "$mine" == "$rec" ]] || {
      printf 'key: this identity does not match the repo recipient — import the shared one, then retry\n' >&2
      return 1
    }
  fi
  idf=$(vault_identity_file)
  mkdir -p "$(dirname "$idf")"
  chmod 700 "$(dirname "$idf")"
  install -m 600 "$src" "$idf" || return 1
  if [[ ! -f "$recf" ]]; then
    printf '%s\n' "$mine" > "$recf"
    briefcache_invalidate
    printf 'key: imported, and recorded as this repos recipient — save to share it\n' >&2
  else
    briefcache_invalidate
    printf 'key: imported (recipient %s)\n' "$mine" >&2
  fi
}

# key_status: what the machine holds, what the repo names, and whether the
# two agree. Every failure names its remediation.
key_status() {
  crypto_require_age || return 1
  local idf recf mine rec
  idf=$(vault_identity_file)
  if [[ ! -f "$idf" ]]; then
    printf 'key: no identity on this machine — run key import <source>\n' >&2
    return 1
  fi
  mine=$(age-keygen -y "$idf" 2>/dev/null || true)
  if [[ "$mine" != age1* ]]; then
    printf 'key: keys/identity.txt is not a valid age identity — re-import with key import <source>\n' >&2
    return 1
  fi
  recf=$(vault_recipient_file)
  if [[ ! -f "$recf" ]]; then
    printf 'key: identity present, but the repo names no recipient — run key init on the first machine\n' >&2
    return 1
  fi
  rec=$(tr -d '[:space:]' < "$recf" 2>/dev/null || true)
  if [[ "$mine" != "$rec" ]]; then
    printf 'key: this identity does not match the repo recipient — run key import with the shared identity\n' >&2
    return 1
  fi
  printf 'key: ready (recipient %s)\n' "$rec"
}

# key_remediation: the one command that fixes the current key state, for
# doctor and for scripts. Prints e.g. "omarchy-replicant key import <source>".
# Never prints key material, only the command.
key_remediation() {
  local idf recf mine rec
  idf=$(vault_identity_file)
  if [[ ! -f "$idf" ]]; then
    printf 'omarchy-replicant key import <source>\n'
    return 0
  fi
  mine=$(age-keygen -y "$idf" 2>/dev/null || true)
  if [[ "$mine" != age1* ]]; then
    printf 'omarchy-replicant key import <source>\n'
    return 0
  fi
  recf=$(vault_recipient_file)
  if [[ ! -f "$recf" ]]; then
    printf 'omarchy-replicant key init\n'
    return 0
  fi
  rec=$(tr -d '[:space:]' < "$recf" 2>/dev/null || true)
  if [[ "$mine" != "$rec" ]]; then
    printf 'omarchy-replicant key import <source>\n'
    return 0
  fi
  printf 'omarchy-replicant key status\n'
}

# key_rotate: a new identity for the setup, with every blob re-encrypted to
# it. Built in a temp dir outside the repo and renamed over only on full
# success, so an interruption keeps the old vault working. Rotation cannot
# revoke the old key: ciphertext already pushed stays readable with it, and a
# compromised key needs a new clean repository instead.
key_rotate() {
  crypto_require_keygen_pq || return 1
  vault_identity_ok || return 1
  local idx old_idf new_idf new_rec work new_blobs
  idx=$(vault_index_decrypt) || return 1
  old_idf=$(vault_identity_file)
  work=$(mktemp -d) || return 1
  _vault_note_temp "$work"
  vault_arm_traps
  new_idf="$work/identity.txt"
  ( umask 077; age-keygen -pq -o "$new_idf" 2>/dev/null ) || {
    _vault_drop_tree "$work"
    printf 'key: generation failed — the old key is untouched\n' >&2
    return 1
  }
  new_rec=$(age-keygen -y "$new_idf" 2>/dev/null || true)
  [[ "$new_rec" == age1pq1* ]] || {
    _vault_drop_tree "$work"
    printf 'key: the generated identity is not post-quantum — the old key is untouched\n' >&2
    return 1
  }
  new_blobs="$work/blobs"
  mkdir -p "$new_blobs" || { _vault_drop_tree "$work"; return 1; }
  local blobs id blob plain
  blobs=$(vault_blobs_dir)
  while IFS=$'\t' read -r id blob; do
    [[ -n "$id" && -n "$blob" ]] || continue
    if [[ ! -f "$blobs/$blob.age" ]]; then
      _vault_drop_tree "$work"
      printf 'key: blob for %s is missing — the old key is untouched\n' "$id" >&2
      return 1
    fi
    plain="$work/$blob.plain"
    _vault_note_temp "$plain"
    if ! age -d -i "$old_idf" -o "$plain" "$blobs/$blob.age" 2>/dev/null; then
      _vault_drop_temp "$plain"
      _vault_drop_tree "$work"
      printf 'key: blob for %s does not decrypt — the old key is untouched\n' "$id" >&2
      return 1
    fi
    if ! age -r "$new_rec" -o "$new_blobs/$blob.age" "$plain" 2>/dev/null; then
      _vault_drop_temp "$plain"
      _vault_drop_tree "$work"
      printf 'key: re-encryption failed — the old key is untouched\n' >&2
      return 1
    fi
    _vault_drop_temp "$plain"
  done < <(jq -r '.secrets[] | [.id, .blob] | @tsv' <<<"$idx" 2>/dev/null)
  local new_index_tmp
  new_index_tmp="$work/index.json"
  _vault_note_temp "$new_index_tmp"
  jq -c -S '{version: 1, secrets: (.secrets | sort_by(.id))}' <<<"$idx" > "$new_index_tmp" || {
    _vault_drop_tree "$work"
    return 1
  }
  local enc recf
  enc=$(vault_index_file)
  age -r "$new_rec" -o "$enc.new" "$new_index_tmp" 2>/dev/null || {
    _vault_drop_tree "$work"
    rm -f "$enc.new"
    printf 'key: re-encryption failed — the old key is untouched\n' >&2
    return 1
  }
  mv -f -- "$enc.new" "$enc"
  local b
  for b in "$new_blobs"/*.age; do
    [[ -f "$b" ]] || continue
    mv -f -- "$b" "$blobs/$(basename "$b")"
  done
  install -m 600 "$new_idf" "$old_idf"
  recf=$(vault_recipient_file)
  printf '%s\n' "$new_rec" > "$recf"
  _vault_drop_temp "$new_index_tmp"
  _vault_drop_tree "$work"
  briefcache_invalidate
  printf 'key: rotated to recipient %s — old ciphertext already pushed stays readable with the old key\n' "$new_rec" >&2
}
