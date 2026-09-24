# shellcheck shell=bash disable=SC2034
# layout.sh: the repo layout and the pre-commit hook.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# The pre-commit hook of the data repo. It fails closed: if it cannot find the
# scanner, it blocks the commit. It used to exit 0 in that case, and the
# scanner is the last check between a token and GitHub.
precommit_hook_text() {
  cat <<'HOOK'
#!/bin/bash
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
files=$(git diff --cached --name-only --diff-filter=ACM)
[[ -z $files ]] && exit 0
SCAN="$REPO/bin/scan-secrets.sh"
[[ -x "$SCAN" ]] || SCAN="$HOME/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/scan-secrets.sh"
if [[ ! -x "$SCAN" ]]; then
  echo "COMMIT BLOCKED: the secret scanner is missing. Run 'omarchy-replicant backup' to put it back." >&2
  exit 1
fi
fail=0
while IFS= read -r file; do
  [[ -f $file ]] || continue
  [[ $file == secrets/* ]] && continue
  # Vault blobs and the encrypted index are random bytes by design: the
  # scanner skips binaries on its own, and naming them here keeps that fast
  # path obvious instead of incidental.
  [[ $file == *.age ]] && continue
  git show ":$file" 2>/dev/null | "$SCAN" --stdin "$file" || fail=1
done <<<"$files"
if (( fail )); then
  echo "COMMIT BLOCKED: possible credential in config/state/templates." >&2
  exit 1
fi
HOOK
}

ensure_repo_layout() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$TEMPLATES_DIR"
  # A repo written before state/ was scoped by machine has its inventory flat in
  # state/. Move it under this machine's name rather than leaving two shapes to
  # support forever; git records the move like any other change.
  # `mv -n` is not enough: it exits 0 and does NOTHING when the target already
  # exists, so a half-migrated repo kept a stale flat copy of every inventory
  # file next to the scoped one, forever. The scoped copy is regenerated from
  # this machine on every backup, so where both exist it is the newer of the
  # two and the flat one is what goes.
  local flat name
  for flat in "$STATE_ROOT"/*.txt; do
    [[ -f "$flat" ]] || continue
    name=$(basename "$flat")
    if [[ -f "$STATE_DIR/$name" ]]; then
      rm -f -- "$flat"
    else
      mv -- "$flat" "$STATE_DIR/$name" 2>/dev/null || true
    fi
  done
  # git init if needed. A repo born here is born v3: the schema marks the
  # format every writer after it must understand. The skeleton lands before
  # the scope and track ensures below, so those gates see the marker and a
  # fresh v3 repo never grows legacy policy files. A repo that already has
  # history keeps whatever it has: v1 and v2 stay readable until the
  # migrate-v3 migration, and a v3 clone only refreshes this machine's own
  # metadata below.
  # -e, not -d: a save transaction works in a linked worktree, whose .git is
  # a file pointing at the main repo. Re-running init there would break it.
  if [[ ! -e "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" init -q -b main
    git -C "$REPO_DIR" config init.defaultBranch main 2>/dev/null || true
    # $USER is not set everywhere (a container, a systemd unit). Under set -u its
    # absence wrote an empty identity, and every commit after it failed. Ask the
    # system instead.
    local who; who=$(id -un)
    git -C "$REPO_DIR" config user.name  "${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || echo "$who")}"
    git -C "$REPO_DIR" config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo "$who@omarchy-replicant")}"
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
    ensure_v3_layout
    # The tracked lists were built at source time, before this repo existed:
    # a fallback read then may have invented entries the canonical stores do
    # not hold. Rebuild them now, so the copy and prune passes below see the
    # version 3 records and never copy a file nothing tracks.
    load_user_manifest
    load_auto_manifest
    invalidate_scopes_cache
  else
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
    if [[ "$(repo_data_version)" == 3 ]]; then machine_metadata_write; fi
  fi
  ensure_scope_file
  if ! repo_is_v3; then
    ensure_track_file
    migrate_retired_shipped
  fi
  record_repo_version
  mkdir -p "$REPO_DIR/profiles/$(current_profile)/config" 2>/dev/null || true
  install -d -m 700 "$SECRETS_DIR" 2>/dev/null || mkdir -p "$SECRETS_DIR"
  # The hook is kept in step with the plugin, like the scanner below. It was
  # written once, so a repo made by an old release kept that hook forever.
  mkdir -p "$GITHOOKS_DIR"
  if ! cmp -s <(precommit_hook_text) "$GITHOOKS_DIR/pre-commit" 2>/dev/null; then
    precommit_hook_text > "$GITHOOKS_DIR/pre-commit"
  fi
  chmod +x "$GITHOOKS_DIR/pre-commit"
  # scan-secrets bin — kept in step with the plugin, not just seeded once.
  #
  # The repo's pre-commit hook runs THIS copy, so a repo created in June was
  # still checking for the four credential shapes the plugin knew about then.
  # Teaching the plugin a new one has to reach the repos that already exist, or
  # the improvement only ever protects people who install for the first time.
  # It is plugin-provided infrastructure, not the user's data, and every
  # version of it is in git — so replacing it is safe and is the point.
  if [[ -f "$PLUGIN_DIR/bin/scan-secrets.sh" ]]; then
    if ! cmp -s "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null; then
      mkdir -p "$REPO_DIR/bin"
      [[ -f "$REPO_DIR/bin/scan-secrets.sh" ]] &&
        echo "  · updating the repo's secret scanner to this version's" >&2
      cp -a "$PLUGIN_DIR/bin/scan-secrets.sh" "$REPO_DIR/bin/scan-secrets.sh"
    fi
  fi
  chmod +x "$REPO_DIR/bin/scan-secrets.sh" 2>/dev/null || true
  # .gitignore — savegame style (state/ is generated, .bak.* ignored, secrets/ tracked)
  if [[ ! -f "$REPO_DIR/.gitignore" ]]; then
    cat >"$REPO_DIR/.gitignore" <<'GI'
# — replicant savegame —
*.bak.*
*.bak
**/.cache/
**/Cache/
GI
  fi
}

# ensure_v3_layout: the v3 skeleton for a repo born here: the schema marker,
# an empty entry registry, and this machine's metadata. It never overwrites:
# schema.json and entries.json belong to the migration once written. It never
# creates legacy policy files: scopes live in entries.json, the profile lives
# in the machine record, and secrets live in the encrypted vault index.
ensure_v3_layout() {
  local rdir="$REPO_DIR/.replicant"
  mkdir -p "$rdir/machines" "$REPO_DIR/vault/blobs"
  if [[ ! -f "$rdir/schema.json" ]]; then
    jq -nc --argjson v "$SCHEMA_VERSION" --arg f "$SCHEMA_FORMAT" \
      '{dataVersion: $v, secretFormat: $f}' > "$rdir/schema.json"
  fi
  [[ -f "$rdir/entries.json" ]] || printf '{}\n' > "$rdir/entries.json"
  machine_metadata_write
}

# ensure_v2_layout: the version 2 skeleton. Only the migration path and the
# legacy parity suites use it: every fresh repo is born v3. It stays until
# migrate-v3 replaces the version 2 staging in phase G3.
ensure_v2_layout() {
  local rdir="$REPO_DIR/.replicant"
  mkdir -p "$rdir/machines" "$REPO_DIR/vault/blobs"
  if [[ ! -f "$rdir/schema.json" ]]; then
    jq -nc '{dataVersion: 2, secretFormat: "age-pq-v1"}' > "$rdir/schema.json"
  fi
  [[ -f "$rdir/entries.json" ]] || printf '{}\n' > "$rdir/entries.json"
  machine_metadata_write
}
