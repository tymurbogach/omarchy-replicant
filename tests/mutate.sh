#!/bin/bash
# Mutation testing. Each mutation breaks one line of production code in a copy
# of the repo and runs the suite that must notice. A mutation that survives is
# a check that passes whether or not the code works: a coverage hole with a name.
#
#   tests/mutate.sh        run every mutation, four at a time
#   tests/mutate.sh 3      run only the third
#
# The mutations are data, below. `from` must occur exactly once in `file`, or
# the mutation is reported as stale: a mutation that no longer applies proves
# nothing, and it must fail loudly rather than pass.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
JOBS="${MUTATE_JOBS:-4}"
ONLY="${1:-}"

# file, suite, from, to, why. One record per block, blocks separated by "---".
MUTATIONS=$(cat <<'DATA'
file: bin/replicant-core.sh
suite: test-core.sh
from: is_excluded "$(owning_rel "$candrel")" && continue
to: :
why: the prune pass keeps the copy of a file that is switched off
---
file: bin/replicant-core.sh
suite: test-core.sh
from: version_lt "$running" "$seen" && return 1
to: :
why: an older client does not prune what a newer one tracks
---
file: bin/replicant-core.sh
suite: test-core.sh
from: $NF == "block" {
to: $NF == "never" {
why: a block inhibitor on the lid switch is named
---
file: bin/replicant-core.sh
suite: test-core.sh
from: if [[ "$n" == 1 ]]; then printf '%s %s\n' "$n" "$one"; else printf '%s %s\n' "$n" "$many"; fi
to: printf '%s %s\n' "$n" "$many"
why: counts read as English
---
file: bin/replicant-core.sh
suite: test-core.sh
from: upstream_tree_matches "$pdir" && continue
to: :
why: a plugin whose files match upstream is not called edited
---
file: bin/replicant-core.sh
suite: test-core.sh
from: if [[ ! -x "$SCAN" ]]; then
to: if false; then
why: the pre-commit hook blocks a commit when the scanner is missing
---
file: bin/replicant-core.sh
suite: test-core.sh
from: scan_dirs+=("$REPO_DIR/profiles/$(current_profile)/config")
to: :
why: the backup scans the profile tree for secrets
---
file: bin/replicant-core.sh
suite: test-core.sh
from: is_secret_rel "$1" && { echo 600; return; }
to: :
why: a secret the user tracked is restored at mode 600
---
file: bin/replicant-core.sh
suite: test-settings.sh
from:   # Always a failure. This read `return "${rc:-1}"` with rc starting at 0, so
to:   return 0 #
why: a root-owned write that did not happen is a failure
---
file: bin/replicant-core.sh
suite: test-settings.sh
from: | grep -Fxf "$SETTING_BACKUPS_FILE"
to:
why: setting edits prune only the backups they made
---
file: bin/replicant-core.sh
suite: test-cli.sh
from: [[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
to: :
why: the core's dispatcher runs only when the core is executed
---
file: bin/omarchy-replicant
suite: test-cli.sh
from: fail "unknown area: $ONLY (areas: ${CATEGORY_ORDER[*]})"
to: :
why: restore refuses an unknown area
---
file: bin/omarchy-replicant
suite: test-journey.sh
from:     PUSH_STATE=failed
to:     PUSH_STATE=ok
why: savegame reports a push that failed
---
file: bin/replicant-core.sh
suite: test-journey.sh
from: if [[ -n "${INCOMING[$rel]:-}" ]] && entry_differs
to: if false && entry_differs
why: saving everything holds back a file another machine changed
---
file: bin/replicant-core.sh
suite: test-settings.sh
from: in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
to: $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
why: toml_set writes the key only inside its own section
DATA
)

# apply <copy> <file> <from> <to>: replace the one occurrence, or fail.
apply() {
  local copy="$1" file="$2" from="$3" to="$4" n
  n=$(grep -cF -- "$from" "$copy/$file" || true)
  [[ "$n" == 1 ]] || return 3
  FROM="$from" TO="$to" awk '
    BEGIN { f = ENVIRON["FROM"]; t = ENVIRON["TO"] }
    { i = index($0, f); if (i && !done) { $0 = substr($0, 1, i - 1) t substr($0, i + length(f)); done = 1 } print }
  ' "$copy/$file" > "$copy/$file.mutated" && mv "$copy/$file.mutated" "$copy/$file"
  chmod +x "$copy/$file"
}

# run_one <number> <file> <suite> <from> <to> <why>: one line of verdict.
run_one() {
  local num="$1" file="$2" suite="$3" from="$4" to="$5" why="$6" copy rc
  copy=$(mktemp -d)
  cp -a "$ROOT/." "$copy/"
  if ! apply "$copy" "$file" "$from" "$to"; then
    printf 'STALE   #%s %s: the text is not in %s exactly once\n' "$num" "$why" "$file"
  else
    "$copy/tests/$suite" >/dev/null 2>&1; rc=$?
    if (( rc != 0 )); then printf 'caught  #%s %s (%s)\n' "$num" "$why" "$suite"
    else printf 'MISSED  #%s %s: %s passed with the line broken\n' "$num" "$why" "$suite"; fi
  fi
  rm -rf "$copy"
}

results=$(mktemp); trap 'rm -f "$results"' EXIT
num=0; file=""; suite=""; from=""; to=""; why=""
while IFS= read -r line; do
  case "$line" in
    "file: "*)  file="${line#file: }" ;;
    "suite: "*) suite="${line#suite: }" ;;
    "from: "*)  from="${line#from: }" ;;
    "to: "*|"to:") to="${line#to:}"; to="${to# }" ;;
    "why: "*)   why="${line#why: }" ;;
    "---")
      num=$((num + 1))
      if [[ -z "$ONLY" || "$ONLY" == "$num" ]]; then
        while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n; done
        run_one "$num" "$file" "$suite" "$from" "$to" "$why" >> "$results" &
      fi
      file=""; suite=""; from=""; to=""; why="" ;;
  esac
done < <(printf '%s\n---\n' "$MUTATIONS")
wait

sort -t'#' -k2 -n "$results"
if grep -qE '^(MISSED|STALE)' "$results"; then
  printf '\033[31m%d of %d mutations were not caught.\033[0m\n' \
    "$(grep -cE '^(MISSED|STALE)' "$results")" "$(grep -c . "$results")"
  exit 1
fi
printf '\033[32mAll %d mutations were caught.\033[0m\n' "$(grep -c . "$results")"
