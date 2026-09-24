# shellcheck shell=bash disable=SC2034
# migrate.sh: one-way migration from the legacy v1 data repository to v2.
# It stages every result outside the active worktree and activates it only
# after validation, commit, remote push and an independent clone succeed.

migration_error() {
  printf 'migrate-v3: %s\n' "$1" >&2
  return 1
}

# core_migration_confirm records the user's acknowledgement outside the data
# repository. The panel calls this internal operation after its confirmation.
core_migration_confirm() {
  local marker="$REPLICANT_HOME/migration-warning"
  [[ -f "$marker" ]] || { migration_error "no legacy cleanup warning is pending"; return 1; }
  rm -f -- "$marker" || { migration_error "could not clear the legacy cleanup warning"; return 1; }
  printf 'migration: legacy cleanup confirmed\n' >&2
}

migration_safe_backup_path() {
  local dest="$1" parent
  [[ "$dest" == /* ]] || { migration_error "identity backup must be an absolute path"; return 1; }
  case "$dest" in
    "$REPLICANT_HOME"/*|"$REPO_DIR"/*)
      migration_error "identity backup must be outside the data repository and state directory"
      return 1 ;;
  esac
  parent=$(dirname -- "$dest")
  [[ -d "$parent" ]] || { migration_error "identity backup parent does not exist: $parent"; return 1; }
  [[ ! -e "$dest" ]] || { migration_error "identity backup already exists: $dest"; return 1; }
  [[ -w "$parent" ]] || { migration_error "identity backup parent is not writable: $parent"; return 1; }
}

migration_remote_empty() {
  local remote="$1" refs
  if [[ "$remote" == /* && -d "$remote" ]]; then
    refs=$(git -C "$remote" for-each-ref --format='%(refname)' 2>/dev/null || true)
  else
    git ls-remote "$remote" HEAD >/dev/null 2>&1 || {
      migration_error "the destination remote is not reachable: $remote"; return 1; }
    refs=$(git ls-remote "$remote" 2>/dev/null || true)
  fi
  [[ -z "$refs" ]] || { migration_error "the destination remote is not empty"; return 1; }
}

# migration_fail_at <stage>: fail when REPLICANT_FAIL_MIGRATION_AT names this
# stage (preflight, encrypt, commit, push, verify, or activate). Tests inject
# a failure at every migration boundary through it, proving that the active
# repository and the local identity survive untouched.
migration_fail_at() {
  [[ "${REPLICANT_FAIL_MIGRATION_AT:-}" == "$1" ]] || return 0
  printf 'migrate-v3: injected failure before %s\n' "$1" >&2
  return 1
}

# migration_machine_lines <v1|v2>: "<machine>\t<profile>" per recorded
# machine. Version 1 records machines as state/ directories with profiles in
# the legacy map; version 2 records them as .replicant/machines/*.json.
migration_machine_lines() {
  local src="$1" m p f
  if [[ "$src" == v2 ]]; then
    for f in "$REPO_DIR/.replicant/machines/"*.json; do
      [[ -f "$f" ]] || continue
      m=$(basename -- "$f" .json)
      validate_machine_id "$m" 2>/dev/null || continue
      p=$(jq -r '.profile // empty' "$f" 2>/dev/null || true)
      printf '%s\t%s\n' "$m" "${p:-unrecorded}"
    done
  else
    for f in "$REPO_DIR/state/"*/; do
      [[ -d "$f" ]] || continue
      m=$(basename -- "$f")
      validate_machine_id "$m" 2>/dev/null || continue
      p=$(legacy_profile_for_machine "$m" 2>/dev/null || true)
      printf '%s\t%s\n' "$m" "${p:-unrecorded}"
    done
  fi
  return 0
}

# migration_summary <v1|v2> <destination> <backup>: the pre-migration report.
# Reads only: the same summary prints with and without --yes, before any
# mutation. Every listed machine must be upgraded or offline before --yes.
migration_summary() {
  local src="$1" dest="$2" backup="$3"
  local row kind scope nconfig=0 nsecret=0 nshared=0 nprofile=0 noff=0
  local machines nmachines=0 line m p
  registry_build || { migration_error "could not read the legacy repository"; return 1; }
  for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
    kind=$(registry_field "$row" 2); scope=$(registry_field "$row" 5)
    if [[ "$kind" == secret ]]; then
      nsecret=$((nsecret + 1))
    else
      nconfig=$((nconfig + 1))
      case "$scope" in shared) nshared=$((nshared + 1)) ;; profile) nprofile=$((nprofile + 1)) ;; off) noff=$((noff + 1)) ;; esac
    fi
  done
  machines=$(migration_machine_lines "$src")
  nmachines=$(printf '%s\n' "$machines" | grep -c . || true)
  printf 'migrate-v3: source is a version %s repository at %s\n' "${src#v}" "$REPO_DIR" >&2
  while IFS=$'\t' read -r m p; do
    [[ -n "${m:-}" ]] || continue
    printf 'migrate-v3: machine %s (profile %s)\n' "$m" "$p" >&2
  done <<<"$machines"
  printf 'migrate-v3: %d machines, %d config entries (shared %d, profile %d, off %d), %d secrets\n' \
    "$nmachines" "$nconfig" "$nshared" "$nprofile" "$noff" "$nsecret" >&2
  printf 'migrate-v3: destination %s, identity backup %s\n' "$dest" "$backup" >&2
  return 0
}

migration_make_entries() {
  local outfile="$1" row id kind source scope live mapped
  {
    for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
      id=$(registry_field "$row" 1); kind=$(registry_field "$row" 2)
      source=$(registry_field "$row" 3); scope=$(registry_field "$row" 5)
      live=$(registry_field "$row" 6)
      [[ "$kind" == secret ]] && continue
      mapped=user; [[ "$source" != user ]] && mapped=override
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$id" "$live" "$kind" "$scope" "$mapped"
    done
  } | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\u001f") |
      {key:.[0], value:{path:.[1], kind:.[2], scope:.[3], source:.[4]}}) |
    from_entries' > "$outfile"
}

migration_new_blob_id() {
  od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]'
}

# migration_copy_tree_v3 <source> <stage>: copy only allowlisted state into
# the staged repository. Inventories that a restore consumes or a person
# rebuilds from travel; retired ones (defined-secrets.txt and its retired
# siblings) stay behind. Plaintext secrets/ and legacy policy files never do.
migration_copy_tree_v3() {
  local source="$1" stage="$2" name mdir base f
  for name in config profiles templates; do
    [[ -e "$source/$name" ]] || continue
    cp -a -- "$source/$name" "$stage/" || {
      migration_error "could not stage $name"; return 1; }
  done
  for mdir in "$source/state/"*/; do
    [[ -d "$mdir" ]] || continue
    base=$(basename -- "$mdir")
    validate_machine_id "$base" 2>/dev/null || continue
    mkdir -p -- "$stage/state/$base" || {
      migration_error "could not stage state/$base"; return 1; }
    for f in omarchy-plugins.txt omarchy-themes.txt drift-vs-omarchy.txt \
             cifs-mounts.txt user-services.txt pacman-*.txt; do
      [[ -f "$mdir/$f" ]] || continue
      cp -a -- "$mdir/$f" "$stage/state/$base/" || {
        migration_error "could not stage state/$base/$f"; return 1; }
    done
  done
  if [[ -f "$source/.gitignore" ]]; then
    cp -a -- "$source/.gitignore" "$stage/.gitignore" || {
      migration_error "could not stage .gitignore"; return 1; }
  else
    printf '*.bak.*\n**/.cache/\n**/Cache/\n' > "$stage/.gitignore"
  fi
  return 0
}

# migration_map_source <registry-source>: collapse a registry source into the
# version 3 provenance: user stays user, everything shipped collapses to
# override, the way the entries migration maps it.
migration_map_source() {
  [[ "$1" == user ]] && printf 'user\n' || printf 'override\n'
}

# migration_stage_secrets_v1 <stage> <recipient> <root>: encrypt every tracked
# secret from its live file or its committed repo copy into the staged vault,
# recording the version 2 index shape. A custom (user) secret with neither is
# a refusal naming the id: its path cannot be reconstructed. A shipped entry
# absent on this machine is skipped and counted in the summary instead.
migration_stage_secrets_v1() {
  local stage="$1" recipient="$2" root="$3"
  local row id live old scope provenance blob plaintext skipped=0
  local index='{"version":2,"secrets":[]}'
  mkdir -p -- "$stage/vault/blobs" || return 1
  : > "$root/plain.sha" || return 1
  for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
    [[ "$(registry_field "$row" 2)" == secret ]] || continue
    id=$(registry_field "$row" 1); live=$(registry_field "$row" 6)
    old=$(registry_field "$row" 7); scope=$(registry_field "$row" 5)
    provenance=$(migration_map_source "$(registry_field "$row" 3)")
    plaintext=""
    [[ -f "$live" ]] && plaintext="$live"
    [[ -z "$plaintext" && -f "$old" ]] && plaintext="$old"
    if [[ -z "$plaintext" ]]; then
      if [[ "$provenance" == user ]]; then
        migration_error "cannot reconstruct a path for secret '$id' — it is tracked but neither the live file nor a repo copy exists"
        return 1
      fi
      skipped=$((skipped + 1))
      continue
    fi
    blob=$(migration_new_blob_id)
    [[ "$blob" =~ ^[0-9a-f]{32}$ ]] || { migration_error "could not create a secret blob id"; return 1; }
    age -r "$recipient" -o "$stage/vault/blobs/$blob.age" "$plaintext" 2>/dev/null || {
      migration_error "could not encrypt secret '$id'"; return 1;
    }
    printf '%s\t%s\n' "$id" "$(sha256sum "$plaintext" | cut -d' ' -f1)" >> "$root/plain.sha" || return 1
    index=$(jq -c --arg id "$id" --arg path "$live" --arg scope "$scope" \
      --arg source "$provenance" --arg blob "$blob" \
      '.secrets += [{id:$id,path:$path,scope:$scope,source:$source,blob:$blob}]' <<<"$index") || return 1
  done
  index=$(jq -c '.secrets |= sort_by(.id)' <<<"$index") || return 1
  printf '%s\n' "$index" > "$root/index.json" || return 1
  printf 'migrate-v3: staged %d secrets from version 1 (%d shipped entries absent on this machine were skipped)\n' \
    "$(jq '.secrets | length' <<<"$index")" "$skipped" >&2
  return 0
}

# migration_stage_secrets_v2 <stage> <recipient> <root> <old-identity>:
# re-encrypt every committed version 1 vault entry to the new recipient,
# resolving each live path through the registry. An index entry no source
# names is a refusal: its path cannot be reconstructed.
migration_stage_secrets_v2() {
  local stage="$1" recipient="$2" root="$3" oldidf="$4"
  local oldidx entry id scope oldblob row live rscope provenance plain newblob
  local index='{"version":2,"secrets":[]}' nlive=0
  oldidx=$(vault_index_decrypt 2>/dev/null) || {
    migration_error "could not read the version 1 vault index"; return 1; }
  mkdir -p -- "$stage/vault/blobs" || return 1
  : > "$root/plain.sha" || return 1
  while IFS=$'\t' read -r id scope oldblob; do
    [[ -n "${id:-}" ]] || continue
    row=$(registry_row_for "$id" 2>/dev/null) || {
      migration_error "cannot reconstruct a path for secret '$id' — the vault names it but no source does"
      return 1; }
    live=$(registry_field "$row" 6); rscope=$(registry_field "$row" 5)
    provenance=$(migration_map_source "$(registry_field "$row" 3)")
    plain="$root/plain-$(printf '%s' "$id" | sha256sum | cut -d' ' -f1)"
    age -d -i "$oldidf" -o "$plain" "$REPO_DIR/vault/blobs/$oldblob.age" 2>/dev/null || {
      migration_error "could not decrypt the committed copy of secret '$id'"; return 1; }
    newblob=$(migration_new_blob_id)
    [[ "$newblob" =~ ^[0-9a-f]{32}$ ]] || { migration_error "could not create a secret blob id"; rm -f -- "$plain"; return 1; }
    age -r "$recipient" -o "$stage/vault/blobs/$newblob.age" "$plain" 2>/dev/null || {
      migration_error "could not re-encrypt secret '$id'"; rm -f -- "$plain"; return 1; }
    printf '%s\t%s\n' "$id" "$(sha256sum "$plain" | cut -d' ' -f1)" >> "$root/plain.sha" || { rm -f -- "$plain"; return 1; }
    rm -f -- "$plain"
    index=$(jq -c --arg id "$id" --arg path "$live" --arg scope "$rscope" \
      --arg source "$provenance" --arg blob "$newblob" \
      '.secrets += [{id:$id,path:$path,scope:$scope,source:$source,blob:$blob}]' <<<"$index") || return 1
  done < <(jq -r '.secrets | sort_by(.id)[] | [.id, .scope, .blob] | @tsv' <<<"$oldidx")
  for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
    [[ "$(registry_field "$row" 2)" == secret ]] || continue
    id=$(registry_field "$row" 1)
    jq -e --arg id "$id" '.secrets | map(.id) | index($id)' <<<"$oldidx" >/dev/null 2>&1 && continue
    live=$(registry_field "$row" 6)
    if [[ -f "$live" ]]; then
      rscope=$(registry_field "$row" 5)
      provenance=$(migration_map_source "$(registry_field "$row" 3)")
      newblob=$(migration_new_blob_id)
      [[ "$newblob" =~ ^[0-9a-f]{32}$ ]] || { migration_error "could not create a secret blob id"; return 1; }
      age -r "$recipient" -o "$stage/vault/blobs/$newblob.age" "$live" 2>/dev/null || {
        migration_error "could not encrypt secret '$id'"; return 1; }
      printf '%s\t%s\n' "$id" "$(sha256sum "$live" | cut -d' ' -f1)" >> "$root/plain.sha" || return 1
      index=$(jq -c --arg id "$id" --arg path "$live" --arg scope "$rscope" \
        --arg source "$provenance" --arg blob "$newblob" \
        '.secrets += [{id:$id,path:$path,scope:$scope,source:$source,blob:$blob}]' <<<"$index") || return 1
      nlive=$((nlive + 1))
    elif [[ "$(migration_map_source "$(registry_field "$row" 3)")" == user ]]; then
      migration_error "cannot reconstruct a path for secret '$id' — it is tracked but neither the vault nor the machine holds it"
      return 1
    fi
  done
  index=$(jq -c '.secrets |= sort_by(.id)' <<<"$index") || return 1
  printf '%s\n' "$index" > "$root/index.json" || return 1
  printf 'migrate-v3: re-encrypted %d secrets from version 2 (%d taken from live files, never committed)\n' \
    "$(jq '.secrets | length' <<<"$index")" "$nlive" >&2
  return 0
}

# migration_stage_machines <v1|v2> <stage>: write every recorded machine as a
# version 3 machine record, preserving ids and profiles.
migration_stage_machines() {
  local src="$1" stage="$2" m p f client
  client=$(running_version)
  mkdir -p -- "$stage/.replicant/machines" || return 1
  while IFS=$'\t' read -r m p; do
    [[ -n "${m:-}" ]] || continue
    [[ "$p" == unrecorded ]] && p=$(guess_profile)
    validate_machine_id "$m" || return 1
    jq -nc --arg id "$m" --arg profile "$p" --arg client "$client" \
      '{machineId: $id, profile: $profile, clientVersion: $client, schemaVersion: 3}' \
      > "$stage/.replicant/machines/$m.json" || {
      migration_error "could not record machine $m"; return 1; }
  done < <(migration_machine_lines "$src")
  if [[ "$src" == v1 && ! -f "$stage/.replicant/machines/$MACHINE.json" ]]; then
    validate_machine_id "$MACHINE" || return 1
    p=$(guess_profile)
    jq -nc --arg id "$MACHINE" --arg profile "$p" --arg client "$client" \
      '{machineId: $id, profile: $profile, clientVersion: $client, schemaVersion: 3}' \
      > "$stage/.replicant/machines/$MACHINE.json" || return 1
  fi
  [[ -n "$(ls -A -- "$stage/.replicant/machines" 2>/dev/null)" ]] || {
    migration_error "no machine record was staged"; return 1; }
  return 0
}

# migration_verify_local <stage> <root> <identity>: verify the complete staged
# repository before any push: marker, legacy ban, entries, the version 2
# index (decrypted with the new identity), every secret decrypted and
# compared, every non-secret digest and permission, and the secret scanner.
migration_verify_local() {
  local stage="$1" root="$2" identity="$3"
  local idx_plain idx entry id blob want got f rel src
  ( REPO_DIR="$stage" _schema_marker_valid ) || {
    migration_error "the staged schema marker is invalid"; return 1; }
  ( REPO_DIR="$stage" v3_no_legacy_files ) || return 1
  ( REPO_DIR="$stage" validate_v3_entries "$stage/.replicant/entries.json" ) || return 1
  idx_plain=$(age -d -i "$identity" -o - "$stage/vault/index.age" 2>/dev/null) || {
    migration_error "the staged vault index does not decrypt with the new identity"; return 1; }
  ( REPO_DIR="$stage" vault_index_validate "$idx_plain" ) || return 1
  while IFS=$'\t' read -r id blob; do
    [[ -n "${id:-}" ]] || continue
    [[ "$blob" =~ ^[0-9a-f]{32}$ ]] || { migration_error "staged secret '$id' has a bad blob id"; return 1; }
    [[ -f "$stage/vault/blobs/$blob.age" ]] || { migration_error "staged secret '$id' is missing its blob"; return 1; }
    want=$(awk -F'\t' -v want="$id" '$1 == want {print $2}' "$root/plain.sha" 2>/dev/null || true)
    [[ -n "$want" ]] || { migration_error "staged secret '$id' has no recorded plaintext digest"; return 1; }
    got=$(age -d -i "$identity" -o - "$stage/vault/blobs/$blob.age" 2>/dev/null | sha256sum | cut -d' ' -f1) || {
      migration_error "staged secret '$id' does not decrypt with the new identity"; return 1; }
    [[ "$got" == "$want" ]] || { migration_error "staged secret '$id' decrypts to different bytes"; return 1; }
  done < <(jq -r '.secrets[] | [.id, .blob] | @tsv' <<<"$idx_plain")
  for f in "$stage/config" "$stage/profiles" "$stage/state" "$stage/templates" \
           "$stage/.gitignore" "$stage/bin/scan-secrets.sh" "$stage/.githooks/pre-commit"; do
    [[ -e "$f" ]] || continue
    if [[ -d "$f" ]]; then
      while IFS= read -r -d '' g; do
        rel="${g#$stage/}"; src="$REPO_DIR/$rel"
        [[ -f "$src" ]] || { migration_error "staged file $rel has no source to compare"; return 1; }
        cmp -s -- "$src" "$g" || { migration_error "staged file $rel differs from its source"; return 1; }
        [[ "$(stat -c '%a' "$src")" == "$(stat -c '%a' "$g")" ]] || {
          migration_error "staged file $rel lost its permissions"; return 1; }
      done < <(find "$f" -type f -print0 2>/dev/null)
    else
      rel="${f#$stage/}"; src="$REPO_DIR/$rel"
      [[ -f "$src" ]] || continue
      cmp -s -- "$src" "$f" || { migration_error "staged file $rel differs from its source"; return 1; }
      [[ "$(stat -c '%a' "$src")" == "$(stat -c '%a' "$f")" ]] || {
        migration_error "staged file $rel lost its permissions"; return 1; }
    fi
  done
  [[ -x "$stage/bin/scan-secrets.sh" ]] || { migration_error "the staged scanner is missing"; return 1; }
  bash "$stage/bin/scan-secrets.sh" "$stage" >/dev/null 2>&1 || {
    migration_error "the staged repository failed the secret scanner"; return 1;
  }
  return 0
}

# migration_verify_remote <remote> <verify> <identity> <count>: clone the
# pushed repository independently and check the result before activation.
migration_verify_remote() {
  local remote="$1" verify="$2" identity="$3" count="$4"
  local roots idx_plain n
  git clone -q -- "$remote" "$verify" 2>/dev/null || {
    migration_error "the independent verification clone failed — retry 'git clone $remote'"; return 1;
  }
  [[ "$(git -C "$verify" rev-list --max-parents=0 HEAD | wc -l)" == 1 ]] || {
    migration_error "the new repository does not have exactly one root commit"; return 1;
  }
  roots=$(git -C "$verify" ls-tree -r --name-only HEAD)
  grep -qE '(^|/)(\.replicant-track|\.replicant-sync|\.replicant-profiles|\.replicant-exclude|secrets/)' <<<"$roots" && {
    migration_error "legacy metadata or plaintext secrets are reachable in the new repository"; return 1;
  }
  ( REPO_DIR="$verify" validate_v3_entries "$verify/.replicant/entries.json" ) || return 1
  idx_plain=$(age -d -i "$identity" -o - "$verify/vault/index.age" 2>/dev/null) || {
    migration_error "the pushed vault index does not decrypt with the new identity"; return 1; }
  ( REPO_DIR="$verify" vault_index_validate "$idx_plain" ) || return 1
  n=$(jq '.secrets | length' <<<"$idx_plain" 2>/dev/null || echo -1)
  [[ "$n" == "$count" ]] || {
    migration_error "the pushed vault holds $n secrets, the staged one held $count"; return 1; }
  return 0
}

# migration_journal_write <journal> <phase> <src> <legacy> <remote> <backup>:
# record the migration stage. The journal (with the journaled old identity
# beside it) survives every failure until activation completes, so a failed
# run can restore the repository and the identity it started from.
migration_journal_write() {
  local journal="$1" phase="$2" src="$3" legacy="$4" remote="$5" backup="$6"
  jq -nc --arg phase "$phase" --arg src "$src" --arg legacy "$legacy" \
    --arg remote "$remote" --arg backup "$backup" \
    '{version: 1, phase: $phase, source: $src, legacy_repo: $legacy, remote: $remote, identity_backup: $backup}' \
    > "$journal" || { migration_error "could not write the recovery journal"; return 1; }
  return 0
}

# migration_cleanup_failure <root> <backup>: drop everything a failed run
# staged (repo, clone, keys, plaintext digests) but keep the journal and the
# journaled old identity. A backup file this run wrote is removed so a retry
# starts clean; the message says so.
migration_cleanup_failure() {
  local root="$1" backup="$2"
  rm -rf -- "$root/repo" "$root/verify" "$root/identity.txt" "$root/index.json" \
    "$root/entries.json" "$root"/plain-* 2>/dev/null || true
  if [[ -n "$backup" && -f "$backup" ]]; then
    rm -f -- "$backup"
    printf 'migrate-v3: the identity backup from this failed run was removed — retry from a clean state\n' >&2
  fi
  return 0
}

# migration_restore_identity <root>: reinstall the journaled old identity, or
# remove the new one when there was none. Runs after every failure at or past
# the identity switch, so the machine keeps a usable identity.
migration_restore_identity() {
  local root="$1"
  if [[ -f "$root/old-identity.txt" ]]; then
    mkdir -p -- "$REPLICANT_HOME/keys" 2>/dev/null || true
    install -m 600 "$root/old-identity.txt" "$REPLICANT_HOME/keys/identity.txt" 2>/dev/null || {
      migration_error "could not restore the original identity from the recovery journal"; return 1; }
  else
    rm -f -- "$REPLICANT_HOME/keys/identity.txt" 2>/dev/null || true
  fi
  return 0
}

# migration_check_upstream: the active repository must track an upstream and
# be exactly synchronized with it. Each state names its own recovery.
migration_check_upstream() {
  local ahead behind
  if ! git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    migration_error "the active repository has no upstream tracking — push it and set the upstream (git push -u), then retry"
    return 1
  fi
  ahead=$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  behind=$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  if (( ahead > 0 && behind > 0 )); then
    migration_error "the active repository has diverged from its upstream (ahead $ahead, behind $behind) — pull and push until synchronized, then retry"
    return 1
  fi
  if (( ahead > 0 )); then
    migration_error "the active repository is ahead of its upstream by $ahead commit(s) — push, then retry"
    return 1
  fi
  if (( behind > 0 )); then
    migration_error "the active repository is behind its upstream by $behind commit(s) — pull, then retry"
    return 1
  fi
  return 0
}

# migration_guard_old_identity <root>: when the source vault holds committed
# ciphertext, journal the existing identity and prove it decrypts the old
# index before any remote mutation. A locked vault refuses with its remedy.
migration_guard_old_identity() {
  local root="$1" idf old plain
  [[ -f "$REPO_DIR/vault/index.age" ]] || return 0
  idf=$(vault_identity_file)
  if [[ ! -f "$idf" ]]; then
    migration_error "the vault is locked — run 'key import <source>' with the shared identity, then retry"
    return 1
  fi
  old="$root/old-identity.txt"
  ( umask 077; cp -a -- "$idf" "$old" && chmod 600 -- "$old" ) || {
    migration_error "could not journal the existing identity"; return 1; }
  plain="$root/old-index-check"
  age -d -i "$old" -o "$plain" "$REPO_DIR/vault/index.age" 2>/dev/null || {
    migration_error "the existing identity does not decrypt the vault — run 'key status', re-import the shared identity, then retry"
    rm -f -- "$plain"; return 1; }
  jq -e '.version == 1 and (.secrets | type) == "array"' "$plain" >/dev/null 2>&1 || {
    migration_error "the existing vault index is unreadable"; rm -f -- "$plain"; return 1; }
  rm -f -- "$plain"
  return 0
}

# core_migrate_v3 --github-name <name> --identity-backup <absolute-path>
# [--remote <url>] [--yes]: migrate a clean v1 or v2 repository into a new
# encrypted v3 repository. Without --yes it prints the migration summary and
# stops: --yes acknowledges that every recorded machine is upgraded or
# offline. The CLI parses nothing beyond this contract.
core_migrate_v3() {
  local github_name="" remote="" identity_backup="" yes=0 arg
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --github-name) github_name="${2:-}"; shift 2 ;;
      --remote) remote="${2:-}"; shift 2 ;;
      --identity-backup) identity_backup="${2:-}"; shift 2 ;;
      --yes|-y) yes=1; shift ;;
      -h|--help)
        echo "migrate-v3 --github-name <name> --identity-backup <absolute-path> [--remote <url>] [--yes]"
        return 0 ;;
      *) migration_error "unknown option: $arg"; return 1 ;;
    esac
  done
  [[ -n "$identity_backup" ]] || { migration_error "--identity-backup is required"; return 1; }
  [[ -n "$remote" || -n "$github_name" ]] || { migration_error "provide --remote or --github-name"; return 1; }
  [[ -e "$REPO_DIR/.git" ]] || { migration_error "no active repository exists"; return 1; }
  local src_version
  case "$(repo_data_version)" in
    1) src_version=v1 ;;
    2) src_version=v2 ;;
    3) migration_error "the active repository is already version 3 — nothing to migrate"; return 1 ;;
    *) migration_error "the active repository uses an unreadable data format — restore it from git history, then retry"; return 1 ;;
  esac

  local dest="${remote:-github:$github_name}"
  # The tracked lists were built at source time: reload them from the
  # committed repository, or entries committed after sourcing are invisible.
  load_user_manifest || { migration_error "could not read the legacy repository"; return 1; }
  load_auto_manifest || { migration_error "could not read the legacy repository"; return 1; }
  invalidate_scopes_cache 2>/dev/null || true
  migration_summary "$src_version" "$dest" "$identity_backup" || return 1
  (( yes )) || {
    migration_error "pass --yes after reviewing the migration summary above — it acknowledges that every recorded machine is upgraded or offline"
    return 1; }

  [[ -z "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)" ]] || {
    migration_error "the active repository has uncommitted changes — save or discard the worktree changes, then retry"; return 1;
  }
  migration_check_upstream || return 1
  migration_safe_backup_path "$identity_backup" || return 1
  crypto_require_age || return 1
  crypto_require_keygen_pq || return 1
  [[ -d "$REPLICANT_HOME" && -w "$REPLICANT_HOME" ]] || { migration_error "the Replicant state directory is not writable"; return 1; }
  if [[ -n "$remote" ]]; then migration_remote_empty "$remote" || return 1; fi
  if [[ -n "$github_name" ]]; then
    [[ "$github_name" =~ ^[A-Za-z0-9._-]+$ ]] || { migration_error "invalid GitHub repository name"; return 1; }
    command -v gh >/dev/null 2>&1 || { migration_error "gh is required for --github-name"; return 1; }
    if gh repo view "$github_name" >/dev/null 2>&1; then
      migration_error "the GitHub repository already exists: $github_name"; return 1
    fi
  fi

  registry_build || { migration_error "could not read the legacy repository"; return 1; }
  local uuid root stage identity recipient entries journal legacy verify epoch count
  uuid="$(date +%s)-$$-${RANDOM}"
  root="$REPLICANT_HOME/migration/$uuid"; stage="$root/repo"
  identity="$root/identity.txt"; entries="$root/entries.json"
  journal="$root/journal.json"
  verify="$root/verify"; epoch=$(date +%s); legacy="$REPLICANT_HOME/legacy-repo-$epoch"
  mkdir -p -- "$root" || return 1
  migration_journal_write "$journal" preflight "$src_version" "$legacy" "$dest" "$identity_backup" || {
    rm -rf -- "$root"; return 1; }
  if ! migration_fail_at preflight; then migration_cleanup_failure "$root" ""; return 1; fi
  if [[ -f "$REPLICANT_HOME/keys/identity.txt" && ! -f "$root/old-identity.txt" ]]; then
    ( umask 077; cp -a -- "$REPLICANT_HOME/keys/identity.txt" "$root/old-identity.txt" \
      && chmod 600 -- "$root/old-identity.txt" ) || {
      migration_error "could not journal the existing identity"; migration_cleanup_failure "$root" ""; return 1; }
  fi
  migration_guard_old_identity "$root" || { migration_cleanup_failure "$root" ""; return 1; }

  mkdir -p -- "$stage/.replicant/machines" "$stage/vault/blobs" || {
    migration_error "could not stage the new repository"; migration_cleanup_failure "$root" ""; return 1; }
  migration_copy_tree_v3 "$REPO_DIR" "$stage" || { migration_cleanup_failure "$root" ""; return 1; }
  mkdir -p -- "$stage/bin" "$stage/.githooks"
  cp -a -- "$PLUGIN_DIR/bin/scan-secrets.sh" "$stage/bin/scan-secrets.sh" || {
    migration_error "could not stage the secret scanner"; migration_cleanup_failure "$root" ""; return 1; }
  precommit_hook_text > "$stage/.githooks/pre-commit"
  chmod +x "$stage/.githooks/pre-commit" "$stage/bin/scan-secrets.sh"
  migration_make_entries "$entries" || { migration_cleanup_failure "$root" ""; return 1; }
  mv -- "$entries" "$stage/.replicant/entries.json"
  jq -nc --argjson v "$SCHEMA_VERSION" --arg f "$SCHEMA_FORMAT" \
    '{dataVersion: $v, secretFormat: $f}' > "$stage/.replicant/schema.json" || {
    migration_error "could not stage the schema marker"; migration_cleanup_failure "$root" ""; return 1; }
  ( umask 077; age-keygen -pq -o "$identity" >/dev/null 2>&1 ) || {
    migration_error "post-quantum identity generation failed"; migration_cleanup_failure "$root" ""; return 1;
  }
  recipient=$(age-keygen -y "$identity" 2>/dev/null || true)
  [[ "$recipient" == age1pq1* ]] || {
    migration_error "generated identity is not post-quantum"; migration_cleanup_failure "$root" ""; return 1; }
  printf '%s\n' "$recipient" > "$stage/.replicant/recipient.txt"
  if ! migration_fail_at encrypt; then migration_cleanup_failure "$root" ""; return 1; fi
  if [[ "$src_version" == v1 ]]; then
    migration_stage_secrets_v1 "$stage" "$recipient" "$root" || { migration_cleanup_failure "$root" ""; return 1; }
  else
    migration_stage_secrets_v2 "$stage" "$recipient" "$root" "$root/old-identity.txt" || {
      migration_cleanup_failure "$root" ""; return 1; }
  fi
  age -r "$recipient" -o "$stage/vault/index.age" "$root/index.json" 2>/dev/null || {
    migration_error "could not encrypt the secret index"; migration_cleanup_failure "$root" ""; return 1;
  }
  rm -f -- "$root/index.json"
  count=$(age -d -i "$identity" -o - "$stage/vault/index.age" 2>/dev/null | jq '.secrets | length' 2>/dev/null || echo -1)
  migration_stage_machines "$src_version" "$stage" || { migration_cleanup_failure "$root" ""; return 1; }
  migration_journal_write "$journal" staged "$src_version" "$legacy" "$dest" "$identity_backup" || {
    migration_cleanup_failure "$root" ""; return 1; }
  git -C "$stage" init -q -b main
  git -C "$stage" config user.name "${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || id -un)}"
  git -C "$stage" config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo replicant@localhost)}"
  git -C "$stage" config core.hooksPath .githooks
  git -C "$stage" add -A
  if ! migration_fail_at commit; then migration_cleanup_failure "$root" ""; return 1; fi
  git -C "$stage" commit -qm "replicant: migrate to v3" || {
    migration_error "the root commit failed"; migration_cleanup_failure "$root" ""; return 1; }
  migration_verify_local "$stage" "$root" "$identity" || { migration_cleanup_failure "$root" ""; return 1; }
  migration_journal_write "$journal" verified "$src_version" "$legacy" "$dest" "$identity_backup" || {
    migration_cleanup_failure "$root" ""; return 1; }

  mkdir -p -- "$(dirname -- "$identity_backup")" || { migration_cleanup_failure "$root" ""; return 1; }
  install -m 600 "$identity" "$identity_backup" || {
    migration_error "could not write the identity backup"; migration_cleanup_failure "$root" ""; return 1; }
  if ! migration_fail_at push; then migration_cleanup_failure "$root" "$identity_backup"; return 1; fi
  if [[ -n "$github_name" ]]; then
    gh repo create "$github_name" --private --source "$stage" --remote origin --push >/dev/null || {
      migration_error "GitHub repository creation or push failed — the staged migration is kept in the recovery journal; fix access, then retry"; migration_cleanup_failure "$root" "$identity_backup"; return 1;
    }
    remote=$(git -C "$stage" remote get-url origin)
    if [[ "$(gh repo view "$github_name" --json visibility --jq .visibility 2>/dev/null || echo "")" == PUBLIC ]]; then
      migration_error "the new GitHub repository is PUBLIC — switch it to private by hand; the staged migration is kept in the recovery journal"
      migration_cleanup_failure "$root" "$identity_backup"; return 1
    fi
  else
    git -C "$stage" remote add origin "$remote"
    git -C "$stage" push -q -u origin main || {
      migration_error "the migration push failed — the staged migration is kept in the recovery journal; run 'omarchy-replicant pull' on the old repo state, then retry"
      migration_cleanup_failure "$root" "$identity_backup"; return 1; }
  fi
  migration_journal_write "$journal" pushed "$src_version" "$legacy" "$dest" "$identity_backup" || {
    migration_cleanup_failure "$root" "$identity_backup"; return 1; }
  if ! migration_fail_at verify; then migration_cleanup_failure "$root" "$identity_backup"; return 1; fi
  migration_verify_remote "$remote" "$verify" "$identity" "$count" || {
    migration_cleanup_failure "$root" "$identity_backup"; return 1; }

  mkdir -p -- "$REPLICANT_HOME/keys"
  install -m 600 "$identity" "$REPLICANT_HOME/keys/identity.txt" || {
    migration_error "could not install the new identity"; migration_cleanup_failure "$root" "$identity_backup"; return 1;
  }
  [[ ! -e "$legacy" ]] || {
    migration_error "legacy destination already exists: $legacy"
    migration_restore_identity "$root"; migration_cleanup_failure "$root" "$identity_backup"; return 1; }
  migration_journal_write "$journal" activating "$src_version" "$legacy" "$dest" "$identity_backup" || {
    migration_restore_identity "$root"; migration_cleanup_failure "$root" "$identity_backup"; return 1; }
  if ! migration_fail_at activate; then
    migration_restore_identity "$root"; migration_cleanup_failure "$root" "$identity_backup"; return 1
  fi
  mv -- "$REPO_DIR" "$legacy" || {
    migration_restore_identity "$root"; migration_cleanup_failure "$root" "$identity_backup"; return 1; }
  if ! mv -- "$stage" "$REPO_DIR"; then
    mv -- "$legacy" "$REPO_DIR" 2>/dev/null || true
    migration_error "activation failed — the original repository was restored; the staged migration is kept in the recovery journal"
    migration_restore_identity "$root"; migration_cleanup_failure "$root" "$identity_backup"; return 1
  fi
  printf '%s\n' "legacy_repo=$legacy" > "$REPLICANT_HOME/migration-warning"
  rm -rf -- "$root"
  briefcache_invalidate
  printf 'migrate-v3: complete. Legacy repository kept at %s\n' "$legacy" >&2
  printf 'migrate-v3: identity backup written to %s\n' "$identity_backup" >&2
}

# core_migrate_v2: deprecated forwarding alias for migrate-v3, kept for one
# release. It migrates to version 3, never to version 2.
core_migrate_v2() {
  printf 'migrate-v2 is deprecated — it migrates to version 3 now; use migrate-v3\n' >&2
  core_migrate_v3 "$@"
}
