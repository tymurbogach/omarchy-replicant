#!/bin/bash
# The whole point of this plugin, run end to end: a desktop saves, a laptop
# clones, and the laptop ends up feeling like home without inheriting the
# things that were only ever true of the desktop.
#
# Every other suite tests a function. This one tests the journey, because the
# parts can each be right while the trip is broken — a file saved to one path
# and restored from another passes every unit test either side of the gap.
#
# Two fake machines with their own $HOME and their own replicant home, and a
# bare repo standing in for GitHub. Nothing here can reach the network.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export OMARCHY_PATH="$TMP/omarchy"
mkdir -p "$OMARCHY_PATH/config/hypr" "$OMARCHY_PATH/default/bash"
printf 'default input\n'  > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'default bashrc\n' > "$OMARCHY_PATH/default/bash/bashrc"

# The stand-in for GitHub.
git init -q --bare -b main "$TMP/origin.git"   # -b main: a bare repo defaulting to
                                              # master leaves the clone checking out
                                              # nothing, which is its own bug (see
                                              # cmd_clone) and not what this tests.

# on <machine> <command...> — run the CLI as that machine.
on() {
  local m="$1"; shift
  HOME="$TMP/$m/home" \
  OMARCHY_REPLICANT_HOME="$TMP/$m/replicant" \
  REPLICANT_MACHINE="$m" \
  REPLICANT_PROFILE="${PROFILE_OF[$m]}" \
    "$CLI" "$@" 2>&1
}
declare -A PROFILE_OF=([desktop]=desktop [laptop]=laptop)

# ── the desktop, with a setup worth replicating ──────────────────────────────
D="$TMP/desktop/home"
mkdir -p "$D/.config/hypr" "$D/.config/nvim/lua" "$D/.local/bin" \
         "$D/.config/environment.d" "$D/.ssh" "$D/.config/omarchy"
printf 'my own input\n'                   > "$D/.config/hypr/input.lua"
printf 'my own bashrc\n'                  > "$D/.bashrc"
printf 'monitor = DP-1, 3840x2160, auto\n' > "$D/.config/hypr/monitors.lua"
printf 'require("plugins")\n'             > "$D/.config/nvim/init.lua"
printf 'return { "a" }\n'                 > "$D/.config/nvim/lua/plugins.lua"
printf '#!/bin/bash\necho mine\n'         > "$D/.local/bin/my-script"; chmod +x "$D/.local/bin/my-script"
printf 'API_TOKEN=sk-desktop-secret\n'    > "$D/.config/environment.d/60-secrets.conf"
printf '{ "idle": { "lock": 600 } }\n'    > "$D/.config/omarchy/shell.json"
# A directory that is really a git clone is inventoried, never copied — the same
# shape as a theme, small enough to keep in a test.
mkdir -p "$D/.config/omarchy/themes/mine"
git init -q "$D/.config/omarchy/themes/mine"
git -C "$D/.config/omarchy/themes/mine" remote add origin https://example.com/omarchy-mine-theme

section "the desktop saves"
on desktop init >/dev/null 2>&1
on desktop track "$D/.local/bin/my-script" >/dev/null 2>&1
DREPO="$TMP/desktop/replicant/repo"
git -C "$DREPO" config user.email t@example.com
git -C "$DREPO" config user.name Test
git -C "$DREPO" remote add origin "$TMP/origin.git" 2>/dev/null
on desktop backup >/dev/null 2>&1
git -C "$DREPO" add -A >/dev/null 2>&1
git -C "$DREPO" commit -q -m "desktop" >/dev/null 2>&1
git -C "$DREPO" push -q -u origin HEAD:main >/dev/null 2>&1

check_true "a shared file is in the repo"        test -f "$DREPO/config/hypr/input.lua"
check_true "a tracked directory is, whole"       test -f "$DREPO/config/nvim/lua/plugins.lua"
check_true "a file the user added is"            test -f "$DREPO/config/bin/my-script"
check_true "the decision to track it travels"    test -f "$DREPO/.replicant-track"
check_true "a secret is, under secrets/"         test -f "$DREPO/secrets/env/60-secrets.conf"
# monitors.lua describes the screens plugged into THIS box. It is not switched
# off — it is kept per profile, so both machines get a backup of their own.
check_true "the monitor layout is kept per profile" \
  test -f "$DREPO/profiles/desktop/config/hypr/monitors.lua"
check "…and not in the shared tree" "0" \
  "$(ls "$DREPO/config/hypr/monitors.lua" 2>/dev/null | wc -l)"
check_contains "the theme is recorded as a URL, not copied" \
  "https://example.com/omarchy-mine-theme" "$(cat "$DREPO/state/desktop/omarchy-themes.txt" 2>/dev/null)"
check "…and no theme file was copied into the repo" "0" \
  "$(find "$DREPO/config" -path '*themes*' 2>/dev/null | wc -l)"

section "savegame, the button the panel actually presses"
# Nothing exercised this command. Every suite reached for `backup` and drove
# git by hand, so the commit step savegame does on its own was never run — and
# a variable named there that belongs to the core, not the CLI, killed it under
# `set -u` after it had copied every file in. A save that does the work and
# then fails is the worst shape this tool has.
# The inventory only commits when the inventory actually changed — it carries
# no timestamp of its own any more — so give it something real to record.
mkdir -p "$D/.config/omarchy/themes/second"
git init -q "$D/.config/omarchy/themes/second"
git -C "$D/.config/omarchy/themes/second" remote add origin https://example.com/omarchy-second-theme
out=$(on desktop savegame --no-push; echo "rc=$?")
check_contains "it finishes"            "rc=0" "$out"
check_true "…and does not die on an unbound variable" \
  bash -c '! grep -q "unbound variable" <<<"$0"' "$out"
check_contains "…and commits the inventory"  "Inventory commit" "$out"
# Which machine's inventory moved is the whole content of the line in a repo
# two machines write to, and the date column beside it already says when.
check_true "…naming the machine, not the date" \
  bash -c 'git -C "$1" log -1 --pretty=%s -- state/ | grep -q "desktop inventory"' _ "$DREPO"
# And saving again, with nothing changed, must record nothing. The inventory
# used to open with the current time, so every save committed "state: desktop
# inventory (packages, plugins, themes)" having inventoried no change at all —
# the panel's Last save showed one of those instead of the file the user saved,
# and two machines on one repo diverged whenever either of them pressed Save.
idle_head=$(git -C "$DREPO" rev-parse HEAD)
out=$(on desktop savegame --no-push)
check "saving twice in a row commits once" "$idle_head" "$(git -C "$DREPO" rev-parse HEAD)"
check_contains "…and says so plainly" "Nothing to save" "$out"

section "pressing Save has to finish the job"
# The panel's Save button ran bare `savegame`, and bare savegame deliberately
# leaves config and secrets copied-in-but-UNCOMMITTED so a human can write one
# commit per change explaining why. The panel has nowhere to type that why, so
# from the panel the primary button copied files in, pushed the inventory, and
# left every badge exactly as red as it was. The user pressed Track on a secret,
# pressed Save, and the secret was still sitting uncommitted afterwards.
printf 'my own input, edited\n' > "$D/.config/hypr/input.lua"
out=$(on desktop savegame --auto)
check_true "the edit is committed, not merely copied in" \
  bash -c '! git -C "$1" status --porcelain -- config/ secrets/ | grep -q .' _ "$DREPO"
check_true "…and it reached the remote"  \
  bash -c 'git -C "$1" diff --quiet origin/main HEAD' _ "$DREPO"
# What a button is able to know is WHAT changed, never why. Saying so beats
# both silence and a date, which the row already carries in its own column.
check_contains "…under a subject naming what changed" "hypr/input.lua" \
  "$(git -C "$DREPO" log -1 --pretty=%s)"
# -m is a subject a person wrote; --auto is only ever the fallback for a caller
# that cannot ask.
printf 'my own input, again\n' > "$D/.config/hypr/input.lua"
on desktop savegame --auto -m "config: raise the repeat rate" >/dev/null 2>&1
check "an explicit -m still wins over --auto" "config: raise the repeat rate" \
  "$(git -C "$DREPO" log -1 --pretty=%s)"

section "push means push"
# It used to mean "copy everything in, stage the lot with add -A, invent a
# subject out of the date, commit, push" — a second, worse savegame that
# nothing called, and that took its arguments as the commit message, which is
# how a commit titled "--help" once reached GitHub.
printf 'not saved by push\n' > "$D/.config/hypr/input.lua"
on desktop backup >/dev/null 2>&1          # copied into the repo, committed nowhere
before_head=$(git -C "$DREPO" rev-parse HEAD)
out=$(on desktop push)
check "push commits nothing on its own" "$before_head" "$(git -C "$DREPO" rev-parse HEAD)"
# "nothing to push" and "nothing to do" are not the same sentence, and the
# difference is the whole reason someone is reading this command's output.
check_contains "…and says there is work it did not take on" "uncommitted changes" "$out"
check_true "…leaving it for savegame" \
  bash -c 'git -C "$1" status --porcelain -- config/ | grep -q .' _ "$DREPO"
on desktop savegame --auto --no-push >/dev/null 2>&1
out=$(on desktop push)
check_contains "…and it does push what is already committed" "commit(s) to" "$out"
check_contains "…saying so out loud" "Pushing" "$out"
check_true "…which really reached the remote" \
  bash -c 'git -C "$1" diff --quiet origin/main HEAD' _ "$DREPO"

# Put the desktop back the way the rest of the journey expects to find it.
printf 'my own input\n' > "$D/.config/hypr/input.lua"
on desktop savegame --auto >/dev/null 2>&1

# ── the laptop, which has never seen any of this ─────────────────────────────
L="$TMP/laptop/home"
mkdir -p "$L/.config/hypr" "$L/.local/bin" "$L/.config/omarchy"
printf 'monitor = eDP-1, 1920x1200, auto\n' > "$L/.config/hypr/monitors.lua"
LAPTOP_MONITORS=$(cat "$L/.config/hypr/monitors.lua")

section "the laptop clones and looks before it leaps"
on laptop clone "$TMP/origin.git" >/dev/null 2>&1
LREPO="$TMP/laptop/replicant/repo"
check_true "the clone arrived" test -d "$LREPO/.git"
before=$(hash_tree "$L")
out=$(on laptop restore --dry-run)
check "a dry run writes nothing at all" "$before" "$(hash_tree "$L")"
check_contains "…and says what it would do" "dry-run" "$out"

section "the laptop restores"
on laptop restore --apply --all --yes >/dev/null 2>&1

check_true "a shared file arrived"            test -f "$L/.config/hypr/input.lua"
check "…with the desktop's content" "my own input" "$(cat "$L/.config/hypr/input.lua" 2>/dev/null)"
check_true "the whole directory arrived"      test -f "$L/.config/nvim/lua/plugins.lua"
# The file the user added to their own list. If .replicant-track did not travel,
# or the laptop ignored it, this is the row that silently does not come back.
check_true "the file the user added arrived"  test -f "$L/.local/bin/my-script"
check "…still executable"  "755" "$(stat -c%a "$L/.local/bin/my-script" 2>/dev/null)"
check_true "the secret arrived"               test -f "$L/.config/environment.d/60-secrets.conf"
check "…at mode 600, not 644" "600" "$(stat -c%a "$L/.config/environment.d/60-secrets.conf" 2>/dev/null)"
# The whole reason profiles exist: the desktop's 4K layout must not land on a
# laptop panel, and the laptop's own must survive being restored onto.
check "the laptop keeps its OWN monitor layout" "$LAPTOP_MONITORS" \
  "$(cat "$L/.config/hypr/monitors.lua" 2>/dev/null)"

section "and back the other way"
printf 'return { "a", "b" }\n' > "$L/.config/nvim/lua/plugins.lua"
on laptop backup >/dev/null 2>&1
git -C "$LREPO" config user.email t@example.com
git -C "$LREPO" config user.name Test
git -C "$LREPO" add -A >/dev/null 2>&1
git -C "$LREPO" commit -q -m "laptop" >/dev/null 2>&1
git -C "$LREPO" push -q origin HEAD:main >/dev/null 2>&1
check_true "the laptop's edit reached the repo" \
  grep -q '"b"' "$LREPO/config/nvim/lua/plugins.lua"
# Two machines, one repo: neither may overwrite the other's inventory.
check_true "the desktop's inventory is still there" test -d "$LREPO/state/desktop"
check_true "…alongside the laptop's own"            test -d "$LREPO/state/laptop"
check_true "…and so is the desktop's profile tree"  \
  test -f "$LREPO/profiles/desktop/config/hypr/monitors.lua"

on desktop pull >/dev/null 2>&1
on desktop restore --apply --only development --yes >/dev/null 2>&1
check_true "the desktop picked the edit up" \
  grep -q '"b"' "$D/.config/nvim/lua/plugins.lua"

summary
