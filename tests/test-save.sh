#!/bin/bash
# Saves as transactions: one snapshot, one commit, and an active worktree that
# stays untouched until the fast-forward. Every failure below also checks what
# did NOT happen, because that is the whole point of section 5A.
#
# Runs against a fake $HOME and a throwaway repo, the way test-cli.sh does.
# Version 1 throughout, except the last section, which builds its own v2
# world in a subshell for the encrypted half.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
CORE_BIN="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
copy_backup() { bash "$CORE_BIN" backup 2>&1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"
REPO="$OMARCHY_REPLICANT_HOME/repo"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy" "$OMARCHY_PATH/config/hypr"
printf 'default input\n'  > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'my own input\n'   > "$HOME/.config/hypr/input.lua"
cat > "$HOME/.config/omarchy/shell.json" <<'JSON'
{ "idle": { "screensaver": 300, "lock": 600 } }
JSON

# Pin version 1: a repo with history keeps what it has, so initializing git
# before the first command means no v2 skeleton is ever written.
mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null

run() { "$CLI" "$@" 2>&1; }
head_now() { git -C "$REPO" rev-parse HEAD 2>/dev/null; }
commits_since() { git -C "$REPO" rev-list --count "$1"..HEAD 2>/dev/null; }

copy_backup >/dev/null 2>&1
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "test base" >/dev/null 2>&1

section "save --all is one commit and leaves a clean tree"
printf 'edited once\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
run save --all -m "config: test save" --no-push >/dev/null 2>&1
check "one commit, not two" "1" "$(commits_since "$before")"
check "…with the message given" "config: test save" "$(git -C "$REPO" log -1 --format=%s)"
check "…and the tree is clean" "0" "$(git -C "$REPO" status --porcelain | grep -c . || true)"
check "…and the file is saved" "0" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"
check "a successful save leaves no transactions behind" "0" \
  "$(ls -A "$OMARCHY_REPLICANT_HOME/transactions" 2>/dev/null | wc -l)"

section "save --auto names what changed"
printf 'edited twice\n' >> "$HOME/.config/hypr/input.lua"
run save --all --auto --no-push >/dev/null 2>&1
check "the subject names the file" "1" \
  "$(git -C "$REPO" log -1 --format=%s | grep -c 'hypr/input.lua' || true)"

section "save --id commits exactly one entry"
printf 'shell tweak\n' >> "$HOME/.config/omarchy/shell.json"
printf 'edited thrice\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
run save --id hypr/input.lua -m "config: just input" --no-push >/dev/null 2>&1
check "one commit" "1" "$(commits_since "$before")"
check "…holding exactly one file" "1" \
  "$(git -C "$REPO" show --stat --name-only --format='' HEAD | grep -c .)"
check "…the one asked for" "config/hypr/input.lua" \
  "$(git -C "$REPO" show --name-only --format='' HEAD | head -1)"
check "…while the other file stays unsaved" "1" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"

section "a save with no message is a review, not a commit"
before=$(head_now)
out=$(run save --all --no-push; echo "rc=$?")
check "it exits 0" "1" "$(grep -c 'rc=0' <<<"$out" || true)"
check "…commits nothing" "$before" "$(head_now)"
check_contains "…and says it committed nothing" "Nothing was committed" "$out"

section "save --inventory takes only the inventory"
mkdir -p "$HOME/.config/omarchy/themes/second"
git init -q "$HOME/.config/omarchy/themes/second" 2>/dev/null
git -C "$HOME/.config/omarchy/themes/second" remote add origin https://example.com/omarchy-second-theme 2>/dev/null
before=$(head_now)
run save --inventory --no-push >/dev/null 2>&1
check "one commit" "1" "$(commits_since "$before")"
check "…holding nothing outside state/" "0" \
  "$(git -C "$REPO" show --stat --name-only --format='' HEAD | grep -vc '^state/' || true)"
check "…under the inventory subject" "1" \
  "$(git -C "$REPO" log -1 --format=%s | grep -c 'inventory' || true)"
check "…while the config edit is still pending" "1" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"

section "savegame stays compatible through the alias"
check_contains "it says it is deprecated" "deprecated" "$(run savegame --auto --no-push)"
run save --all -m "clear the decks" --no-push >/dev/null 2>&1
printf 'left for a reason\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
out=$(run savegame --no-push; echo "rc=$?")
check "bare savegame exits 0" "1" "$(grep -c 'rc=0' <<<"$out" || true)"
check "…leaves the config uncommitted" "$before" "$(head_now)"
check "…which still reads unsaved" "1" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"
run savegame --auto --no-push >/dev/null 2>&1
check "savegame --auto still saves everything" "0" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"

section "save-file is save --id with a default subject"
printf 'per-file\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
run save-file hypr/input.lua >/dev/null 2>&1
check "one commit" "1" "$(commits_since "$before")"
check "…exactly one file" "1" \
  "$(git -C "$REPO" show --stat --name-only --format='' HEAD | grep -c .)"
check "…with the default subject" "config: update hypr/input.lua" \
  "$(git -C "$REPO" log -1 --format=%s)"
check_false "save-file on an unknown id fails" "$CLI" save-file nope/nope

section "a save on a dirty repo fails and touches nothing"
printf 'dirty me\n' >> "$HOME/.config/hypr/input.lua"
copy_backup >/dev/null 2>&1
check_true "the backup dirtied the tree" \
  test -n "$(git -C "$REPO" status --porcelain)"
before=$(head_now)
rc=0; out=$(run save --all -m "must not land") || rc=$?
check "the save refuses" "1" "$rc"
check "…naming the clean-worktree rule" "1" "$(grep -c 'clean worktree' <<<"$out" || true)"
check "…with the commit point unmoved" "$before" "$(head_now)"
git -C "$REPO" checkout -- . >/dev/null 2>&1
git -C "$REPO" clean -fdq >/dev/null 2>&1
run save --all --auto --no-push >/dev/null 2>&1
check "…and works again once the tree is clean" "0" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"

section "a secret in the snapshot blocks the save before any commit"
# Assembled from pieces: a whole token here is a real credential to every
# scanner in the chain, including the repo's own pre-commit hook. The shape
# is the classic GitHub token the scanner knows, like test-core.sh uses.
P_GH="gh""p_"
printf 'token = %sabcdefghijklmnopqrstuvwxyz0123456789\n' "$P_GH" \
  > "$HOME/.config/hypr/input.lua"
before=$(head_now)
rc=0; run save --all -m "must not land" >/dev/null 2>&1 || rc=$?
check "the save fails" "1" "$rc"
check "…with the commit point unmoved" "$before" "$(head_now)"
check "…and the active tree has no snapshot litter" "0" \
  "$(git -C "$REPO" status --porcelain | grep -c . || true)"
printf 'my own input\nedited once\nedited twice\nedited thrice\nleft for a reason\nper-file\ndirty me\n' \
  > "$HOME/.config/hypr/input.lua"
run save --all --auto --no-push >/dev/null 2>&1
check "…and the cleanup saves again" "0" \
  "$(run status --json --brief --no-fetch | jq -r .unsaved)"

section "a push that fails keeps the commit and says so"
git -C "$REPO" remote add origin /nonexistent/remote.git 2>/dev/null
printf 'one more\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
rc=0; out=$(run save --all --auto) || rc=$?
check "a rejected push is a failure" "1" "$rc"
check "…that never claims it pushed" "0" "$(grep -c 'saved and pushed' <<<"$out" || true)"
check_contains "…but says the commit is local" "Saved locally" "$out"
check "…and the commit really is local" "1" "$(commits_since "$before")"
check "…kept with its transaction for recovery" "1" \
  "$(ls "$OMARCHY_REPLICANT_HOME/transactions" 2>/dev/null | wc -l)"
check "…and the transaction is listed" "1" "$(run tx list | grep -c . || true)"
check_contains "…and doctor names the resume" "tx resume" "$(run doctor)"
for _tx in $(run tx list 2>/dev/null | cut -f1); do run tx discard "$_tx" --force >/dev/null 2>&1; done
check "…and cleanup discards it" "0" \
  "$(ls -A "$OMARCHY_REPLICANT_HOME/transactions" 2>/dev/null | wc -l)"
git -C "$REPO" remote remove origin 2>/dev/null

section "an empty save pushes what waits and says nothing happened"
before=$(head_now)
out=$(run save --all --auto; echo "rc=$?")
check "it exits 0" "1" "$(grep -c 'rc=0' <<<"$out" || true)"
check "…commits nothing" "$before" "$(head_now)"
check_contains "…and says so plainly" "Nothing to save" "$out"

section "changes reviews without writing, backup is its alias"
printf 'review me\n' >> "$HOME/.config/hypr/input.lua"
copy_backup >/dev/null 2>&1
before=$(head_now)
out=$(run changes 2>&1; echo "rc=$?")
check "changes exits 0" "1" "$(grep -c 'rc=0' <<<"$out" || true)"
check "…writes nothing" "$before" "$(head_now)"
check "…leaving the pending copies in place" "1" "$(git -C "$REPO" status --porcelain | grep -c . || true)"
check_contains "…and points at save" "save --all" "$out"
out=$(run backup 2>&1; echo "rc=$?")
check "backup still runs as the alias" "1" "$(grep -c 'rc=0' <<<"$out" || true)"
check "…saying it is deprecated" "1" "$(grep -ci 'deprecated' <<<"$out" || true)"
check "…writing nothing either" "$before" "$(head_now)"
git -C "$REPO" checkout -- . >/dev/null 2>&1
git -C "$REPO" clean -fdq >/dev/null 2>&1
run save --all --auto --no-push >/dev/null 2>&1

section "pull rejects a dirty worktree instead of stashing it"
printf 'dirty pull\n' >> "$HOME/.config/hypr/input.lua"
copy_backup >/dev/null 2>&1
before=$(head_now)
rc=0; out=$(run pull 2>&1) || rc=$?
check "the pull refuses" "1" "$rc"
check_contains "…naming the clean-worktree rule" "clean worktree" "$out"
check_contains "…with recovery steps" "changes" "$out"
check "…with the commit point unmoved" "$before" "$(head_now)"
check "…and no stash left behind" "0" "$(git -C "$REPO" stash list 2>/dev/null | wc -l)"
git -C "$REPO" checkout -- . >/dev/null 2>&1
git -C "$REPO" clean -fdq >/dev/null 2>&1
run save --all --auto --no-push >/dev/null 2>&1

section "push reports the same outcomes as save"
out=$(run push 2>&1; echo "rc=$?")
check "no remote is not a failure" "1" "$(grep -c 'rc=0' <<<"$out" || true)"
check_contains "…naming the next step" "create --push" "$out"
git -C "$REPO" remote add origin /nonexistent/remote.git 2>/dev/null
printf 'push me\n' >> "$HOME/.config/hypr/input.lua"
run save --all --auto --no-push >/dev/null 2>&1
rc=0; out=$(run push 2>&1) || rc=$?
check "a failed push exits 1" "1" "$rc"
check_contains "…saying the commits stay local" "Saved locally" "$out"
check_contains "…with the retry step" "pull" "$out"
git -C "$REPO" remote remove origin 2>/dev/null
out=$(run push 2>&1; echo "rc=$?")
check "nothing to push exits 0 once the remote is gone" "1" "$(grep -c 'rc=0' <<<"$out" || true)"

section "abandoned transactions list, resume and discard"
txdir="$OMARCHY_REPLICANT_HOME/transactions/fake-started"
mkdir -p "$txdir"
printf '{"version":1,"base":"abc","scope":"all","ids":[],"msg":"","stage":"started","candidate":null,"push":null}\n' > "$txdir/meta.json"
check "a pre-commit journal is listed" "1" "$(run tx list | grep -c fake-started || true)"
check_contains "…and doctor names the discard" "tx discard fake-started" "$(run doctor)"
check_false "resuming a journal with no commit fails" "$CLI" tx resume fake-started
run tx discard fake-started >/dev/null 2>&1
check "…while discarding removes it" "0" "$(run tx list | grep -c fake-started || true)"
check_false "discarding twice fails" "$CLI" tx discard fake-started
check "a committed journal needs --force to discard" "1" \
  "$( { mkdir -p "$OMARCHY_REPLICANT_HOME/transactions/fake-committed"
      printf '{"version":1,"base":"abc","scope":"all","ids":[],"msg":"","stage":"committed","candidate":"deadbeef","push":"failed"}\n' \
        > "$OMARCHY_REPLICANT_HOME/transactions/fake-committed/meta.json"
      run tx discard fake-committed >/dev/null 2>&1; echo $?; } )"
run tx discard fake-committed --force >/dev/null 2>&1
check "…and --force removes it" "0" "$(run tx list | grep -c fake-committed || true)"
check_contains "…and doctor is quiet again" "no abandoned save transactions" "$(run doctor)"
check "a successful save leaves no transactions behind" "0" \
  "$(run tx list | grep -c . || true)"

section "v2 secrets save through the transaction in one commit"
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
    && probe=$(mktemp -d) && ( umask 077; age-keygen -pq -o "$probe/key" >/dev/null 2>&1 ) \
    && grep -q '^# public key: age1pq1' "$probe/key" 2>/dev/null; then
  rm -rf -- "$probe"
  OLDHOME="$HOME" OLDREP="$OMARCHY_REPLICANT_HOME"
  export HOME="$TMP/v2home" OMARCHY_REPLICANT_HOME="$TMP/v2rep"
  VREPO="$OMARCHY_REPLICANT_HOME/repo"
  mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d"
  printf 'FIRST=save-fixture-alpha\n' > "$HOME/.config/environment.d/60-secrets.conf"
  printf 'my own input\n' > "$HOME/.config/hypr/input.lua"
  run init >/dev/null 2>&1
  "$CLI" key init >/dev/null 2>&1
  printf 'edited\n' >> "$HOME/.config/hypr/input.lua"
  printf 'SECOND=save-fixture-beta\n' >> "$HOME/.config/environment.d/60-secrets.conf"
  before_v2=$(git -C "$VREPO" rev-parse HEAD)
  run save --all --auto --no-push >/dev/null 2>&1
  check "config and vault land in one commit" "1" \
    "$(git -C "$VREPO" rev-list --count "$before_v2"..HEAD 2>/dev/null)"
  check "…naming the blob, never the secret" "1" \
    "$(git -C "$VREPO" show --stat --name-only --format='' HEAD | grep -c 'vault/blobs/' || true)"
  check "…with a clean tree" "0" \
    "$(git -C "$VREPO" status --porcelain | grep -c . || true)"
  export HOME="$OLDHOME" OMARCHY_REPLICANT_HOME="$OLDREP"
else
  rm -rf -- "${probe:-/nonexistent}" 2>/dev/null || true
  section "v2 secrets save through the transaction in one commit"
  check_true "age without post-quantum support skips the vault save" true
fi

summary
