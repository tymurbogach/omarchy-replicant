#!/bin/bash
# shellcheck disable=SC2034  # the paths set here are read by the modules in bin/lib/
# replicant-core.sh: the entry point of the plugin's logic. It sets the paths,
# loads the modules in bin/lib/, and runs the command it is given. The CLI
# runs it, or sources it for its functions. The logic is in bin/lib/.
set -euo pipefail

REAL_CORE="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(cd -- "$(dirname -- "$REAL_CORE")/.." && pwd)"
# plural and replicant_machine live in bin/lib/common.sh, shared with the CLI.
# shellcheck source=bin/lib/common.sh
source "$PLUGIN_DIR/bin/lib/common.sh" || { echo "replicant-core.sh: bin/lib/common.sh is missing" >&2; exit 1; }
# User's target repo (separate from the plugin's own code): private, savegame layout
REPLICANT_HOME="${OMARCHY_REPLICANT_HOME:-$HOME/.local/share/omarchy-replicant}"
REPO_DIR="$REPLICANT_HOME/repo"
CONFIG_DIR="$REPO_DIR/config"
SECRETS_DIR="$REPO_DIR/secrets"
# One repo, several machines. state/ is an inventory OF A MACHINE — its
# packages, its services, its plugins — so a shared state/ meant the desktop and
# the laptop overwrote each other's inventory on every save, and every pull
# looked like a change. Scoping it by hostname makes two machines additive
# instead of competing.
MACHINE="$(replicant_machine)"
STATE_ROOT="$REPO_DIR/state"
STATE_DIR="$STATE_ROOT/$MACHINE"

# Which tracked entries the last pull brought a newer copy of. Machine-local on
# purpose: it is a fact about what THIS machine has not caught up with yet, not
# about the setup, so it has no business travelling in the repo.
#
# It exists because "does the file on this machine differ from the copy in the
# repo" cannot tell you WHICH way the difference points, and the two answers ask
# for opposite buttons. Before this, pulling a change the laptop had made left
# the desktop showing the calm red "unsaved" badge — press Save and the laptop's
# work is quietly committed away. The direction is only knowable at the moment
# the commits arrive, so that is where it is written down.
INCOMING_FILE="$REPLICANT_HOME/incoming"

# Overridable so the tests can exercise the reader and the writer without a
# root-owned file; in normal use it is exactly where logind looks.
LOGIND_DROPIN="${REPLICANT_LOGIND_DROPIN:-/etc/systemd/logind.conf.d/99-lid.conf}"


TEMPLATES_DIR="$REPO_DIR/templates"
GITHOOKS_DIR="$REPO_DIR/.githooks"

# The logic lives in modules under bin/lib/. Each defines functions and data
# and runs nothing. The two calls after the loop load the tracked lists, so
# every module is defined before they run.
for _module in manifest categories scopes track suggest incoming backups tree layout gitstate discover settings status restore plugins; do
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/bin/lib/$_module.sh" || { echo "replicant-core.sh: bin/lib/$_module.sh is missing" >&2; exit 1; }
done
unset _module
load_user_manifest
load_auto_manifest

# The commands below run only when this file is executed. A caller that sources
# it for its functions passes its own positional parameters through, so without
# this line `omarchy-replicant path machine` ran the `machine` command first.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

# An unknown command is an error. The chain of ifs that this replaces did
# nothing for one and exited 0, which a caller reads as success.
case "${1:-}" in
  backup)             core_backup "${2:-}" ;;
  status)             shift; core_status "$@" ;;
  diff)               core_diff "${2:-}" "${3:-auto}" ;;
  log)                core_log "${2:-8}" ;;
  shortcuts)          core_shortcuts ;;
  sync)               core_sync "${2:-}" "${3:-}" ;;
  revert)             core_revert "${2:-}" "${3:-default}" ;;
  restore-file)       core_restore_file "${2:-}" ;;
  scope)              core_scope "${2:-}" "${3:-}" ;;
  profile-set)        core_profile_set "${2:-}" ;;
  profile-get)        current_profile ;;
  profile-list)       list_profiles ;;
  local-only-plugins) local_only_plugins ;;
  cloned-plugins)     cloned_plugins ;;
  edited-plugins)     edited_plugins ;;
  hypr-unresolved)    unresolved_hypr_modules ;;
  repo-path)          repo_copy_for_rel "${2:-}" ;;
  local-only-themes)  local_only_themes ;;
  track)              shift; core_track "$@" ;;
  untrack)            core_untrack "${2:-}" ;;
  suggest)            core_suggest "${2:-}" ;;
  incoming)           core_incoming "${2:-}" "${3:-}" ;;
  backups)            list_backups "${2:-}" ;;
  backups-json)       build_backups_json ;;
  undo)               core_undo "${2:-}" ;;
  machine)            printf '%s\n' "$MACHINE" ;;
  *)                  echo "replicant-core.sh: unknown command '${1:-}'" >&2; exit 2 ;;
esac
