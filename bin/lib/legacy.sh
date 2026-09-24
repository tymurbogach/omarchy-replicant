# shellcheck shell=bash disable=SC2034
# legacy.sh: the migration-only readers for version 1 and 2 repositories.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing. No writer imports it: versions 1 and 2
# are readable for inspection and migration, and only version 3 accepts
# writes. Anything here that a writer needs on v3 has a canonical twin in
# the owning module (entries in schema.sh, the vault index in crypto.sh,
# the machine record in schema.sh).

# What the pre-0.7 core tracked that is one person's rather than everyone's.
# Kept only so an existing repo does not silently stop tracking them the day it
# upgrades: ensure_track_file writes whichever of these the repo or the machine
# actually has into the user's own list, and load_user_manifest falls back to
# the same set for reads until that migration runs. Nothing here is offered to
# a fresh install. `~/Projects/mise.toml` is deliberately absent — it is a project
# file, not machine config, and is dropped rather than migrated.
LEGACY_PERSONAL=(
  "$HOME/.claude/hooks/cbm-code-discovery-gate:claude/hooks/cbm-code-discovery-gate"
  "$HOME/.claude/hooks/cbm-session-reminder:claude/hooks/cbm-session-reminder"
  "$HOME/.claude/hooks/cbm-subagent-reminder:claude/hooks/cbm-subagent-reminder"
  "$HOME/.config/uwsm/env.d/50-local-bin-priority.sh:uwsm/env.d/50-local-bin-priority.sh"
  "$HOME/.local/bin/hypr-refresh-auto:bin/hypr-refresh-auto"
  "$HOME/.local/bin/omarchy-audit:bin/omarchy-audit"
  "$HOME/.config/omarchy-audit-ignore:omarchy-audit-ignore"
  "$HOME/.config/omarchy/hooks/post-update.d/audit-config.hook:omarchy/hooks/post-update.d/audit-config.hook"
  "/etc/systemd/system/fprintd-resume.service:etc/fprintd-resume.service"
)
LEGACY_PERSONAL_SECRETS=(
  "$HOME/Projects/portfolio/.env:env/portfolio.env"
  "$HOME/Projects/lazytripz/backend/.env:env/lazytrip-backend.env"
)

# A pre-0.7 entry counts as this user's only if the repo already holds a copy or
# the machine still has the file. Deliberately blunt about where the copy might
# be: this runs before scope_for is defined, so it looks under both roots rather
# than asking repo_path_for which one applies.
legacy_personal_present() {
  local src="${1%%:*}" rel="${1##*:}" p
  [[ -e "$src" ]] && return 0
  [[ -e "$CONFIG_DIR/$rel" ]] && return 0
  for p in "$REPO_DIR"/profiles/*/config/"$rel"; do [[ -e "$p" ]] && return 0; done
  return 1
}

# legacy_user_entries: the fallback user list for repos without
# .replicant-track, one "src:rel" per line for configs and one for secrets.
# load_user_manifest reads this until the migration writes the real file.
legacy_user_entries() {
  local entry
  for entry in "${LEGACY_PERSONAL[@]}"; do
    legacy_personal_present "$entry" && printf 'config\t%s\t%s\n' "${entry%%:*}" "${entry##*:}"
  done
  for entry in "${LEGACY_PERSONAL_SECRETS[@]}"; do
    [[ -f "${entry%%:*}" || -f "$SECRETS_DIR/${entry##*:}" ]] &&
      printf 'secret\t%s\t%s\n' "${entry%%:*}" "${entry##*:}"
  done
  return 0
}

# legacy_read_profile_map: the version 1 and 2 machine-to-profile assignments,
# one "<machine> = <profile>" per line without comments or blanks.
legacy_read_profile_map() {
  [[ -f "$PROFILE_FILE" ]] || return 0
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$PROFILE_FILE" 2>/dev/null || true
}

# legacy_profile_for_machine <machine>: the recorded profile, or nothing.
legacy_profile_for_machine() {
  local want="$1" line k v
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ "$k" == "$want" ]] && { printf '%s\n' "$v"; return 0; }
  done < <(legacy_read_profile_map)
  return 1
}

# legacy_exclude_map: the version 0.5 flat off-list, one path per line.
legacy_exclude_map() {
  [[ -f "$LEGACY_EXCLUDE_FILE" ]] || return 0
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$LEGACY_EXCLUDE_FILE" 2>/dev/null || true
}

# legacy_migrate_exclude: translate the flat off-list into seed lines for the
# scope file. Returns 1 when there is nothing to migrate.
legacy_migrate_exclude() {
  [[ -f "$LEGACY_EXCLUDE_FILE" ]] || return 1
  local ln migrated=0
  while IFS= read -r ln; do
    ln="${ln//[[:space:]]/}"
    [[ -n "$ln" ]] && { printf '%s = off\n' "$ln"; migrated=1; }
  done < <(legacy_exclude_map)
  (( migrated )) || return 1
  rm -f -- "$LEGACY_EXCLUDE_FILE"
  return 0
}
