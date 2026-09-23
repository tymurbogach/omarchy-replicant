#!/bin/bash
# Compare status latency with a numeric baseline outside the repository.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
CLI="$ROOT/bin/omarchy-replicant"
BASELINE="${REPLICANT_STATUS_BASELINE:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-replicant/status-baseline.txt}"
RUNS="${REPLICANT_STATUS_RUNS:-5}"

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "RUNS must be a positive integer" >&2; exit 2; }
mkdir -p -- "$(dirname -- "$BASELINE")"

measure() {
  local mode="$1" sample total=0 i
  for ((i = 0; i < RUNS; i++)); do
    sample=$( { time -p "$CLI" status --json --no-fetch $mode >/dev/null; } 2>&1 | awk '$1 == "real" { print $2; exit }' )
    [[ "$sample" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid timing" >&2; exit 1; }
    total=$(awk -v a="$total" -v b="$sample" 'BEGIN { printf "%.6f", a + b }')
  done
  awk -v t="$total" -v n="$RUNS" 'BEGIN { printf "%.6f", t / n }'
}

json=$(measure "")
brief=$(measure "--brief")
current="$json $brief"

if [[ ! -f "$BASELINE" ]]; then
  printf '%s\n' "$current" > "$BASELINE"
  echo "status benchmark baseline created at $BASELINE"
  exit 0
fi

read -r base_json base_brief < "$BASELINE"
[[ "$base_json" =~ ^[0-9]+([.][0-9]+)?$ && "$base_brief" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "baseline must contain two numeric values" >&2
  exit 1
}

awk -v name=status.json -v now="$json" -v base="$base_json" 'BEGIN {
  if (now > base * 1.10) { printf "%s regressed: %.6f > %.6f\n", name, now, base * 1.10; exit 1 }
  printf "%s %.6f (baseline %.6f)\n", name, now, base
}'
awk -v name=status.brief -v now="$brief" -v base="$base_brief" 'BEGIN {
  if (now > base * 1.10) { printf "%s regressed: %.6f > %.6f\n", name, now, base * 1.10; exit 1 }
  printf "%s %.6f (baseline %.6f)\n", name, now, base
}'
