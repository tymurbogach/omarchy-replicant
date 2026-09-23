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
file: bin/lib/backup.sh
suite: test-core.sh
from: is_excluded "$(owning_rel "$candrel")" && continue
to: :
why: the prune pass keeps the copy of a file that is switched off
---
file: bin/lib/manifest.sh
suite: test-core.sh
from: version_lt "$running" "$seen" && return 1
to: :
why: an older client does not prune what a newer one tracks
---
file: bin/lib/settings.sh
suite: test-core.sh
from: $NF == "block" {
to: $NF == "never" {
why: a block inhibitor on the lid switch is named
---
file: bin/lib/common.sh
suite: test-core.sh
from: if [[ "$n" == 1 ]]; then printf '%s %s\n' "$n" "$one"; else printf '%s %s\n' "$n" "$many"; fi
to: printf '%s %s\n' "$n" "$many"
why: counts read as English
---
file: bin/lib/plugins.sh
suite: test-core.sh
from: upstream_tree_matches "$pdir" && continue
to: :
why: a plugin whose files match upstream is not called edited
---
file: bin/lib/layout.sh
suite: test-core.sh
from: if [[ ! -x "$SCAN" ]]; then
to: if false; then
why: the pre-commit hook blocks a commit when the scanner is missing
---
file: bin/lib/backup.sh
suite: test-core.sh
from: scan_dirs+=("$REPO_DIR/profiles/$(current_profile)/config")
to: :
why: the backup scans the profile tree for secrets
---
file: bin/lib/restore.sh
suite: test-core.sh
from: is_secret_rel "$1" && { echo 600; return; }
to: :
why: a secret the user tracked is restored at mode 600
---
file: bin/lib/settings.sh
suite: test-settings.sh
from:   # Always a failure. This read `return "${rc:-1}"` with rc starting at 0, so
to:   return 0 #
why: a root-owned write that did not happen is a failure
---
file: bin/lib/backups.sh
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
file: bin/lib/restore.sh
suite: test-cli.sh
from:     echo "unknown area: $only (areas: ${CATEGORY_ORDER[*]})" >&2
to:     :
why: restore refuses an unknown area
---
file: bin/lib/backup.sh
suite: test-journey.sh
from:     if is_incoming_rel "$rel" && entry_differs "$rlive" "$rrepo" "$isdir"; then
to:     if false; then
why: saving everything holds back a file another machine changed
---
file: bin/lib/settings.sh
suite: test-settings.sh
from: in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
to: $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
why: toml_set writes the key only inside its own section
---
file: bin/lib/incoming.sh
suite: test-core.sh
from: [[ "${rel%%/*}" == "$(current_profile)" ]] || continue
to: :
why: a pull marks only this profile's files as incoming
---
file: bin/lib/status.sh
suite: test-core.sh
from: (( age >= FETCH_MAX_AGE ))
to: true
why: status fetches at most once per FETCH_MAX_AGE
---
file: bin/lib/layout.sh
suite: test-core.sh
from: local who; who=$(id -un)
to: local who; who=$USER
why: a new repo gets an identity when $USER is not set
---
file: bin/lib/backup.sh
suite: test-core.sh
from: -o $(id -un) -g $(id -gn)
to: -o $USER -g $USER
why: an unreadable secret is named when $USER is not set
---
file: bin/lib/scopes.sh
suite: test-core.sh
from: print_lines() { (( $# )) || return 0;
to: print_lines() { (( $# )) || return 1;
why: a writer with nothing to keep still succeeds
---
file: bin/lib/settings.sh
suite: test-cli.sh
from: declare -gA FILE_MAP_LOADED=()
to: declare -A FILE_MAP_LOADED=()
why: the core's caches survive being sourced inside a function
---
file: bin/lib/scopes.sh
suite: test-cli.sh
from: printf -v "$1" '%s' "${SCOPE_OF[$2]:-shared}"
to: printf -v "$1" '%s' shared
why: the fork-free scope lookup gives the real scope
---
file: bin/lib/repo.sh
suite: test-cli.sh
from: if [[ -e "$REPO_DIR/${p%/}" || -n "$(git_repo ls-files -- "$p" 2>/dev/null)" ]]; then paths+=("$p"); fi
to: paths+=("$p")
why: untrack commits although one of its paths does not exist
---
file: bin/lib/track.sh
suite: test-cli.sh
from: if [[ -e "${src%/}" ]]; then
to: if false; then
why: forget refuses a file that is still on the machine
---
file: bin/lib/history.sh
suite: test-cli.sh
from: if (( dry )); then skip "dry-run: nothing was touched. Repeat with --apply"; return 0; fi
to: :
why: recover is a dry run by default
---
file: bin/lib/history.sh
suite: test-cli.sh
from: [[ -n "${in_head[$line]:-}" || -n "${seen[$line]:-}" ]] && continue
to: :
why: deleted does not list a copy that is back in the repo
---
file: bin/lib/history.sh
suite: test-cli.sh
from: write_track_file ${keep[@]+"${keep[@]}"}
to: :
why: recovering an untrack tracks the file again
---
file: bin/lib/update.sh
suite: test-cli.sh
from: (( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) >= UPDATE_MAX_AGE ))
to: true
why: update-check asks the origin at most every UPDATE_MAX_AGE
---
file: bin/lib/update.sh
suite: test-cli.sh
from: [[ -n "$id" && "$PLUGIN_DIR" == "$HOME/.config/omarchy/plugins/$id" ]]
to: true
why: only the installed copy updates through omarchy plugin update
---
file: bin/lib/suggest.sh
suite: test-cli.sh
from: else is_tracked_path "$path" && tracked=true; fi
to: else :; fi
why: the file picker says which files are tracked
---
file: bin/lib/plugins.sh
suite: test-core.sh
from: in_bar: ($bar | any(. == $i))})
to: in_bar: false})
why: the Plugins card finds a bar widget's settings in shell.json
---
file: bin/lib/plugins.sh
suite: test-core.sh
from: recorded: ($mine | length > 0),
to: recorded: true,
why: a plugin installed after the last save is not called recorded
---
file: bin/lib/schema.sh
suite: test-schema.sh
from:     2) return 0 ;;
to:     2|99) return 0 ;;
why: a newer data format blocks writes
---
file: bin/lib/schema.sh
suite: test-schema.sh
from:   v=$(jq -r '.dataVersion // empty' "$file" 2>/dev/null || true)
to:   v=1
why: the write gate reads the version from the schema file
---
file: bin/lib/layout.sh
suite: test-schema.sh
from:     ensure_v2_layout
to:     :
why: a fresh repo is born v2
---
file: bin/lib/schema.sh
suite: test-schema.sh
from:   dups=$(_v2_top_keys "$file" | sort | uniq -d)
to:   dups=
why: a duplicate entry id is rejected
---
file: bin/lib/schema.sh
suite: test-schema.sh
from:     '{machineId: $id, profile: $profile, clientVersion: $client, schemaVersion: $schema}' > "$dir/$id.json"
to:     '{machineId: $id, profile: $profile, clientVersion: $client, schemaVersion: $schema, debug: $id}' > "$dir/$id.json"
why: machine metadata holds exactly four fields
---
file: bin/lib/crypto.sh
suite: test-crypto.sh
from:       if cmp -s "$src" "$plain" 2>/dev/null; then
to:       if false; then
why: an unchanged secret keeps its ciphertext byte for byte
---
file: bin/lib/state.sh
suite: test-crypto.sh
from:   elif [[ "$locked_v" == "true" ]]; then sync_state="locked"
to:   elif false; then sync_state="locked"
why: a secret the key cannot read shows as locked
---
file: bin/lib/crypto.sh
suite: test-crypto.sh
from:   if ! age -d -i "$idf" -o "$plain" "$blobs/$blob.age" 2>/dev/null; then
to:   if false; then
why: a tampered blob never replaces live data on restore
---
file: bin/lib/crypto.sh
suite: test-crypto.sh
from:     if ! age -d -i "$old_idf" -o "$plain" "$blobs/$blob.age" 2>/dev/null; then
to:     if false; then
why: rotation re-encrypts every blob from readable plaintext
---
file: bin/lib/crypto.sh
suite: test-crypto.sh
from:   [[ "$(repo_data_version)" == 2 ]] || {
to:   :
why: key init refuses a version 1 repo
---
file: bin/lib/status.sh
suite: test-crypto.sh
from:         vars=""; nvars=0
to:         :
why: a locked secret row carries no variable names or counts
---
file: bin/lib/incoming.sh
suite: test-crypto.sh
from:   printf '%s %s %s %s\n' "$n_unsaved" "$n_incoming" "$n_locked" "$n_missing"
to:   printf '%s %s %s\n' "$n_unsaved" "$n_incoming" "$n_locked"
why: the bar counts locked secrets apart from unsaved ones
---
file: bin/lib/inventory.sh
suite: test-crypto.sh
from:   for retired in system.txt mise.txt npm-global.txt containers.txt system-services.txt defined-secrets.txt; do
to:   for retired in system.txt mise.txt npm-global.txt containers.txt system-services.txt; do
why: a backup sweeps retired inventories including defined-secrets.txt
---
file: bin/omarchy-replicant
suite: test-crypto.sh
from:     if key_out=$(bash "$CORE" key status 2>&1); then key_rc=0; else key_rc=$?; fi
to:     key_rc=0
why: doctor reports the key remedy when the vault is locked
---
file: bin/lib/registry.sh
suite: test-state.sh
from:     [[ -n "${r_live[$rel]:-}" ]] && continue
to:     :
why: a user entry wins over an auto-discovered one
---
file: bin/lib/registry.sh
suite: test-state.sh
from:         [[ -z "$vidx" ]] && locked="true"
to:         :
why: a secret the key cannot read resolves to locked
---
file: bin/lib/registry.sh
suite: test-state.sh
from: {for (i = 1; i <= n; i++) print $i}
to: {print $0}
why: a row with an empty middle field still parses to nine fields
---
file: bin/lib/state.sh
suite: test-state.sh
from:   elif [[ "$incoming_v" == true ]]; then sync_state="incoming"
to:   elif false; then sync_state="incoming"
why: an incoming entry asks for restore, not for save
---
file: bin/lib/incoming.sh
suite: test-state.sh
from:       [[ "$repo" == true ]] && n_missing=$(( n_missing + 1 ))
to:       :
why: the bar counts a saved entry gone from this machine
---
file: bin/lib/status.sh
suite: test-state.sh
from:   (( n_unsaved > 0 || n_incoming > 0 || n_locked > 0 || n_missing > 0 )) && needs_action=true
to:   needs_action=false
why: any actionable count raises needs_action
---
file: bin/lib/briefcache.sh
suite: test-state.sh
from:     [[ "$live_sig" == "$clive" ]] || return 1
to:     :
why: a live-file change drops the brief cache
---
file: bin/lib/incoming.sh
suite: test-state.sh
from:   briefcache_invalidate
to:   :
why: an incoming record drops the brief cache
---
file: bin/lib/status.sh
suite: test-state.sh
from:     (( brief )) && briefcache_write "$n_unsaved" "$n_incoming" "$n_locked" "$n_missing" "$needs_action" 2>/dev/null || true
to:     :
why: a brief miss stores its counts for the next poll
---
file: bin/lib/save.sh
suite: test-save.sh
from:     did_commit=1
to:     did_commit=0
why: a committed transaction is fast-forwarded into the active repo
---
file: bin/lib/migrate.sh
suite: test-migration.sh
from:   mv -- "$REPO_DIR" "$legacy" || { rm -f -- "$identity_backup"; rm -rf -- "$root"; return 1; }
to:   true || { rm -f -- "$identity_backup"; rm -rf -- "$root"; return 1; }
why: migration activates the new repository only after the staged copy passes verification
---
file: bin/omarchy-replicant
suite: test-bulk.sh
from:         (( rc == 0 )) && git_repo merge --ff-only -q FETCH_HEAD || rc=$?
to:         (( rc == 0 )) && : || rc=$?
why: a successful bulk transaction fast-forwards the active repository
---
file: bin/lib/save.sh
suite: test-save.sh
from:     echo "save: the repo has uncommitted changes — a save needs a clean worktree:" >&2
to:     :
why: a save refuses a dirty worktree before creating anything
---
file: bin/omarchy-replicant
suite: test-save.sh
from:   warn "savegame is deprecated — 'save' does this now (same options)"
to:   :
why: savegame says it is deprecated
---
file: bin/lib/repo.sh
suite: test-save.sh
from:     echo "pull: the repo has uncommitted changes — pull needs a clean worktree:" >&2
to:     :
why: pull refuses a dirty worktree instead of stashing it
---
file: bin/lib/repo.sh
suite: test-save.sh
from:     echo "nothing to push — there is no remote yet: run 'omarchy-replicant create --push'" >&2
to:     :
why: push names the next step when there is no remote
---
file: bin/lib/repo.sh
suite: test-save.sh
from:     if ! push_err=$(git_repo push -q 2>&1); then
to:     if false; then
why: a shape commit that cannot push reports the local commit and fails
---
file: bin/lib/save.sh
suite: test-save.sh
from:     if (( ! force )); then
to:     if false; then
why: discarding a committed transaction needs an explicit force
---
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
      [[ -n "$file" ]] || continue
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
