#!/bin/bash
# The one place where credential patterns live. Used by .githooks/pre-commit
# (over the content staged for commit) and by core_backup() (over what was just
# copied from the system). Previously each had its own list and they'd drifted.
#
#   bin/scan-secrets.sh config state        scans paths
#   ... | bin/scan-secrets.sh --stdin PATH  scans stdin, labeled as PATH
#
# Exits 1 if it finds anything. secrets/ is never scanned: real credentials go
# there by explicit design (CLAUDE.md § Rule 0).

set -uo pipefail

# Markers that mean "this is a placeholder, not a real secret".
PLACEHOLDER='<[^>]+>|REDACTED|EXAMPLE|SAMPLE|xxxxx|\.\.\.|PUT_HERE|YOUR_'

# pattern:description
PATTERNS=(
  'ghp_[A-Za-z0-9]{36}:classic GitHub token'
  'github_pat_[A-Za-z0-9_]{22,}:GitHub fine-grained token'
  'AIza[0-9A-Za-z_-]{35}:Google API key'
  'GOCSPX-[A-Za-z0-9_-]{20,}:Google OAuth client secret'
  'sk-ant-[A-Za-z0-9_-]{20,}:Anthropic API key'
  'BEGIN [A-Z ]*PRIVATE KEY:private key'
  'APP_KEY=base64:[A-Za-z0-9+/=]{40,}:Laravel APP_KEY'
  '^[[:space:]]*password[[:space:]]*=[[:space:]]*[^<[:space:]].*:plaintext password'
  'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{20,}:AWS secret'
)

fail=0

# Prints a pattern's hits and marks the failure. The header carries where it came
# from: in --stdin mode that's the given label; when scanning paths, each grep
# line already carries its own path.
report() {
  local header=$1 hits=$2
  [[ -n $hits ]] || return 0
  echo "✗ $header"
  printf '%s\n' "$hits" | sed 's/^/    /'
  fail=1
}

if [[ ${1:-} == --stdin ]]; then
  label=${2:-input}
  content=$(cat)

  for entry in "${PATTERNS[@]}"; do
    hits=$(printf '%s\n' "$content" | grep -nE "${entry%:*}" | grep -vE "$PLACEHOLDER") || true
    report "$label — ${entry##*:}" "$hits"
  done
else
  (( $# )) || { echo "usage: $0 PATH... | $0 --stdin PATH" >&2; exit 2; }

  for entry in "${PATTERNS[@]}"; do
    hits=$(grep -rnE --exclude-dir=.git --exclude-dir=secrets "${entry%:*}" "$@" 2>/dev/null \
      | grep -vE "$PLACEHOLDER") || true
    report "${entry##*:}" "$hits"
  done
fi

exit $fail
