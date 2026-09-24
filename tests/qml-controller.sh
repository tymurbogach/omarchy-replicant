#!/bin/bash
# QML integration harness for the real controller.
# Verifies the ReplicantController.qml contract statically, then runs the QML
# test directory (pure logic plus controller queue semantics) with mock
# Omarchy modules first on the import path so container runs resolve.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
CONTROLLER="$ROOT/ReplicantController.qml"

failed=0
ok() { printf '  \x1b[32m\xe2\x9c\x93\x1b[0m %s\n' "$1"; }
bad() { printf '  \x1b[31m\xe2\x9c\x97\x1b[0m %s\n' "$1"; failed=$((failed+1)); }

[[ -f "$CONTROLLER" ]] && ok "real controller file exists" || { bad "ReplicantController.qml is missing"; exit 1; }
grep -q 'function run(' "$CONTROLLER" && ok "controller exposes run()" || bad "controller misses run()"
grep -q 'function cancel(' "$CONTROLLER" && ok "controller exposes cancel()" || bad "controller misses cancel()"
grep -q 'property var queue' "$CONTROLLER" && ok "controller owns one queue" || bad "controller misses queue"
grep -q 'signal completed' "$CONTROLLER" && ok "controller emits completed" || bad "controller misses completed signal"
grep -q 'Quickshell.Io' "$CONTROLLER" && ok "controller runs CLI processes" || bad "controller misses process backend"
if grep -q 'console\.log' "$CONTROLLER"; then bad "console.log left in controller"; else ok "no debug logging in controller"; fi
[[ -d "$HERE/qml/mock" ]] && ok "mock Omarchy modules exist" || bad "mock modules are missing"

QMLTEST="$(command -v qmltestrunner6 || true)"
[[ -z "$QMLTEST" && -x /usr/lib/qt6/bin/qmltestrunner ]] && QMLTEST=/usr/lib/qt6/bin/qmltestrunner
if [[ -z "$QMLTEST" ]]; then
  echo "qmltestrunner (Qt 6) is not installed, static checks only"
  (( failed == 0 )) && exit 0 || exit 1
fi
if out=$(env -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen "$QMLTEST" -import "$HERE/qml/mock" -input "$ROOT/tests/qml" 2>&1); then
  ok "$(grep -oE 'Totals: [0-9]+ passed, [0-9]+ failed' <<<"$out" || echo 'qml tests passed')"
else
  bad "qml tests failed"
  printf '%s\n' "$out" | grep -vE '^PASS|^QDEBUG' | sed 's/^/    /'
  exit 1
fi
