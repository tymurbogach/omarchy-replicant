#!/bin/bash
# The v2 data repository schema: the version marker, the write gate, the
# entries validation, and the machine metadata. Everything runs against a
# fake $HOME and a throwaway repo, the way test-core.sh does.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
CLI="$HERE/../bin/omarchy-replicant"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"

mkdir -p "$HOME/.config/hypr" "$OMARCHY_PATH/config/hypr"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'my own input\n'  > "$HOME/.config/hypr/input.lua"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

section "a fresh repo is born v2"
core_backup >/dev/null 2>&1
check "schema marker says version 2" "2" \
  "$(jq -r .dataVersion "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "…and names the coming secret format" "age-pq-v1" \
  "$(jq -r .secretFormat "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "the entry registry starts empty" "{}" \
  "$(jq -c . "$REPO_DIR/.replicant/entries.json" 2>/dev/null)"
check "an empty registry loads as no rows" "" "$(load_v2_entries)"
check "the repo version is recorded, so older clients will not prune it" \
  "$(running_version)" "$(repo_written_by)"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "born v2" >/dev/null 2>&1

section "machine metadata holds four fields and nothing else"
mfile="$REPO_DIR/.replicant/machines/$MACHINE.json"
check_true "this machine recorded itself" test -f "$mfile"
check "…with exactly the four fields" "clientVersion machineId profile schemaVersion" \
  "$(jq -r 'keys | sort | join(" ")' "$mfile" 2>/dev/null)"
check "…at schema version 2" "2" "$(jq -r .schemaVersion "$mfile" 2>/dev/null)"
check "…for this client version" "$(running_version)" "$(jq -r .clientVersion "$mfile" 2>/dev/null)"
check "…and no path or secret ever lands in it" "0" \
  "$(grep -c -E '/home|/tmp|secret|token|key' "$mfile" || true)"

section "unknown and newer formats block writes, not reads"
cp "$REPO_DIR/.replicant/schema.json" "$TMP/schema.keep"
printf '{"dataVersion":99,"secretFormat":"age-pq-v1"}\n' > "$REPO_DIR/.replicant/schema.json"
check_false "a backup refuses a newer format" core_backup
check_false "tracking refuses it too" core_track "$HOME/.config/hypr/input.lua"
check_false "…and so does a scope change" core_scope hypr/input.lua off
check_false "…and a profile change" core_profile_set laptop
check_false "…and the savegame gate" bash "$CORE" schema-gate
check_contains "…naming the update as the way out" "update the plugin" \
  "$(require_writable_schema 2>&1 || true)"
printf '{not json' > "$REPO_DIR/.replicant/schema.json"
check_false "a corrupt schema blocks writes" core_backup
check_contains "…saying the file is unreadable" "unreadable" \
  "$(require_writable_schema 2>&1 || true)"
cp "$TMP/schema.keep" "$REPO_DIR/.replicant/schema.json"
check_true "reads keep answering on any schema" core_status --json --brief --no-fetch
check "a refused write leaves the repo clean" "" \
  "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

section "savegame stops before the commit on a newer format"
# cmd_savegame commits through git directly, so the gate cannot live in a core
# writer alone: without it the failed backup still stops the save (set -e),
# but only past the hooksPath write and the first progress line. The explicit
# gate fails before any of that.
printf '{"dataVersion":99,"secretFormat":"age-pq-v1"}\n' > "$REPO_DIR/.replicant/schema.json"
before=$(git -C "$REPO_DIR" rev-parse HEAD)
out=$("$CLI" savegame --auto --no-push 2>&1); rc=$?
check "savegame refuses a newer format" "1" "$rc"
check_contains "…naming the newer format" "data format 99" "$out"
check "…before doing any work" "0" "$(grep -c "savegame: copying" <<<"$out" || true)"
check "…without committing anything" "$before" "$(git -C "$REPO_DIR" rev-parse HEAD)"
cp "$TMP/schema.keep" "$REPO_DIR/.replicant/schema.json"

section "v1 repos keep working and gain no v2 files"
rm -rf "$REPO_DIR/.replicant"
core_backup >/dev/null 2>&1
check_false "no schema marker appears on a v1 repo" test -f "$REPO_DIR/.replicant/schema.json"
printf 'mine\n' > "$HOME/.config/notes.conf"
check_true "tracking still works there" core_track "$HOME/.config/notes.conf"
check_true "…and untracking too" core_untrack notes.conf
rm -f "$HOME/.config/notes.conf"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "v1 still works" >/dev/null 2>&1 || true

section "entries validation accepts the good and names the bad"
good="$TMP/good.json"
cat > "$good" <<EOF
{"hypr/input.lua": {"path": "$HOME/.config/hypr/input.lua", "kind": "config", "scope": "shared", "source": "user"},
 "nvim/": {"path": "$HOME/.config/nvim/", "kind": "dir", "scope": "profile", "source": "override"},
 "gone.conf": {"path": "$HOME/.config/gone.conf", "kind": "config", "scope": "shared", "source": "user"}}
EOF
check_true "a sound file validates" validate_v2_entries "$good"
check "…loading three rows, sorted by id" "3" "$(load_v2_entries "$good" | grep -c .)"
check "a path that does not exist is missing, not broken" "0" \
  "$(validate_v2_entries "$good" 2>/dev/null; echo $?)"
bad_scope="$TMP/bad-scope.json"
printf '{"a": {"path": "/x", "kind": "config", "scope": "mine", "source": "user"}}' > "$bad_scope"
check_false "a scope outside shared, profile, off" validate_v2_entries "$bad_scope"
check_contains "…naming the rule" "scope is not shared" "$(validate_v2_entries "$bad_scope" 2>&1 || true)"
printf '{"a": {"path": "/x", "kind": "config", "scope": "shared", "source": "shipped"}}' > "$TMP/f.json"
check_false "a source outside user, override" validate_v2_entries "$TMP/f.json"
printf '{"a": {"path": "relative/x", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a relative path" validate_v2_entries "$TMP/f.json"
printf '{"a": {"path": "/x/../y", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a path that climbs with .." validate_v2_entries "$TMP/f.json"
printf '{"a": {"path": "/x", "kind": "blob", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a kind outside config, dir" validate_v2_entries "$TMP/f.json"
printf '{"a": {"path": "/x/", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a file path with a trailing slash" validate_v2_entries "$TMP/f.json"
printf '{"a": {"path": "/x", "kind": "dir", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a dir path without one" validate_v2_entries "$TMP/f.json"
printf '[]' > "$TMP/f.json"
check_false "a JSON array is not a registry" validate_v2_entries "$TMP/f.json"
printf '{"a": 42}' > "$TMP/f.json"
check_false "a non-object entry" validate_v2_entries "$TMP/f.json"
printf '{oops' > "$TMP/f.json"
check_false "broken JSON" validate_v2_entries "$TMP/f.json"
check_false "a missing file" validate_v2_entries "$TMP/no-such.json"
printf '{"a": {"path": "/x", "kind": "config", "scope": "shared", "source": "user"}, "a": {"path": "/y", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a duplicate id" validate_v2_entries "$TMP/f.json"
check_contains "…naming the id" "duplicate id a" "$(validate_v2_entries "$TMP/f.json" 2>&1 || true)"
printf '{"a": {"path": "/x", "kind": "config", "scope": "shared", "source": "user"}, "b": {"path": "/x", "kind": "config", "scope": "off", "source": "user"}}' > "$TMP/f.json"
check_false "two ids sharing one live path" validate_v2_entries "$TMP/f.json"
check_contains "…naming both" "share the live path /x" "$(validate_v2_entries "$TMP/f.json" 2>&1 || true)"
printf '{"tree/": {"path": "%s", "kind": "dir", "scope": "shared", "source": "user"}, "leaf": {"path": "%sone.conf", "kind": "config", "scope": "shared", "source": "user"}}' \
  "$HOME/.config/tree/" "$HOME/.config/tree/" > "$TMP/f.json"
check_false "a directory swallowing another entry" validate_v2_entries "$TMP/f.json"
check_contains "…naming the nesting" "nested tracked roots" "$(validate_v2_entries "$TMP/f.json" 2>&1 || true)"
printf '{"a": {"path": "%s/config/x", "kind": "config", "scope": "shared", "source": "user"}}' "$REPO_DIR" > "$TMP/f.json"
check_false "a live path inside the data repo" validate_v2_entries "$TMP/f.json"
mkfifo "$TMP/pipe" 2>/dev/null || true
printf '{"a": {"path": "%s/pipe", "kind": "config", "scope": "shared", "source": "user"}}' "$TMP" > "$TMP/f.json"
check_false "a fifo is not a trackable file" validate_v2_entries "$TMP/f.json"

summary
