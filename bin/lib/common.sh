# shellcheck shell=bash
# common.sh: what the CLI and the core both need, defined once. Both source it.
# It holds functions only, and runs nothing when it is sourced.

# plural <n> <singular> [plural]: "1 file", "4 files". Every count this tool
# printed used to read "4 file(s)", and the parenthesis never said anything that
# the number did not.
plural() {
  local n="$1" one="$2" many="${3:-$2s}"
  if [[ "$n" == 1 ]]; then printf '%s %s\n' "$n" "$one"; else printf '%s %s\n' "$n" "$many"; fi
}

# replicant_machine: the name of this machine, as the repo records it under
# state/<machine>/. REPLICANT_MACHINE overrides it for the tests. The CLI used
# `hostname -s` for the same idea, so the two could disagree.
replicant_machine() {
  printf '%s\n' "${REPLICANT_MACHINE:-$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
}
