#!/bin/bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
bash "$HERE/test-format.sh"
for file in "$ROOT"/bin/omarchy-replicant "$ROOT"/bin/*.sh "$ROOT"/bin/lib/*.sh; do
  bash -n "$file"
done
bash "$ROOT/bin/scan-secrets.sh" "$ROOT/bin" "$ROOT/tests" "$ROOT"/*.qml "$ROOT/components" "$ROOT/replicant.js" "$ROOT/docs" "$ROOT/README.md"
omarchy plugin validate "$ROOT"
qml_lint=$(command -v qmllint-qt6 || command -v qmllint)
"$qml_lint" -I /usr/share/omarchy/shell "$ROOT"/*.qml "$ROOT"/components/*.qml
echo "All checks passed."
