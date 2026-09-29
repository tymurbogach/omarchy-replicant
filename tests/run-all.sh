#!/bin/bash
# Full release gate: static checks, every shell suite, QML, bench budgets,
# phase gates G0-G8, plugin validation and QML lint.
# Suites with their own gate run inside that gate; suites without one run here
# directly, so every suite runs at least once and none runs silently never.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "static: format"
bash "$HERE/test-format.sh"

section "static: syntax"
for file in "$ROOT"/bin/omarchy-replicant "$ROOT"/bin/*.sh "$ROOT"/bin/lib/*.sh; do
  bash -n "$file"
done

section "static: secret scan"
bash "$ROOT/bin/scan-secrets.sh" "$ROOT/bin" "$ROOT/tests" "$ROOT"/*.qml "$ROOT/components" "$ROOT/replicant.js" "$ROOT/docs" "$ROOT/README.md"

section "static: coverage manifest"
bash "$HERE/coverage-check.sh"

section "static: version bump"
bash "$HERE/check-version-bump.sh"

section "suites without a phase gate"
for suite in test-cli test-core test-journey test-modules test-interruptions test-usability; do
  echo "--- $suite ---"
  bash "$HERE/$suite.sh"
done

section "phase gates G0-G8 (run the remaining suites)"
for gate in G0 G1 G2 G3 G4 G5 G6 G7 G8; do
  bash "$HERE/gate.sh" "$gate"
done

section "bench budgets"
bash "$HERE/bench-status.sh" --check

section "plugin"
omarchy plugin validate "$ROOT"
qml_lint=$(command -v qmllint-qt6 || command -v qmllint)
"$qml_lint" -I /usr/share/omarchy/shell "$ROOT"/*.qml "$ROOT"/components/*.qml
echo "All checks passed."
