#!/bin/bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
bash "$HERE/test-format.sh"
for file in "$ROOT"/bin/omarchy-replicant "$ROOT"/bin/*.sh "$ROOT"/bin/lib/*.sh; do bash -n "$file"; done
echo "All checks passed."
