#!/bin/bash
# Shared harness for the test scripts.
#
# Every suite runs against a throwaway $HOME and a throwaway repo under
# $OMARCHY_REPLICANT_HOME, so nothing here can touch the real ~/.config or the
# user's own backup repo. That is not a nicety: these tests exercise the code
# paths that overwrite config files and push commits.
#
# The reporters are named t_* on purpose. replicant-core.sh defines its own
# ok() / skip() / run(), and sourcing it silently replaced the test reporters
# once — the suite then reported "0 checks" while appearing to pass.

pass=0; fail=0
t_ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
t_bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_bad "$1 — expected '$2', got '$3'"; fi
}

# check_contains <description> <needle> <haystack>
check_contains() {
  if [[ "$3" == *"$2"* ]]; then t_ok "$1"; else t_bad "$1 — '$2' not found in output"; fi
}

# check_true <description> <command...>  — passes when the command succeeds
check_true() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then t_ok "$desc"; else t_bad "$desc — command failed: $*"; fi
}

# check_false <description> <command...> — passes when the command FAILS. Used
# for every "it must refuse this" case, which is most of the value here.
check_false() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then t_bad "$desc — command unexpectedly succeeded: $*"; else t_ok "$desc"; fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

summary() {
  echo
  if (( fail == 0 )); then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$pass"; exit 0
  else
    printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1
  fi
}

# hash_tree <dir> — content fingerprint of a directory, for proving that a
# dry-run really changed nothing.
hash_tree() {
  find "$1" -type f -not -path '*/.git/*' -print0 2>/dev/null |
    sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}
