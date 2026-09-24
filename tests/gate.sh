#!/bin/bash
# Canonical phase runner for the Replicant v3 plan.
# Usage: ./tests/gate.sh G0|G1|G2|G3|G4|G5|G6|G7|G8
# Every gate runs inside an isolated HOME and XDG environment with local bare
# Git remotes, stubbed externals, and no network access. Each gate asserts
# repository cleanliness and temporary file removal.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
PHASE="${1:-}"

case "$PHASE" in
  G0|G1|G2|G3|G4|G5|G6|G7|G8) ;;
  *) echo "usage: $(basename "$0") G0..G8" >&2; exit 2 ;;
esac

pass=0; fail=0
ok() { printf '  \x1b[32m\xe2\x9c\x93\x1b[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \x1b[31m\xe2\x9c\x97\x1b[0m %s\n' "$1"; fail=$((fail+1)); }
section() { printf '\n\x1b[1m%s\x1b[0m\n' "$1"; }

# Isolated environment. Every gate gets a fresh HOME, XDG dirs, and a private
# state dir. Nothing in a gate may write to the real user state.
GATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/replicant-gate-XXXXXX")"
export HOME="$GATE_TMP/home"
export XDG_CONFIG_HOME="$GATE_TMP/config"
export XDG_DATA_HOME="$GATE_TMP/data"
export XDG_STATE_HOME="$GATE_TMP/state"
export XDG_CACHE_HOME="$GATE_TMP/cache"
export OMARCHY_REPLICANT_HOME="$GATE_TMP/replicant"
export GIT_CONFIG_GLOBAL="$GATE_TMP/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$OMARCHY_REPLICANT_HOME"
printf '[user]\n\tname = Gate\n\temail = gate@example.com\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

# Local bare remotes stand in for GitHub. Tests must use these, never the network.
export REPLICANT_GATE_REMOTE="$GATE_TMP/remote.git"
git init --bare -q "$REPLICANT_GATE_REMOTE"

# Reject unexpected network access. Real network tools fail inside gates.
# Suites that need one provide their own fixture first on PATH.
GATE_STUB_DIR="$GATE_TMP/stubbin"
mkdir -p "$GATE_STUB_DIR"
GATE_STUB_LOG="$GATE_STUB_DIR/calls.log"
for tool in curl wget ssh gh; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\necho "gate: network access blocked: %s" >&2\nexit 97\n' "$tool" "$GATE_STUB_LOG" "$tool" > "$GATE_STUB_DIR/$tool"
  chmod +x "$GATE_STUB_DIR/$tool"
done
# Editors, privilege tools, and session tools always fail. A gate that needs
# one writes its own stub and puts it first on PATH.
for tool in sudo pkexec systemctl hyprctl omarchy xdg-open notify-send omarchy-theme-set omarchy-restart-shell omarchy-launch-editor omarchy-launch-floating-terminal-with-presentation vim nvim nano code; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 97\n' "$tool" "$GATE_STUB_LOG" > "$GATE_STUB_DIR/$tool"
  chmod +x "$GATE_STUB_DIR/$tool"
done
export PATH="$GATE_STUB_DIR:$PATH"
export REPLICANT_CATALOG_URL="file:///nonexistent/replicant-gate-catalog.json"
export GIT_PROXY_COMMAND="false"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy || true

cleanup_gate() { rm -rf "$GATE_TMP"; }
trap cleanup_gate EXIT

assert_clean_repo() {
  # A gate must not leave whitespace errors or stray artifacts behind. The
  # plugin checkout is dirty during phase work by design, so this checks the
  # gate's own hygiene, not a clean tree.
  if git -C "$ROOT" diff --check >/dev/null 2>&1; then
    ok "no whitespace errors in the working tree"
  else
    bad "whitespace errors present"; git -C "$ROOT" diff --check >&2 || true
  fi
  if [[ -z "$(git -C "$ROOT" status --porcelain | grep -E '\.log$|\.tmp$|baseline\.txt$' || true)" ]]; then
    ok "no stray test artifacts in the working tree"
  else
    bad "stray test artifacts remain"
    git -C "$ROOT" status --porcelain | grep -E '\.log$|\.tmp$|baseline\.txt$' >&2 || true
  fi
}

assert_no_gate_tmp_left() {
  local left
  left="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'replicant-gate-*' -newer "$GIT_CONFIG_GLOBAL" 2>/dev/null | grep -v "^$GATE_TMP$" || true)"
  if [[ -z "$left" ]]; then
    ok "no stray gate temp dirs left behind"
  else
    bad "stray gate temp dirs remain: $left"
  fi
}

gate_g0() {
  section "G0 isolated environment"
  [[ "$HOME" == "$GATE_TMP/home" ]] && ok "HOME is isolated" || bad "HOME is not isolated"
  [[ "$XDG_STATE_HOME" == "$GATE_TMP/state" ]] && ok "XDG_STATE_HOME is isolated" || bad "XDG_STATE_HOME is not isolated"
  [[ -d "$REPLICANT_GATE_REMOTE" ]] && ok "local bare remote exists" || bad "local bare remote is missing"
  if curl https://example.com >/dev/null 2>&1; then bad "network curl was not blocked"; else ok "network access is rejected"; fi
  if gh auth status >/dev/null 2>&1; then bad "gh stub was not blocking"; else ok "gh is stubbed"; fi
  if sudo true >/dev/null 2>&1; then bad "sudo stub was not blocking"; else ok "privilege tools are stubbed"; fi

  section "G0 benchmark harness"
  [[ -x "$HERE/bench-status.sh" ]] && ok "bench-status.sh is present" || bad "bench-status.sh is missing"
  if "$HERE/bench-status.sh" --help 2>&1 | grep -q -- "--check"; then ok "bench --check mode exists"; else bad "bench --check mode is missing"; fi
  if grep -q 'FULL_BUDGET_MS=250' "$HERE/bench-status.sh" && grep -q 'BRIEF_BUDGET_MS=100' "$HERE/bench-status.sh"; then
    ok "status budgets are 250 ms full and 100 ms brief"
  else
    bad "status budgets are not 250 ms full and 100 ms brief"
  fi
  if grep -q 'XDG_STATE_HOME' "$HERE/bench-status.sh" && ! grep -qE 'HOME/\.local/state' "$HERE/bench-status.sh"; then
    ok "bench never hardcodes user state paths"
  else
    bad "bench still references hardcoded user state"
  fi

  section "G0 command coverage manifest"
  [[ -f "$HERE/coverage.json" ]] && ok "coverage.json exists" || bad "coverage.json is missing"
  if [[ -f "$HERE/coverage.json" ]]; then
    if jq empty "$HERE/coverage.json" >/dev/null 2>&1; then ok "coverage.json is valid JSON"; else bad "coverage.json is not valid JSON"; fi
    missing="$("$HERE/coverage-check.sh" --list-missing 2>/dev/null || true)"
    if [[ -z "$missing" ]]; then
      ok "every public command is mapped to tests"
    else
      bad "unmapped public commands:$missing"
      printf '%s\n' "$missing" >&2
    fi
  fi

  section "G0 QML integration harness"
  [[ -x "$HERE/qml-controller.sh" ]] && ok "qml-controller.sh exists" || bad "qml-controller.sh is missing"
  [[ -f "$HERE/qml/tst_controller.qml" ]] && ok "tst_controller.qml exists" || bad "tst_controller.qml is missing"
  [[ -d "$HERE/qml/mock" ]] && ok "mock Omarchy QML modules exist" || bad "mock Omarchy QML modules are missing"
  if [[ -x "$HERE/qml-controller.sh" ]]; then
    if "$HERE/qml-controller.sh" >/dev/null 2>&1; then ok "QML controller harness passes"; else bad "QML controller harness fails"; fi
  fi

  section "G0 container dependencies"
  for dep in git jq shellcheck diffutils which age; do
    grep -q "$dep" "$HERE/Dockerfile" && ok "Dockerfile lists $dep" || bad "Dockerfile misses $dep"
  done
  grep -q 'qt6-declarative' "$HERE/Dockerfile" && ok "Dockerfile lists qt6-declarative" || bad "Dockerfile misses qt6-declarative"
}

gate_g1() {
  section "G1 v3 schema gate"
  "$HERE/coverage-check.sh" >/dev/null 2>&1 && ok "coverage manifest is complete" || bad "coverage manifest is incomplete"
  if grep -q 'SCHEMA_VERSION=3' "$ROOT/bin/lib/schema.sh" 2>/dev/null; then ok "v3 schema is canonical"; else bad "v3 schema is not canonical (expected after G1)"; fi
  if grep -q 'schema_version:$schema_version' "$ROOT/bin/lib/status.sh" 2>/dev/null; then ok "status payload follows the schema version"; else bad "status payload hardcodes a schema version"; fi
  grep -q 'SCHEMA_FORMAT="age-pq-v2"' "$ROOT/bin/lib/schema.sh" 2>/dev/null && ok "secret format is age-pq-v2" || bad "secret format is not age-pq-v2"
  [[ -f "$ROOT/bin/lib/legacy.sh" ]] && ok "legacy readers live in the migration-only module" || bad "bin/lib/legacy.sh is missing"
  if "$HERE/test-v3schema.sh" >/dev/null 2>&1; then ok "v3 schema suite passes"; else bad "v3 schema suite fails"; fi
  if "$HERE/test-schema.sh" >/dev/null 2>&1; then ok "legacy schema suite still passes"; else bad "legacy schema suite fails"; fi
}

gate_g2() { section "G2 bootstrap gate"; bad "G2 is not implemented yet"; }
gate_g3() { section "G3 migration gate"; bad "G3 is not implemented yet"; }
gate_g4() { section "G4 transaction gate"; bad "G4 is not implemented yet"; }
gate_g5() { section "G5 status gate"; bad "G5 is not implemented yet"; }
gate_g6() { section "G6 secret restore gate"; bad "G6 is not implemented yet"; }
gate_g7() { section "G7 controller gate"; bad "G7 is not implemented yet"; }
gate_g8() { section "G8 release gate"; bad "G8 is not implemented yet"; }

"gate_$(echo "$PHASE" | tr '[:upper:]' '[:lower:]')"

section "gate cleanliness"
assert_clean_repo
assert_no_gate_tmp_left

echo
if (( fail == 0 )); then printf '\x1b[32mGate %s passed (%d checks).\x1b[0m\n' "$PHASE" "$pass"; exit 0
else printf '\x1b[31mGate %s failed: %d of %d checks failed.\x1b[0m\n' "$PHASE" "$fail" "$((pass+fail))"; exit 1; fi
