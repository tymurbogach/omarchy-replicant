#!/bin/bash
# The one place where credential patterns live. Used by .githooks/pre-commit
# (over the content staged for commit) and by core_backup() (over what was just
# copied from the system). Previously each had its own list and they'd drifted.
#
#   bin/scan-secrets.sh config state        scans paths
#   ... | bin/scan-secrets.sh --stdin PATH  scans stdin, labeled as PATH
#
# Exits 1 if it finds anything. secrets/ is never scanned: real credentials go
# there by design.

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
  'AGE-SECRET-KEY-1[A-Z0-9]{20,}:age secret identity'
  'AGE-SECRET-KEY-PQ-1[A-Z0-9]{20,}:post-quantum age secret identity'
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
  # Do not print a matched line. Scanner output often reaches the panel, logs,
  # and support reports, where the credential must never appear. Two shapes:
  # path scans print `file:line:content`, stdin scans print `line:content` —
  # the second shape used to fall through unredacted and leak the credential.
  printf '%s\n' "$hits" | sed -E -e 's/^([^:]+):([0-9]+):.*/    \1:\2: match redacted/' \
    -e 's/^([0-9]+):.*/    \1: match redacted/'
  fail=1
}

# One pass over the input for every pattern, then attribution per pattern.
# Twenty-five tree walks per save became one: the walk, not the matching, was
# the cost. A line matching two patterns reports under both, exactly as the
# per-pattern loops did. Lines no pattern claims (binary "matches" notices)
# report once under their own header instead of once per pattern.
combined=""
for entry in "${PATTERNS[@]}"; do
  if [[ -z "$combined" ]]; then combined="(${entry%:*})"; else combined="$combined|(${entry%:*})"; fi
done

classify_and_report() {
  local label="$1" hits="$2" entry h rest
  [[ -n "$hits" ]] || return 0
  for entry in "${PATTERNS[@]}"; do
    h=$(grep -E "${entry%:*}" <<<"$hits" || true)
    [[ -n "$h" ]] || continue
    if [[ -n "$label" ]]; then report "$label — ${entry##*:}" "$h"; else report "${entry##*:}" "$h"; fi
  done
  rest="$hits"
  for entry in "${PATTERNS[@]}"; do
    rest=$(grep -vE "${entry%:*}" <<<"$rest" || true)
  done
  [[ -z "$rest" ]] && return 0
  if [[ -n "$label" ]]; then report "$label — binary content matched" "$rest"
  else report "binary content matched" "$rest"; fi
}

if [[ ${1:-} == --stdin ]]; then
  label=${2:-input}
  # Through a file, not a variable. The pre-commit hook feeds every staged file
  # in, and once a plugin's compiled shader and its PNG were tracked those
  # arrived as binary — bash cannot hold a NUL in a variable and printed
  # "warning: command substitution: ignored null byte in input" on every commit.
  # A binary is also not what this looks for: every pattern here is a text
  # token, so grep -I skips them and says so instead of half-reading them.
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  cat > "$tmp"

  hits=$(grep -InE "$combined" "$tmp" | grep -vE "$PLACEHOLDER") || true
  classify_and_report "$label" "$hits"
else
  (( $# )) || { echo "usage: $0 PATH... | $0 --stdin PATH" >&2; exit 2; }

  hits=$(grep -rInE --exclude-dir=.git --exclude-dir=secrets "$combined" "$@" 2>/dev/null \
    | grep -vE "$PLACEHOLDER") || true
  classify_and_report "" "$hits"
fi

exit $fail
