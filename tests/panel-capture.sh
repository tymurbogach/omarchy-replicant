#!/bin/bash
# Render the four review states into /tmp. The script never writes images to
# the repository and uses a throwaway data repository.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy" "$OMARCHY_PATH/config/hypr"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'local input\n' > "$HOME/.config/hypr/input.lua"
printf '{ "idle": { "screensaver": 300, "lock": 600 } }\n' > "$HOME/.config/omarchy/shell.json"
"$ROOT/bin/omarchy-replicant" init >/dev/null 2>&1
STATUS="$TMP/status.json"
"$ROOT/bin/omarchy-replicant" status --json --no-fetch > "$STATUS"

for state in overview configs manage settings; do
  out="/tmp/omarchy-replicant-panel-$state.png"
  case "$state" in
    overview) tab=overview; cards=; js= ;;
    configs) tab=configs; cards=; js= ;;
    manage) tab=configs; cards=; js= ;;
    settings) tab=settings; cards=; js= ;;
  esac
  # Opening the panel captures its default navigation snapshot. Clear that
  # snapshot before selecting the review state, or the scheduled restore can
  # put the capture back on Overview after the tab change.
  late="p.navigationSnapshot = null; p.navigationRestorePending = false; p.showTab('$tab'); if ('$state' === 'manage') { p.manageMode = true; p.selectVisible() }"
  STATUS="$STATUS" LATE_JS="$late" SHOT_W=720 SHOT_H=1100 \
    "$HERE/panel-shot.sh" "$out" "$tab" "$cards" "$js" >/dev/null
  test -s "$out"
  printf '%s\n' "$out"
done
