#!/bin/bash
# The data repository schema: the exact marker, the entries validation, and
# the machine metadata. Everything runs against a fake $HOME and a throwaway
# repo, the way test-core.sh does.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
CLI="$HERE/../bin/replicant"
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

section "a fresh repo carries the exact marker"
core_backup >/dev/null 2>&1
check "schema marker is exact" '{"format":"replicant"}' \
  "$(cat "$REPO_DIR/.replicant/schema.json" 2>/dev/null)"
check "the entry registry starts empty" "{}" \
  "$(jq -c . "$REPO_DIR/.replicant/entries.json" 2>/dev/null)"
check "an empty registry loads as no rows" "" "$(load_entries)"
check "the repo version is recorded, so older clients will not prune it" \
  "$(running_version)" "$(repo_written_by)"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "born ready" >/dev/null 2>&1

section "machine metadata holds three fields and nothing else"
mfile="$REPO_DIR/.replicant/machines/$MACHINE.json"
check_true "this machine recorded itself" test -f "$mfile"
check "…with exactly the three fields" "clientVersion machineId profile" \
  "$(jq -r 'keys | sort | join(" ")' "$mfile" 2>/dev/null)"
check "…for this client version" "$(running_version)" "$(jq -r .clientVersion "$mfile" 2>/dev/null)"
check "…and no path or secret ever lands in it" "0" \
  "$(grep -c -E '/home|/tmp|secret|token|key' "$mfile" || true)"

section "a wrong marker blocks writes"
cp "$REPO_DIR/.replicant/schema.json" "$TMP/schema.keep"
printf '{"format":"other"}\n' > "$REPO_DIR/.replicant/schema.json"
check_false "a backup refuses a foreign marker" core_backup
check_false "tracking refuses it too" core_track "$HOME/.config/hypr/input.lua"
check_false "…and so does a scope change" core_scope hypr/input.lua off
check_false "…and a profile change" core_profile_set laptop
check_false "…and the schema gate" bash "$CORE" schema-gate
check_contains "…naming the expected marker" 'expected {"format":"replicant"}' \
  "$(require_ready_schema 2>&1 || true)"
printf '{not json' > "$REPO_DIR/.replicant/schema.json"
check_false "a corrupt marker blocks writes" core_backup
cp "$TMP/schema.keep" "$REPO_DIR/.replicant/schema.json"
check "a refused write leaves the repo clean" "" \
  "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)"

section "entries validation accepts the good and names the bad"
good="$TMP/good.json"
cat > "$good" <<EOF
{"hypr/input.lua": {"path": "$HOME/.config/hypr/input.lua", "kind": "config", "scope": "shared", "source": "user"},
 "nvim/": {"path": "$HOME/.config/nvim/", "kind": "dir", "scope": "profile", "source": "override"},
 "gone.conf": {"path": "$HOME/.config/gone.conf", "kind": "config", "scope": "shared", "source": "user"}}
EOF
check_true "a sound file validates" validate_entries "$good"
check "…loading three rows, sorted by id" "3" "$(load_entries "$good" | grep -c .)"
check "a path that does not exist is missing, not broken" "0" \
  "$(validate_entries "$good" 2>/dev/null; echo $?)"
bad_scope="$TMP/bad-scope.json"
printf '{"a": {"path": "/x", "kind": "config", "scope": "mine", "source": "user"}}' > "$bad_scope"
check_false "a scope outside shared, profile, off" validate_entries "$bad_scope"
printf '{"a": {"path": "/x", "kind": "config", "scope": "shared", "source": "shipped"}}' > "$TMP/f.json"
check_false "a source outside user, override" validate_entries "$TMP/f.json"
printf '{"a": {"path": "relative/x", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a relative path" validate_entries "$TMP/f.json"
printf '{"a": {"path": "/x/../y", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a path that climbs with .." validate_entries "$TMP/f.json"
printf '{"a": {"path": "/x", "kind": "blob", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a kind outside config, dir" validate_entries "$TMP/f.json"
printf '{"a": {"path": "/x/", "kind": "config", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a file path with a trailing slash" validate_entries "$TMP/f.json"
printf '{"a": {"path": "/x", "kind": "dir", "scope": "shared", "source": "user"}}' > "$TMP/f.json"
check_false "a dir path without one" validate_entries "$TMP/f.json"
printf '[]' > "$TMP/f.json"
check_false "a JSON array is not a registry" validate_entries "$TMP/f.json"
printf '{"a": 42}' > "$TMP/f.json"
check_false "a non-object entry" validate_entries "$TMP/f.json"
printf '{oops' > "$TMP/f.json"
check_false "broken JSON" validate_entries "$TMP/f.json"
check_false "a missing file" validate_entries "$TMP/no-such.json"
printf '{"a": {"path": "/x", "kind": "config", "scope": "shared", "source": "user"}, "b": {"path": "/x", "kind": "config", "scope": "off", "source": "user"}}' > "$TMP/f.json"
check_false "two ids sharing one live path" validate_entries "$TMP/f.json"
printf '{"tree/": {"path": "%s", "kind": "dir", "scope": "shared", "source": "user"}, "leaf": {"path": "%sone.conf", "kind": "config", "scope": "shared", "source": "user"}}' \
  "$HOME/.config/tree/" "$HOME/.config/tree/" > "$TMP/f.json"
check_false "a directory swallowing another entry" validate_entries "$TMP/f.json"
printf '{"a": {"path": "%s/config/x", "kind": "config", "scope": "shared", "source": "user"}}' "$REPO_DIR" > "$TMP/f.json"
check_false "a live path inside the data repo" validate_entries "$TMP/f.json"
mkfifo "$TMP/pipe" 2>/dev/null || true
printf '{"a": {"path": "%s/pipe", "kind": "config", "scope": "shared", "source": "user"}}' "$TMP" > "$TMP/f.json"
check_false "a fifo is not a trackable file" validate_entries "$TMP/f.json"

summary
