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
# `omarchy refresh config` restores one FILE. A tracked directory has no single
# default to go back to, and cmp on a directory would decide whether it is
# "still the default" by failing. Today the only reason one is never offered is
# that Omarchy ships no default for the directories people track — luck.
check_false "a directory cannot be reset" "$CLI" reset "nvim/"
check_contains "…and it says what to use instead" "restore-file" "$(run reset 'nvim/')"
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
  "$(grep -cx 'hypr/input.lua = off' "$REPO/.replicant-sync" 2>/dev/null || true)"
check "…and the panel reads it back as off" "off" \
  "$(run status --json --no-fetch | jq -r '[.configs[] | select(.id=="hypr/input.lua")][0].sync_state')"
# The decision is a fact about the setup, so it travels with the repo.
check "…committed, not left dangling" "0" \
  "$(git -C "$REPO" status --porcelain -- .replicant-sync | grep -c . || true)"
run sync hypr/input.lua on >/dev/null 2>&1
check "switching back on clears it" "0" \
  "$(grep -c '^hypr/input.lua' "$REPO/.replicant-sync" 2>/dev/null || true)"

section "three scopes and two profiles, from the command line"
check_false "scope needs both arguments" "$CLI" scope hypr/input.lua
check_false "…and a real id"             "$CLI" scope nope/nope shared
check_false "…and a real scope"          "$CLI" scope hypr/input.lua sideways
run scope hypr/input.lua profile >/dev/null 2>&1
check "scoping to a profile is recorded" "1" \
  "$(grep -cx 'hypr/input.lua = profile' "$REPO/.replicant-sync" 2>/dev/null || true)"
check "…and the panel reads the scope back" "profile" \
  "$(run status --json --no-fetch | jq -r '[.configs[] | select(.id=="hypr/input.lua")][0].scope')"
# Scoped to a profile is emphatically NOT switched off: it still syncs, just
# not with the other profile. The badge has to keep saying so.
check "…and it is not reported as off" "false" \
  "$(run status --json --no-fetch | jq -r '[.configs[] | select(.id=="hypr/input.lua")][0].sync_state == "off"')"
check "…committed, not left dangling" "0" \
  "$(git -C "$REPO" status --porcelain -- .replicant-sync | grep -c . || true)"
run scope hypr/input.lua shared >/dev/null 2>&1

check "profile prints the current one" "1" \
  "$(run profile | grep -c 'is in the' || true)"
run profile deskbox >/dev/null 2>&1
check "…and can be set"            "deskbox" "$(run profile | sed -n 's/.*is in the "\([^"]*\)".*/\1/p')"
check "…and is recorded in the repo" "1" \
  "$(grep -c ' = deskbox$' "$REPO/.replicant-profiles" 2>/dev/null || true)"
check_false "a nonsense profile name is refused" "$CLI" profile "../etc"

# A scope change is one decision and must commit exactly that. Staging the whole
# of config/ would sweep any unrelated dotfile that happened to be pending into a
# commit whose message says "scope:" — the data repo's one-commit-per-decision
# convention exists precisely to stop that.
printf 'an unrelated edit\n' >> "$REPO/config/omarchy/shell.json"
run scope hypr/hyprlock.conf profile >/dev/null 2>&1
check "a scope commit touches only that file and the scope list" "0" \
  "$(git -C "$REPO" show --stat --format="" HEAD 2>/dev/null | grep -c 'shell.json' || true)"
check "…and the unrelated edit is still pending, not swallowed" "1" \
  "$(git -C "$REPO" status --porcelain -- config/omarchy/shell.json | grep -c . || true)"
git -C "$REPO" checkout -- config/omarchy/shell.json 2>/dev/null || true
run scope hypr/hyprlock.conf shared >/dev/null 2>&1

section "editing a file, and coming back to the panel"
# --wait only means something for an editor that can be waited on. A terminal
# editor is opened in a floating terminal that detaches, so the CLI must NOT
# claim it waited — the panel reopens on that marker and only that marker, and
# reopening over a floating terminal would be worse than staying shut.
printf 'nano\n' > "$HOME/.local/state/omarchy/defaults/editor"
# Stub out every way this command can reach a real editor. Without them the
# fallback branch runs the machine's actual omarchy-launch-editor, and the test
# opens nvim on the screen of whoever is running the suite — which is both
# rude and a way to make the measurement lie, because a window closing
# mid-test changes what the command returns.
mkdir -p "$TMP/nobin"
for stub in omarchy-launch-editor xdg-open nano nvim; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/nobin/$stub"; chmod +x "$TMP/nobin/$stub"
done
out=$(PATH="$TMP/nobin:$PATH" EDITOR="$TMP/nobin/nvim" run edit hypr/input.lua --wait 2>/dev/null || true)
check "a terminal editor does not claim to have waited" "0" \
  "$(printf '%s' "$out" | grep -c 'replicant:waited' || true)"
check_false "edit still needs an id"  "$CLI" edit --wait
check_false "…and a real one"         "$CLI" edit nope/nope --wait

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
# A directory restore leaves its backup as a whole TREE beside the original.
# Hard rule 8 is that purge can name everything this plugin leaves behind, and
# a restored tree sitting next to the real one is not a small thing to miss:
# globbing "$src".bak.* on a tracked directory looked INSIDE it, and the
# removal used rm -f, which silently does nothing to a directory.
mkdir -p "$HOME/.config/nvim.bak.1700000000"
printf 'old\n' > "$HOME/.config/nvim.bak.1700000000/init.lua"
out=$(run purge)
check_contains "a directory backup is listed too" ".bak.<epoch> backup(s)" "$out"
check "…and the dry run leaves it alone" "1" "$(ls -d "$HOME/.config/nvim.bak.1700000000" 2>/dev/null | wc -l)"
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
check "…and the directory backup is really gone, not just listed" "0" \
  "$(ls -d "$HOME/.config/nvim.bak.1700000000" 2>/dev/null | wc -l)"
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

section "track / untrack commit only their own paths"
printf 'mine\n' > "$HOME/.config/mine.conf"
# Something unrelated left pending, exactly as a user would have it.
printf '{ "idle": { "lock": 900 } }\n' > "$HOME/.config/omarchy/shell.json"
run backup >/dev/null 2>&1
run track "$HOME/.config/mine.conf" >/dev/null 2>&1
check_contains "the list names it" "mine.conf" "$(cat "$REPO/.replicant-track" 2>/dev/null)"
check "the track commit is about the list, not the pending edit" "0" \
  "$(git -C "$REPO" show --stat --format="" HEAD 2>/dev/null | grep -c 'shell.json' || true)"
check "…and it does commit the list" "1" \
  "$(git -C "$REPO" show --stat --format="" HEAD 2>/dev/null | grep -c 'replicant-track' || true)"
check "…leaving the unrelated edit still pending" "1" \
  "$(git -C "$REPO" status --porcelain -- config/omarchy/shell.json | grep -c . || true)"
check_false "track needs a path"                "$CLI" track
check_false "…that exists"                      "$CLI" track "$HOME/.config/definitely-not-here.conf"
check_false "untrack needs an id"               "$CLI" untrack
check_false "untrack refuses a shipped file"    "$CLI" untrack hypr/input.lua
run untrack mine.conf >/dev/null 2>&1
check "untracking removes it from the list" "0" \
  "$(grep -c 'mine.conf' "$REPO/.replicant-track" 2>/dev/null || true)"

section "suggest never writes anything"
before=$(hash_tree "$HOME")
out=$(run suggest 2>&1)
check "suggest changes nothing on the machine" "$before" "$(hash_tree "$HOME")"
check "suggest --json is valid JSON" "0" \
  "$("$CLI" suggest --json 2>/dev/null | jq empty >/dev/null 2>&1; echo $?)"
check_contains "help documents track" "track <path>" "$(run --help)"
check_contains "help documents suggest" "suggest" "$(run --help)"

section "the background poll is cheap"
# The bar icon reads six numbers and polls once a minute. It used to build the
# whole payload — fifty file rows, every setting, every category — to answer
# them, which was 1.4 s of CPU a minute for a plugin that was idle.
brief=$(run status --json --brief 2>/dev/null | tail -n1)
check "brief is valid JSON" "0" "$(printf '%s' "$brief" | jq empty >/dev/null 2>&1; echo $?)"
check "…and says so"        "true" "$(printf '%s' "$brief" | jq -r '.brief')"
for f in initialized branch dirty ahead behind; do
  check "brief still answers $f" "true" "$(printf '%s' "$brief" | jq --arg f "$f" 'has($f)')"
done
for f in configs settings categories secrets; do
  check "brief does not build $f" "false" "$(printf '%s' "$brief" | jq --arg f "$f" 'has($f)')"
done
full=$(run status --json 2>/dev/null | tail -n1)
check "the full payload still has configs" "true" "$(printf '%s' "$full" | jq 'has("configs")')"
check "…and is not marked brief" "false" "$(printf '%s' "$full" | jq 'has("brief")')"

section "every command is asked a question it cannot answer"
# A smoke pass over the whole surface. What is being checked is not that these
# fail — it is that they fail the way a person can act on: exit 1 with a
# sentence, never a bare git exit code or a stack of shell errors.
for bad in "get nope.setting" "set nope.setting 5" "edit nope/nope" "path nope/nope" \
           "save-file nope/nope" "scope nope/nope shared" "scope hypr/input.lua sideways" \
           "revert nope.setting" "restore-file nope/nope" "reset nope/nope" \
           "track /nonexistent/x" "untrack nope/nope" "profile ../evil"; do
  # shellcheck disable=SC2086
  out=$(run $bad 2>&1); rc=$?
  check "'$bad' exits 1, not a raw error code" "1" "$rc"
  if [[ -z "$out" ]]; then t_bad "'$bad' failed silently"; else t_ok "…and says why"; fi
done
check_contains "revert names the real problem" "unknown setting" "$(run revert nope.setting)"

section "the secret scanner is the last thing between a token and GitHub"
# It runs in the repo's pre-commit hook and over everything core_backup copies.
# It shipped knowing four shapes, and this machine runs seven AI CLIs whose keys
# live in ordinary JSON config — exactly the kind of file that gets tracked
# without a second thought.
SCAN="$HERE/../bin/scan-secrets.sh"
scan_one() { # <value> -> "caught" | "missed"
  local d; d=$(mktemp -d); mkdir -p "$d/config"; printf '%s\n' "$1" > "$d/config/f.txt"
  if bash "$SCAN" "$d/config" >/dev/null 2>&1; then rm -rf "$d"; echo missed; else rm -rf "$d"; echo caught; fi
}
# The shapes are assembled from pieces on purpose. Written out whole, this file
# contains strings that ARE the thing being tested for: GitHub's own push
# protection rejected the commit that first added them, and it was right to.
# A test fixture that looks like a real credential is a real credential as far
# as every scanner in the chain is concerned.
P_GH="gh""p_"; P_GL="gl""pat-"; P_ANT="sk-""ant-"; P_OAI="sk-""proj-"; P_SK="sk""-"
P_OR="sk-""or-v1-"; P_XAI="xa""i-"; P_HF="h""f_"; P_NPM="np""m_"
P_SLACK="xo""xb-"; P_STRIPE="sk""_live_"; P_AWS="AK""IA"; P_JWT="ey""J"
P_GOOG="AI""za"; P_PEM="BEG""IN OPENSSH PRIVATE KEY"
A32="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
while IFS='|' read -r name value; do
  [[ -n "$name" ]] || continue
  check "$name is caught" "caught" "$(scan_one "$value")"
done <<SHAPES
a GitHub token|${P_GH}abcdefghijklmnopqrstuvwxyz0123456789
a GitLab token|${P_GL}AAAAAAAAAAAAAAAAAAAA
an Anthropic key|${P_ANT}api03-AAAAAAAAAAAAAAAAAAAAAAAA
an OpenAI project key|${P_OAI}${A32}AAAAAAAA
an OpenAI-style key|${P_SK}${A32}AAAA
an OpenRouter key|${P_OR}0123456789abcdef0123456789abcdef
an xAI key|${P_XAI}AAAAAAAAAAAAAAAAAAAAAAAA
a Hugging Face token|${P_HF}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
an npm token|${P_NPM}${A32}AAAAAAAA
a Slack token|${P_SLACK}123456789012-1234567890123-abcdefghijklmnop
a Stripe live key|${P_STRIPE}AAAAAAAAAAAAAAAAAAAAAAAA
a Google API key|${P_GOOG}SyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
an AWS access key id|${P_AWS}IOSFODNN7AAAAAAA
a private key|-----${P_PEM}-----
a JSON Web Token|${P_JWT}hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.${P_JWT}hIjoxLCJiIjoyfQ.abcdefghijklmnop
SHAPES

# The other half matters just as much: a scanner that cries wolf gets disabled,
# and then it is not a scanner at all.
d=$(mktemp -d); mkdir -p "$d/config"
cat > "$d/config/ordinary.json" <<'J'
{ "model": "claude-opus-5",
  "sha": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "url": "https://example.com/sk-something",
  "note": "password = <your password here>" }
J
check_true "ordinary config that looks key-ish is not flagged" bash "$SCAN" "$d/config"
printf 'API_TOKEN=%s\n' "${P_GH}abcdefghijklmnopqrstuvwxyz0123456789" > "$d/config/real.env"
check_false "…but a real one in the same place is"           bash "$SCAN" "$d/config"
rm -rf "$d"

summary
