# shellcheck shell=bash disable=SC2034
# layout.sh: the repo layout and the pre-commit hook.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. Other modules read its data.

# The pre-commit hook of the data repo. It fails closed: if it cannot find the
# scanner, it blocks the commit. It used to exit 0 in that case, and the
# scanner is the last check between a token and GitHub.
precommit_hook_text() {
  cat <<'HOOK' | sed "s|@PLUGIN_DIR@|$PLUGIN_DIR|g"
#!/bin/bash
set -uo pipefail
REPO=$(git rev-parse --show-toplevel)
files=$(git diff --cached --name-only --diff-filter=ACM)
[[ -z $files ]] && exit 0
SCAN="@PLUGIN_DIR@/bin/scan-secrets.sh"
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
  # A repo with inventory flat in state/ has it moved under this machine's
  # name rather than leaving two shapes to support forever; git records the
  # move like any other change.
  # `mv -n` is not enough: it exits 0 and does NOTHING when the target already
  # exists, so a half-moved repo kept a stale flat copy of every inventory
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
  # format every writer after it must understand. The skeleton lands before
  # the scope and track ensures below, so those gates see the marker and a
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
    ensure_repository_layout
    # The tracked lists were built at source time, before this repo existed:
    # a fallback read then may have invented entries the canonical stores do
    # not hold. Rebuild them now, so the copy and prune passes below see the
    # version 3 records and never copy a file nothing tracks.
    load_user_manifest
    load_auto_manifest
    invalidate_scopes_cache
  else
    git -C "$REPO_DIR" config core.hooksPath .githooks 2>/dev/null || true
    require_ready_schema || return 1
    machine_metadata_write
  fi
  mkdir -p "$REPO_DIR/profiles/$(current_profile)/config" 2>/dev/null || true
  record_repo_version 2>/dev/null || true
  # The hook is kept in step with the plugin, like the scanner below. It was
  # written once, so a repo made by an old release kept that hook forever.
  mkdir -p "$GITHOOKS_DIR"
  if ! cmp -s <(precommit_hook_text) "$GITHOOKS_DIR/pre-commit" 2>/dev/null; then
    precommit_hook_text > "$GITHOOKS_DIR/pre-commit"
  fi
  chmod +x "$GITHOOKS_DIR/pre-commit"
  # .gitignore (state/ is generated, .bak.* ignored, secrets/ tracked)
  if [[ ! -f "$REPO_DIR/.gitignore" ]]; then
    cat >"$REPO_DIR/.gitignore" <<'GI'
# — replicant repo —
*.bak.*
*.bak
**/.cache/
**/Cache/
GI
  fi
}

# an empty entry registry, and this machine's metadata. It never overwrites:
# in the machine record, and secrets live in the encrypted vault index.
ensure_repository_layout() {
  local rdir="$REPO_DIR/.replicant"
  mkdir -p "$rdir/machines" "$REPO_DIR/vault/blobs"
  : > "$REPO_DIR/vault/blobs/.keep"
  if [[ ! -f "$rdir/schema.json" ]]; then
    printf '{"format":"replicant"}\n' > "$rdir/schema.json"
  fi
  [[ -f "$rdir/entries.json" ]] || printf '{}\n' > "$rdir/entries.json"
  machine_metadata_write
}
