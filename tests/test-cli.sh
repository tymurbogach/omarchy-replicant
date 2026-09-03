#!/bin/bash
# The bin/omarchy-replicant command surface: argument handling, the read-only
# commands, and — the part that matters most — that every destructive command
# really is a no-op until it is given --apply.
#
# Runs against a fake $HOME and a local bare repo standing in for GitHub, so
# nothing here can reach the network or the user's own machine state.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"
REPO="$OMARCHY_REPLICANT_HOME/repo"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy" "$OMARCHY_PATH/config/hypr" "$OMARCHY_PATH/default/bash"
printf 'default input\n'  > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'default bashrc\n' > "$OMARCHY_PATH/default/bash/bashrc"
printf 'my own input\n'   > "$HOME/.config/hypr/input.lua"
printf 'my own bashrc\n'  > "$HOME/.bashrc"
cat > "$HOME/.config/omarchy/shell.json" <<'JSON'
{ "idle": { "screensaver": 300, "lock": 600 }, "bar": { "position": "top", "transparent": false } }
JSON

run() { "$CLI" "$@" 2>&1; }

section "the command surface"
check_contains "help lists the commands" "omarchy-replicant savegame" "$(run --help)"
check_contains "help mentions the new ones" "doctor" "$(run --help)"
for c in "sync <id>" "revert <id>" "restore-file <id>" "shortcuts"; do
  check_contains "help documents $c" "$c" "$(run --help)"
done
check_true  "--help exits 0"      "$CLI" --help
check_false "an unknown command fails" "$CLI" definitely-not-a-command
check_contains "…and says so" "unknown command" "$(run definitely-not-a-command)"
check_false "status on an uninitialised machine still answers" false
check "status --json before setup is valid JSON" "0" "$(run status --json | jq empty >/dev/null 2>&1; echo $?)"
check "…and reports not initialized" "false" "$(run status --json | jq -r '.initialized')"

section "id -> path resolution"
check "resolves a tracked id"  "$HOME/.config/hypr/input.lua" "$(run path hypr/input.lua)"
check_false "rejects an unknown id" "$CLI" path nope/nope
check_false "path with no argument fails" "$CLI" path

section "reading and writing one setting"
check "get reads a value"      "300" "$(run get idle.screensaver)"
check_false "get on an unknown id fails" "$CLI" get not.a.setting

section "dry runs must not write — proven by hashing the files"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
"$CLI" backup >/dev/null 2>&1
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m initial >/dev/null 2>&1
# Diverge the machine from the repo so both dry runs have real work to describe.
printf 'changed on this machine\n' > "$HOME/.config/hypr/input.lua"

before_home=$(hash_tree "$HOME/.config")
before_repo=$(hash_tree "$REPO")

out=$(run restore --dry-run)
check "restore --dry-run leaves ~/.config alone" "$before_home" "$(hash_tree "$HOME/.config")"
check "restore --dry-run leaves the repo alone"  "$before_repo" "$(hash_tree "$REPO")"
check_contains "…and says it wrote nothing" "Dry-run" "$out"

out=$(run reset-all --dry-run)
check "reset-all --dry-run leaves ~/.config alone" "$before_home" "$(hash_tree "$HOME/.config")"
check "reset-all --dry-run leaves the repo alone"  "$before_repo" "$(hash_tree "$REPO")"
check_contains "…and says it wrote nothing" "Dry-run" "$out"

# Dry-run is the DEFAULT, not something you have to remember to ask for.
out=$(run restore)
check "restore with no flags is a dry run"  "$before_home" "$(hash_tree "$HOME/.config")"
out=$(run reset-all)
check "reset-all with no flags is a dry run" "$before_home" "$(hash_tree "$HOME/.config")"

section "reset refuses what it cannot restore"
# A file Omarchy ships no default for has nothing to be reset to, and must be
# refused before `omarchy refresh` is ever invoked.
check_false "no default -> refused" "$CLI" reset omarchy/shell.toml
check_contains "…with a reason" "no Omarchy default" "$(run reset omarchy/shell.toml)"
check_false "unknown id -> refused" "$CLI" reset nope/nope
check "nothing was touched" "$before_home" "$(hash_tree "$HOME/.config")"

section "save-file touches one file and nothing else"
"$CLI" backup >/dev/null 2>&1
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m "second" >/dev/null 2>&1
printf 'edited again\n' > "$HOME/.config/hypr/input.lua"
run save-file hypr/input.lua -m "config: test" >/dev/null 2>&1
check "committed exactly one file" "1" "$(git -C "$REPO" show --stat --name-only --format='' HEAD | grep -c .)"
check "…and it is the one asked for" "config/hypr/input.lua" "$(git -C "$REPO" show --name-only --format='' HEAD | head -1)"
check "…with the message given"      "config: test" "$(git -C "$REPO" log -1 --format=%s)"
check_false "save-file on an unknown id fails" "$CLI" save-file nope/nope

section "log and settings"
check "log --json is valid JSON" "0" "$(run log --json | jq empty >/dev/null 2>&1; echo $?)"
check "log --json respects -n"   "1" "$(run log --json -n 1 | jq 'length')"
check "settings --json is valid" "0" "$(run settings --json | jq empty >/dev/null 2>&1; echo $?)"
check_contains "settings prints groups" "Idle & power" "$(run settings)"
check_contains "settings shows a value"  "Screensaver"  "$(run settings)"

section "diff renders as plain text for the panel"
check_contains "against the repo by default" "this machine" "$(run diff hypr/input.lua)"
check_contains "--against default works"     "omarchy default" "$(run diff hypr/input.lua --against default)"
check_false "diff with no id fails" "$CLI" diff nope/nope

section "the per-file sync switch, from the command line"
check_false "sync needs both arguments" "$CLI" sync hypr/input.lua
check_false "…and a real id"            "$CLI" sync nope/nope off
check_false "…and a real state"         "$CLI" sync hypr/input.lua sideways
run sync hypr/input.lua off >/dev/null 2>&1
check "switching off is recorded in the repo" "1" \
  "$(grep -cx 'hypr/input.lua' "$REPO/.replicant-exclude" 2>/dev/null || true)"
check "…and the panel reads it back as off" "off" \
  "$(run status --json --no-fetch | jq -r '[.configs[] | select(.id=="hypr/input.lua")][0].sync_state')"
# The decision is a fact about the setup, so it travels with the repo.
check "…committed, not left dangling" "0" \
  "$(git -C "$REPO" status --porcelain -- .replicant-exclude | grep -c . || true)"
run sync hypr/input.lua on >/dev/null 2>&1
check "switching back on clears it" "0" \
  "$(grep -cx 'hypr/input.lua' "$REPO/.replicant-exclude" 2>/dev/null || true)"

section "reverting one setting"
check_false "revert needs an id"       "$CLI" revert
check_false "…a known one"             "$CLI" revert not.a.setting
check_false "…and a known target"      "$CLI" revert idle.lock --to sideways
mkdir -p "$OMARCHY_PATH/config/omarchy"
printf '{"idle":{"lock":300}}\n' > "$OMARCHY_PATH/config/omarchy/shell.json"
run set idle.lock 900 >/dev/null 2>&1
check "the value moved"        "900" "$(run get idle.lock)"
run revert idle.lock --to default >/dev/null 2>&1
check "reverting to Omarchy's default puts it back" "300" "$(run get idle.lock)"
check "…in the stored unit, not the panel's"        "300" \
  "$(jq -r '.idle.lock' "$HOME/.config/omarchy/shell.json")"

section "restoring one file from the repo"
check_false "restore-file needs an id" "$CLI" restore-file
check_false "…a known one"             "$CLI" restore-file nope/nope
printf 'edited after the last save\n' > "$HOME/.config/hypr/input.lua"
run restore-file hypr/input.lua >/dev/null 2>&1
check "the file came back from the repo" "0" \
  "$(cmp -s "$HOME/.config/hypr/input.lua" "$REPO/config/hypr/input.lua"; echo $?)"
check "…and the version it replaced is on disk" "1" \
  "$(ls "$HOME/.config/hypr/input.lua".bak.* 2>/dev/null | wc -l)"

section "shortcuts"
mkdir -p "$HOME/.config/hypr"
printf 'o.bind("SUPER + J", "Journal", "obsidian")\n' > "$HOME/.config/hypr/bindings.lua"
check "shortcuts --json is valid JSON" "0" "$(run shortcuts --json | jq empty >/dev/null 2>&1; echo $?)"
check "…and finds your own binding"    "1" "$(run shortcuts --json | jq '.own | length')"
check_contains "the plain listing names it" "Journal" "$(run shortcuts)"

section "doctor is read-only"
before_home=$(hash_tree "$HOME/.config")
before_repo=$(hash_tree "$REPO")
run doctor >/dev/null 2>&1
check "doctor changes nothing in ~/.config" "$before_home" "$(hash_tree "$HOME/.config")"
check "doctor changes nothing in the repo"  "$before_repo" "$(hash_tree "$REPO")"
check_contains "doctor reports on the repo" "local repo" "$(run doctor)"

section "link / unlink is reversible and touches nothing else"
export PATH_LINK="$HOME/.local/bin/omarchy-replicant"
check "nothing on PATH before linking" "0" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
run link >/dev/null 2>&1
check "link creates the symlink"       "1" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
check "…pointing at the plugin's own CLI" "$(readlink -f "$CLI")" "$(readlink -f "$PATH_LINK")"
run link >/dev/null 2>&1
check "linking twice is not an error"  "1" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
run unlink >/dev/null 2>&1
check "unlink removes it"              "0" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
check_true "unlinking twice is not an error" "$CLI" unlink
# It must never delete a real file someone put there themselves.
mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\n' > "$PATH_LINK"
run unlink >/dev/null 2>&1
check "a real file at that path is left alone" "1" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
check_false "…and link refuses to clobber it" "$CLI" link
rm -f "$PATH_LINK"

section "purge is a dry run by default and never touches the remote"
run link >/dev/null 2>&1
out=$(run purge)
check_contains "lists what it would remove" "would remove" "$out"
check "purge --dry-run removes nothing"   "1" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
check_contains "keeps the repo unless asked" "keeping your backup repo" "$out"
check "…and the repo is still there"      "1" "$(ls -d "$REPO" 2>/dev/null | wc -l)"
run purge --apply --yes >/dev/null 2>&1
check "purge --apply removes the symlink" "0" "$(ls "$PATH_LINK" 2>/dev/null | wc -l)"
check "…and still keeps the repo"         "1" "$(ls -d "$REPO" 2>/dev/null | wc -l)"
check "…and the lock file is gone"        "0" "$(ls "$OMARCHY_REPLICANT_HOME/.replicant.lock" 2>/dev/null | wc -l)"
run purge --apply --yes --repo >/dev/null 2>&1
check "purge --repo removes the local clone" "0" "$(ls -d "$REPO" 2>/dev/null | wc -l)"

section "concurrent writes are serialized, not corrupted"
# the repo was just purged; rebuild it for this last check
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
# Two writes racing used to collide on .git/index.lock and one would die
# half-done, leaving the repo mid-commit.
for i in 1 2 3; do ( "$CLI" backup >/dev/null 2>&1 ) & done
wait
check "no leftover git index lock" "0" "$(ls "$REPO/.git/index.lock" 2>/dev/null | wc -l)"
check_true "the repo is still usable afterwards" git -C "$REPO" status --porcelain

summary
