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
# Each entry is a shape a real credential has and ordinary config does not.
# Anything vaguer than that belongs in the user's own review, not in a hook that
# blocks commits: a scanner that cries wolf gets disabled, and then it is not a
# scanner at all.
PATTERNS=(
  'ghp_[A-Za-z0-9]{36}:classic GitHub token'
  'gh[opsu]_[A-Za-z0-9]{36}:GitHub OAuth/app/refresh token'
  'github_pat_[A-Za-z0-9_]{22,}:GitHub fine-grained token'
  'glpat-[A-Za-z0-9_-]{20,}:GitLab personal access token'
  'AIza[0-9A-Za-z_-]{35}:Google API key'
  'GOCSPX-[A-Za-z0-9_-]{20,}:Google OAuth client secret'
  'sk-ant-[A-Za-z0-9_-]{20,}:Anthropic API key'
  # The AI CLIs on a machine like this keep keys in ordinary JSON config, which
  # is exactly the kind of file that gets tracked without a second thought.
  'sk-proj-[A-Za-z0-9_-]{20,}:OpenAI project key'
  'sk-or-v1-[a-f0-9]{32,}:OpenRouter key'
  'sk-[A-Za-z0-9]{32,}:OpenAI-style API key'
  'xai-[A-Za-z0-9]{20,}:xAI key'
  'hf_[A-Za-z0-9]{30,}:Hugging Face token'
  'npm_[A-Za-z0-9]{36}:npm token'
  'xox[baprse]-[A-Za-z0-9-]{10,}:Slack token'
  '[srp]k_live_[A-Za-z0-9]{20,}:Stripe live key'
  'AKIA[0-9A-Z]{16}:AWS access key id'
  'BEGIN [A-Z ]*PRIVATE KEY:private key'
  'APP_KEY=base64:[A-Za-z0-9+/=]{40,}:Laravel APP_KEY'
  '^[[:space:]]*password[[:space:]]*=[[:space:]]*[^<[:space:]].*:plaintext password'
  'aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{20,}:AWS secret'
  'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}:JSON Web Token'
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
