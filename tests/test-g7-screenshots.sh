#!/bin/bash
# Render stable G7 panel states offscreen and compare them with reviewed PNGs.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/g7"
GOLDEN="$FIXTURES/screens"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
THEME="${OMARCHY_TEST_THEME:-/usr/share/omarchy/themes/tokyo-night}"
if [[ ! -f "$THEME/colors.toml" ]]; then
  echo "test-g7-screenshots: deterministic Tokyo Night theme is required at $THEME" >&2
  exit 2
fi
mkdir -p "$TMP/home/.local/state/omarchy/current" "$TMP/config" "$TMP/data" "$TMP/state" "$TMP/cache"
ln -s "$THEME" "$TMP/home/.local/state/omarchy/current/theme"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data"
export XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache"
pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

if ! command -v quickshell >/dev/null 2>&1 || ! command -v compare >/dev/null 2>&1 \
    || [[ ! -d "${OMARCHY_SHELL:-/usr/share/omarchy/shell}/Ui" ]]; then
  echo "test-g7-screenshots: quickshell, ImageMagick and Omarchy shell are required" >&2
  exit 2
fi

render() {
  local name="$1" status="$2" tab="$3" cards="$4" js="$5"
  SHOT_STATIC=1 STATUS="$status" SHOT_W=720 SHOT_H=1100 \
    "$HERE/panel-shot.sh" "$TMP/$name.png" "$tab" "$cards" "$js" >/dev/null
}

compare_fixture() {
  local name="$1" metric
  metric="$TMP/$name.metric"
  if [[ ! -f "$GOLDEN/$name.png" ]]; then
    bad "$name has no visual fixture"
    return
  fi
  if compare -metric AE "$GOLDEN/$name.png" "$TMP/$name.png" null: 2>"$metric"; then
    if [[ "$(<"$metric")" == 0* ]]; then ok "$name matches its visual fixture"; else bad "$name differs by $(<"$metric") pixels"; fi
  else
    bad "$name differs from its visual fixture"
  fi
}

render overview "$FIXTURES/status.json" overview "" ""
compare_fixture overview

render loading "$FIXTURES/empty.json" overview "" \
  'p.asked = false; p.repoState = { initialized: false, configs: [], secrets: [], categories: [], settings: [], setting_groups: [], machines: [] }'
compare_fixture loading

render empty "$FIXTURES/empty.json" overview "" ""
compare_fixture empty

render conflict "$FIXTURES/conflict.json" overview "" ""
compare_fixture conflict

render locked "$FIXTURES/status.json" configs secrets ""
compare_fixture locked

render local-only "$FIXTURES/status.json" overview "" \
  'p.lastTitle = "Saved locally"; p.lastOk = true; p.lastCancelled = false; p.lastOutput = "Saved locally, but the push failed.\nRetry: omarchy-replicant push"'
compare_fixture local-only

render failure "$FIXTURES/status.json" overview "" \
  'p.lastTitle = "Save"; p.lastOk = false; p.lastCancelled = false; p.lastOutput = "Save failed (exit 1)\nRemote rejected the push"'
compare_fixture failure

render cancelled "$FIXTURES/status.json" overview "" \
  'p.lastTitle = "Cancelled"; p.lastOk = true; p.lastCancelled = true; p.lastOutput = "Cancelled before the commit"'
compare_fixture cancelled

echo
if (( fail == 0 )); then printf '\033[32mAll %d screenshot checks passed.\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d of %d screenshot checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1; fi
