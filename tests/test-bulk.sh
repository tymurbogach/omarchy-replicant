#!/bin/bash
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
CORE="$HERE/../bin/replicant-core.sh"
source "$HERE/lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
REPO="$OMARCHY_REPLICANT_HOME/repo"
mkdir -p "$HOME/.config/hypr" "$OMARCHY_PATH/config/hypr"
printf 'default\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'one\n' > "$HOME/.config/hypr/input.lua"
printf 'two\n' > "$HOME/.config/hypr/hyprlock.conf"
printf 'credential: placeholder\n' > "$HOME/.config/hosts.yml"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
# shellcheck source=bin/replicant-core.sh
source "$CORE" 2>/dev/null
set +e +u
core_backup >/dev/null 2>&1
git -C "$REPO" add -A
git -C "$REPO" commit -q -m initial

section "secret suggestions hide size metadata"
secret_suggestion=$(core_suggest --json | jq -c '.[] | select(.kind == "secret")' | head -n 1)
check "secret suggestion has no size" "0" "$(jq -r '.size' <<<"$secret_suggestion")"
check "secret suggestion has no file count" "0" "$(jq -r '.nfiles' <<<"$secret_suggestion")"

section "bulk save updates selected content"
printf 'saved by bulk\n' > "$HOME/.config/hypr/input.lua"
check_true "selected config is saved" "$CLI" bulk save -- hypr/input.lua
check "bulk save copies the live content" "saved by bulk" "$(git -C "$REPO" show HEAD:config/hypr/input.lua 2>/dev/null)"

section "bulk validates before mutation"
before=$(git -C "$REPO" rev-parse HEAD)
check_false "unknown ID is rejected" "$CLI" bulk scope --scope off --yes -- hypr/input.lua missing/id
check "invalid bulk leaves HEAD unchanged" "$before" "$(git -C "$REPO" rev-parse HEAD)"
check_false "scope off needs confirmation" "$CLI" bulk scope --scope off -- hypr/input.lua

section "bulk scope is one commit"
before=$(git -C "$REPO" rev-parse HEAD)
check_true "scope changes succeed" "$CLI" bulk scope --scope off --yes -- hypr/input.lua hypr/hyprlock.conf
check "both scopes changed" "2" "$(grep -c ' = off$' "$REPO/.replicant-sync")"
check "scope creates one commit" "1" "$(git -C "$REPO" log --format=%s "$before"..HEAD | grep -c '^bulk: scope 2 entries$')"

section "bulk track validates all paths"
printf 'alpha\n' > "$HOME/.config/alpha.conf"
printf 'beta\n' > "$HOME/.config/beta.conf"
before=$(git -C "$REPO" rev-parse HEAD)
check_true "two files track together" "$CLI" bulk track --kind config --yes -- "$HOME/.config/alpha.conf" "$HOME/.config/beta.conf"
check "both user entries exist" "2" "$(grep -Ec 'alpha.conf|beta.conf' "$REPO/.replicant-track")"
check "tracking creates one commit" "1" "$(git -C "$REPO" log --format=%s "$before"..HEAD | grep -c '^bulk: track 2 entries$')"

section "bulk rejects unsafe trees before mutation"
printf '\0binary\n' > "$HOME/.config/binary.conf"
before=$(git -C "$REPO" rev-parse HEAD)
check_false "binary secret is rejected" "$CLI" bulk track --kind secret --yes -- "$HOME/.config/alpha.conf" "$HOME/.config/binary.conf"
check "binary rejection leaves HEAD unchanged" "$before" "$(git -C "$REPO" rev-parse HEAD)"
check "binary rejection leaves tracking unchanged" "2" "$(grep -Ec 'alpha.conf|beta.conf' "$REPO/.replicant-track")"

mkdir -p "$HOME/.config/nested-repo/.git"
before=$(git -C "$REPO" rev-parse HEAD)
check_false "nested repository is rejected" "$CLI" bulk track --kind config --yes -- "$HOME/.config/nested-repo"
check "nested repository leaves HEAD unchanged" "$before" "$(git -C "$REPO" rev-parse HEAD)"

mkdir -p "$HOME/.config/too-many"
for i in $(seq 1 401); do printf '%s\n' "$i" > "$HOME/.config/too-many/$i.conf"; done
before=$(git -C "$REPO" rev-parse HEAD)
check_false "trees over 400 files are rejected" "$CLI" bulk track --kind config --yes -- "$HOME/.config/too-many"
check "large tree rejection leaves HEAD unchanged" "$before" "$(git -C "$REPO" rev-parse HEAD)"

section "bulk handles large text only with explicit consent"
head -c 10485761 /dev/zero | tr '\0' x > "$HOME/.config/large.conf"
before=$(git -C "$REPO" rev-parse HEAD)
check_false "large file needs allow-large" "$CLI" bulk track --kind config --yes -- "$HOME/.config/large.conf"
check "large rejection leaves HEAD unchanged" "$before" "$(git -C "$REPO" rev-parse HEAD)"
check_true "allow-large accepts large text" "$CLI" bulk track --kind config --yes --allow-large -- "$HOME/.config/large.conf"
check "large file is tracked after consent" "1" "$(grep -c 'large.conf' "$REPO/.replicant-track")"

section "bulk blocks plaintext secret conversion"
printf 'secret-conversion-payload\n' > "$HOME/.config/convert-secret.conf"
check_true "conversion source is tracked" "$CLI" bulk track --kind config --yes -- "$HOME/.config/convert-secret.conf"
before=$(git -C "$REPO" rev-parse HEAD)
check_false "v1 conversion is rejected" "$CLI" bulk convert-secret --yes -- convert-secret.conf
check "rejected conversion leaves HEAD unchanged" "$before" "$(git -C "$REPO" rev-parse HEAD)"
check "rejected conversion leaves plaintext out of Git" "0" "$(git -C "$REPO" grep -F -c 'secret-conversion-payload' HEAD 2>/dev/null || echo 0)"

section "bulk untrack is atomic"
before=$(git -C "$REPO" rev-parse HEAD)
check_false "mixed user and shipped entries are rejected" "$CLI" bulk untrack --yes -- alpha.conf hypr/input.lua
check "rejected untrack leaves list unchanged" "2" "$(grep -Ec 'alpha.conf|beta.conf' "$REPO/.replicant-track")"
check_true "user entries untrack together" "$CLI" bulk untrack --yes -- alpha.conf beta.conf
check "untrack creates one commit" "1" "$(git -C "$REPO" log --format=%s "$before"..HEAD | grep -c '^bulk: untrack 2 entries$')"

summary
