# shellcheck shell=bash disable=SC2034
# migrate.sh: one-way migration from the legacy v1 data repository to v2.
# It stages every result outside the active worktree and activates it only
# after validation, commit, remote push and an independent clone succeed.

migration_error() {
  printf 'migrate-v2: %s\n' "$1" >&2
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
    "$REPLICANT_HOME"/*|"REPO_DIR"/*)
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
    refs=$(git ls-remote "$remote" 2>/dev/null || true)
  fi
  [[ -z "$refs" ]] || { migration_error "the destination remote is not empty"; return 1; }
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

migration_encrypt_secrets() {
  local stage="$1" recipient="$2" index_file="$3"
  local row rel live old blob source scope blob_file
  local index='{"version":1,"secrets":[]}'
  mkdir -p "$stage/vault/blobs"
  for row in ${REGISTRY[@]+"${REGISTRY[@]}"}; do
    [[ "$(registry_field "$row" 2)" == secret ]] || continue
    rel=$(registry_field "$row" 1); live=$(registry_field "$row" 6)
    old=$(registry_field "$row" 7); scope=$(registry_field "$row" 5)
    source=""
    [[ -f "$live" ]] && source="$live"
    [[ -z "$source" && -f "$old" ]] && source="$old"
    [[ -n "$source" ]] || continue
    blob=$(migration_new_blob_id)
    [[ "$blob" =~ ^[0-9a-f]{32}$ ]] || { migration_error "could not create a secret blob id"; return 1; }
    blob_file="$stage/vault/blobs/$blob.age"
    age -r "$recipient" -o "$blob_file" "$source" 2>/dev/null || {
      migration_error "could not encrypt a secret entry"; return 1;
    }
    index=$(jq -c --arg id "$rel" --arg scope "$scope" --arg blob "$blob" \
      '.secrets += [{id:$id,scope:$scope,blob:$blob}]' <<<"$index") || return 1
  done
  printf '%s\n' "$index" > "$index_file"
}

migration_copy_tree() {
  local source="$1" stage="$2" name
  for name in config profiles state templates; do
    [[ -e "$source/$name" ]] || continue
    cp -a -- "$source/$name" "$stage/"
  done
  [[ -f "$source/.gitignore" ]] && cp -a -- "$source/.gitignore" "$stage/.gitignore"
  return 0
}

migration_verify_tree() {
  local stage="$1" remote="$2" verify="$3" roots
  [[ -x "$stage/bin/scan-secrets.sh" ]] || { migration_error "the staged scanner is missing"; return 1; }
  [[ ! -d "$stage/secrets" ]] || { migration_error "plaintext secrets reached the staged repository"; return 1; }
  ( REPO_DIR="$stage" validate_v2_entries "$stage/.replicant/entries.json" ) || return 1
  bash "$stage/bin/scan-secrets.sh" "$stage" >/dev/null 2>&1 || {
    migration_error "the staged repository failed the secret scanner"; return 1;
  }
  git clone -q -- "$remote" "$verify" 2>/dev/null || {
    migration_error "the independent verification clone failed"; return 1;
  }
  [[ "$(git -C "$verify" rev-list --max-parents=0 HEAD | wc -l)" == 1 ]] || {
    migration_error "the new repository does not have exactly one root commit"; return 1;
  }
  roots=$(git -C "$verify" ls-tree -r --name-only HEAD)
  grep -qE '(^|/)(\.replicant-track|\.replicant-sync|\.replicant-profiles|secrets/)' <<<"$roots" && {
    migration_error "legacy metadata or plaintext secrets are reachable in the new repository"; return 1;
  }
  return 0
}

# core_migrate_v2 --github-name <name> --identity-backup <absolute-path>
# [--remote <url>] [--yes]. The CLI parses nothing beyond this contract.
core_migrate_v2() {
  local github_name="" remote="" identity_backup="" yes=0 arg
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --github-name) github_name="${2:-}"; shift 2 ;;
      --remote) remote="${2:-}"; shift 2 ;;
      --identity-backup) identity_backup="${2:-}"; shift 2 ;;
      --yes|-y) yes=1; shift ;;
      -h|--help)
        echo "migrate-v2 --github-name <name> --identity-backup <absolute-path> [--remote <url>] [--yes]"
        return 0 ;;
      *) migration_error "unknown option: $arg"; return 1 ;;
    esac
  done
  (( yes )) || { migration_error "pass --yes after reviewing the migration summary"; return 1; }
  [[ -n "$identity_backup" ]] || { migration_error "--identity-backup is required"; return 1; }
  [[ -n "$remote" || -n "$github_name" ]] || { migration_error "provide --remote or --github-name"; return 1; }
  [[ -e "$REPO_DIR/.git" ]] || { migration_error "no active repository exists"; return 1; }
  [[ "$(repo_data_version)" == 1 ]] || { migration_error "the active repository is not a legacy v1 repository"; return 1; }
  [[ -z "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)" ]] || {
    migration_error "the active repository has uncommitted changes"; return 1;
  }
  if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    local ahead behind
    ahead=$(git -C "$REPO_DIR" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    behind=$(git -C "$REPO_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    (( ahead == 0 && behind == 0 )) || { migration_error "the active repository is not synchronized with its upstream"; return 1; }
  fi
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

  registry_build || return 1
  local uuid root stage identity recipient entries index_file legacy verify epoch old_identity
  uuid="$(date +%s)-$$-${RANDOM}"
  root="$REPLICANT_HOME/migration/$uuid"; stage="$root/repo"
  identity="$root/identity.txt"; entries="$root/entries.json"; index_file="$root/index.json"
  verify="$root/verify"; epoch=$(date +%s); legacy="$REPLICANT_HOME/legacy-repo-$epoch"
  mkdir -p "$stage/.replicant/machines" "$stage/vault/blobs" || return 1
  migration_copy_tree "$REPO_DIR" "$stage"
  [[ -f "$stage/.gitignore" ]] || printf '*.bak.*\n**/.cache/\n**/Cache/\n' > "$stage/.gitignore"
  mkdir -p "$stage/bin" "$stage/.githooks"
  cp -a "$PLUGIN_DIR/bin/scan-secrets.sh" "$stage/bin/scan-secrets.sh"
  precommit_hook_text > "$stage/.githooks/pre-commit"
  chmod +x "$stage/.githooks/pre-commit" "$stage/bin/scan-secrets.sh"
  migration_make_entries "$entries" || return 1
  mv -- "$entries" "$stage/.replicant/entries.json"
  jq -nc --argjson v "$SCHEMA_VERSION" --arg f "$SCHEMA_FORMAT" \
    '{dataVersion:$v,secretFormat:$f}' > "$stage/.replicant/schema.json"
  ( umask 077; age-keygen -pq -o "$identity" >/dev/null 2>&1 ) || {
    migration_error "post-quantum identity generation failed"; rm -rf -- "$root"; return 1;
  }
  recipient=$(age-keygen -y "$identity" 2>/dev/null || true)
  [[ "$recipient" == age1pq1* ]] || { migration_error "generated identity is not post-quantum"; rm -rf -- "$root"; return 1; }
  printf '%s\n' "$recipient" > "$stage/.replicant/recipient.txt"
  migration_encrypt_secrets "$stage" "$recipient" "$index_file" || { rm -rf -- "$root"; return 1; }
  age -r "$recipient" -o "$stage/vault/index.age" "$index_file" 2>/dev/null || {
    migration_error "could not encrypt the secret index"; rm -rf -- "$root"; return 1;
  }
  rm -f -- "$index_file"
  jq -nc --arg client "$(running_version)" --arg machine "$MACHINE" --arg profile "$(current_profile)" \
    --argjson schema "$SCHEMA_VERSION" \
    '{clientVersion:$client,machineId:$machine,profile:$profile,schemaVersion:$schema}' \
    > "$stage/.replicant/machines/$MACHINE.json"
  git -C "$stage" init -q -b main
  git -C "$stage" config user.name "${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || id -un)}"
  git -C "$stage" config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo replicant@localhost)}"
  git -C "$stage" config core.hooksPath .githooks
  ( REPO_DIR="$stage" validate_v2_entries "$stage/.replicant/entries.json" ) || { rm -rf -- "$root"; return 1; }
  git -C "$stage" add -A
  git -C "$stage" commit -qm "replicant: migrate to v2" || { migration_error "the root commit failed"; rm -rf -- "$root"; return 1; }

  if [[ -n "$github_name" ]]; then
    gh repo create "$github_name" --private --source "$stage" --remote origin --push >/dev/null || {
      migration_error "GitHub repository creation or push failed"; rm -rf -- "$root"; return 1;
    }
    remote=$(git -C "$stage" remote get-url origin)
  else
    git -C "$stage" remote add origin "$remote"
    git -C "$stage" push -q -u origin main || { migration_error "the migration push failed"; rm -rf -- "$root"; return 1; }
  fi
  migration_verify_tree "$stage" "$remote" "$verify" || { rm -rf -- "$root"; return 1; }

  mkdir -p "$(dirname -- "$identity_backup")" || { rm -rf -- "$root"; return 1; }
  install -m 600 "$identity" "$identity_backup" || { migration_error "could not write the identity backup"; rm -rf -- "$root"; return 1; }
  mkdir -p "$REPLICANT_HOME/keys"
  old_identity="$root/old-identity.txt"
  if [[ -f "$REPLICANT_HOME/keys/identity.txt" ]]; then cp -a "$REPLICANT_HOME/keys/identity.txt" "$old_identity"; fi
  install -m 600 "$identity" "$REPLICANT_HOME/keys/identity.txt" || {
    rm -f -- "$identity_backup"; rm -rf -- "$root"; return 1;
  }
  [[ ! -e "$legacy" ]] || { migration_error "legacy destination already exists"; rm -f -- "$identity_backup"; rm -rf -- "$root"; return 1; }
  mv -- "$REPO_DIR" "$legacy" || { rm -f -- "$identity_backup"; rm -rf -- "$root"; return 1; }
  if ! mv -- "$stage" "$REPO_DIR"; then
    mv -- "$legacy" "$REPO_DIR" 2>/dev/null || true
    rm -f -- "$identity_backup"; rm -rf -- "$root"; return 1
  fi
  printf '%s\n' "legacy_repo=$legacy" > "$REPLICANT_HOME/migration-warning"
  rm -rf -- "$root"
  briefcache_invalidate
  printf 'migrate-v2: complete. Legacy repository kept at %s\n' "$legacy" >&2
  printf 'migrate-v2: identity backup written to %s\n' "$identity_backup" >&2
}
