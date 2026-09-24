#!/bin/bash
# Compare status latency against budgets or a stored baseline.
# The script never writes user state: the baseline defaults to the isolated
# XDG_STATE_HOME when set, otherwise to a temporary file that is removed.
# --check runs a deterministic measurement against an empty fixture and
# compares it to the fixed budgets. Baseline mode compares to a stored file.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
CLI="$ROOT/bin/omarchy-replicant"
RUNS="${REPLICANT_STATUS_RUNS:-5}"

FULL_BUDGET_MS=250
BRIEF_BUDGET_MS=100

usage() {
  cat <<'EOF'
usage: bench-status.sh [--check] [--help] [--runs N]
  --check   deterministic budget check: full <= 250 ms, brief <= 100 ms
  --help    print this text
  default   compare against the stored baseline (no user state is written)
EOF
}

CHECK=0
while (($# > 0)); do
  case "$1" in
    --check) CHECK=1; shift ;;
    --help) usage; exit 0 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "RUNS must be a positive integer" >&2; exit 2; }

resolve_baseline() {
  if [[ -n "${REPLICANT_STATUS_BASELINE:-}" ]]; then
    printf '%s' "$REPLICANT_STATUS_BASELINE"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s' "$XDG_STATE_HOME/omarchy-replicant/status-baseline.txt"
  else
    printf '%s' "${TMPDIR:-/tmp}/replicant-status-baseline.txt"
  fi
}

measure() {
  local mode="$1" sample total=0 i
  for ((i = 0; i < RUNS; i++)); do
    sample=$( { time -p "$CLI" status --json --no-fetch $mode >/dev/null; } 2>&1 | awk '$1 == "real" { print $2; exit }' )
    [[ "$sample" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid timing" >&2; exit 1; }
    total=$(awk -v a="$total" -v b="$sample" 'BEGIN { printf "%.6f", a + b }')
  done
  awk -v t="$total" -v n="$RUNS" 'BEGIN { printf "%.6f", t / n }'
}

ms_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a * 1000 > b) }'; }

measure_min() {
  # Minimum of several samples. The minimum filters scheduling jitter and
  # reflects the achievable latency of the fixture. Used by --check only.
  local mode="$1" sample best="" i
  for ((i = 0; i < 3; i++)); do
    sample=$( { time -p "$CLI" status --json --no-fetch $mode >/dev/null; } 2>&1 | awk '$1 == "real" { print $2; exit }' )
    [[ "$sample" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid timing" >&2; exit 1; }
    if [[ -z "$best" ]] || awk -v a="$sample" -v b="$best" 'BEGIN { exit !(a < b) }'; then best="$sample"; fi
  done
  printf '%s' "$best"
}

if (( CHECK )); then
  # Deterministic check against an empty isolated fixture. The fixture has no
  # tracked files, so the measurement reflects harness overhead only and stays
  # stable across machines. No baseline file is read or written.
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/replicant-bench-XXXXXX")"
  trap 'rm -rf "$FIXTURE"' EXIT
  export HOME="$FIXTURE/home"
  export XDG_CONFIG_HOME="$FIXTURE/config"
  export XDG_DATA_HOME="$FIXTURE/data"
  export XDG_STATE_HOME="$FIXTURE/state"
  export XDG_CACHE_HOME="$FIXTURE/cache"
  export OMARCHY_REPLICANT_HOME="$FIXTURE/replicant"
  export GIT_CONFIG_GLOBAL="$FIXTURE/gitconfig"
  mkdir -p "$HOME" "$XDG_STATE_HOME" "$OMARCHY_REPLICANT_HOME"
  printf '[user]\n\tname = Bench\n\temail = bench@example.com\n' > "$GIT_CONFIG_GLOBAL"
  json=$(measure_min "")
  brief=$(measure_min "--brief")
  echo "status.json ${json}s (budget 0.250s)"
  echo "status.brief ${brief}s (budget 0.100s)"
  failed=0
  if ms_gt "$json" "$FULL_BUDGET_MS"; then echo "status.json exceeds ${FULL_BUDGET_MS} ms budget" >&2; failed=1; fi
  if ms_gt "$brief" "$BRIEF_BUDGET_MS"; then echo "status.brief exceeds ${BRIEF_BUDGET_MS} ms budget" >&2; failed=1; fi
  exit "$failed"
fi

BASELINE="$(resolve_baseline)"
mkdir -p -- "$(dirname -- "$BASELINE")"

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
