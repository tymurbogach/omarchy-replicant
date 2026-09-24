#!/bin/bash
# Encrypted secrets: the shared age identity, the vault, and every flow that
# touches them. Keys are generated at runtime with age-keygen, never stored in
# fixtures: a fixture that looks like a credential is one to every scanner.
# Everything runs against a fake $HOME and a throwaway repo.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
CLI="$HERE/../bin/omarchy-replicant"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "age or age-keygen is not on PATH — skipped (omarchy pkg add age)"
  exit 0
fi
probe_dir=$(mktemp -d); trap 'rm -rf "$TMP" "$probe_dir"' EXIT
if ! ( umask 077; age-keygen -pq -o "$probe_dir/key" >/dev/null 2>&1 ) \
    || ! grep -q '^# public key: age1pq1' "$probe_dir/key" 2>/dev/null; then
  echo "age-keygen here cannot make post-quantum keys — skipped (upgrade age past 1.3)"
  exit 0
fi
rm -rf -- "$probe_dir"

TMP=$(mktemp -d)
export HOME="$TMP/home"
export OMARCHY_PATH="$TMP/omarchy"
export OMARCHY_REPLICANT_HOME="$TMP/replicant"

mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default input\n'      > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'my own input\n'       > "$HOME/.config/hypr/input.lua"
printf 'FIRST=crypto-fixture-alpha\n' > "$HOME/.config/environment.d/60-secrets.conf"
printf 'notes-body-crypto-beta\n'     > "$HOME/.config/notes-private.conf"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

KEYS="$REPLICANT_HOME/keys/identity.txt"
RECIPIENT="$REPO_DIR/.replicant/recipient.txt"

section "key init makes one shared identity"
core_backup >/dev/null 2>&1
check "a fresh repo is version 3" "3" "$(repo_data_version)"
check_true "key init works" key_init
check_true "the identity exists" test -f "$KEYS"
check "…at mode 600" "600" "$(stat -c '%a' "$KEYS" 2>/dev/null)"
check "…the keys dir at 700" "700" "$(stat -c '%a' "$REPLICANT_HOME/keys" 2>/dev/null)"
check "…and the recipient is post-quantum" "age1pq1" "$(head -c 7 "$RECIPIENT" 2>/dev/null)"
check "…matching the identity" "$(age-keygen -y "$KEYS" 2>/dev/null)" "$(cat "$RECIPIENT" 2>/dev/null)"
check_false "a second init refuses to overwrite" key_init
check_contains "…saying to rotate instead" "rotate" "$(key_init 2>&1 || true)"

section "key init refuses a version 1 repo"
mv "$REPO_DIR/.replicant/schema.json" "$TMP/schema.keep"
check_false "no encrypted secrets on a plaintext layout" key_init
check_contains "…naming the reason" "version 1" "$(key_init 2>&1 || true)"
mv "$TMP/schema.keep" "$REPO_DIR/.replicant/schema.json"

section "key export backs up outside the repo"
check_false "not into the data repo" key_export "$REPO_DIR/key.txt"
check_false "not into the state dir" key_export "$REPLICANT_HOME/key.txt"
check_false "not a relative path" key_export relative/key.txt
check_true "but outside both" key_export "$TMP/key-backup.txt"
check "…at mode 600" "600" "$(stat -c '%a' "$TMP/key-backup.txt" 2>/dev/null)"
check "…verifying by recipient" "$(age-keygen -y "$KEYS" 2>/dev/null)" \
  "$(age-keygen -y "$TMP/key-backup.txt" 2>/dev/null)"

section "key import adopts the shared identity"
mv "$KEYS" "$TMP/identity.keep"
check_false "status without a key names the remedy" key_status
check_contains "…which is import" "key import" "$(key_status 2>&1 || true)"
age-keygen -pq -o "$TMP/other.txt" 2>/dev/null
chmod 600 "$TMP/other.txt"
check_false "a foreign identity does not match" key_import "$TMP/other.txt"
check_contains "…naming the shared one" "shared" "$(key_import "$TMP/other.txt" 2>&1 || true)"
printf 'not a key\n' > "$TMP/junk.txt"
check_false "garbage is not a key" key_import "$TMP/junk.txt"
check_true "the backup imports" key_import "$TMP/key-backup.txt"
check "…at mode 600" "600" "$(stat -c '%a' "$KEYS" 2>/dev/null)"
check_contains "status is ready" "ready" "$(key_status 2>&1)"
check_contains "…through the CLI too" "ready" "$("$CLI" key status 2>&1)"
cp "$KEYS" "$TMP/identity.good"
printf 'malformed identity\n' > "$KEYS"
chmod 600 "$KEYS"
check_false "a malformed identity is rejected" key_status
check_contains "…with an import remedy" "re-import" "$(key_status 2>&1 || true)"
cp "$TMP/identity.good" "$KEYS"
chmod 000 "$KEYS"
check_false "an unreadable identity is rejected" key_status
chmod 600 "$KEYS"
check_contains "…without exposing the secret" "key" "$(key_status 2>&1 || true)"

section "saving encrypts, resaving preserves"
core_track "$HOME/.config/notes-private.conf" --secret >/dev/null 2>&1
core_backup >/dev/null 2>&1
dec_index() { age -d -i "$KEYS" "$REPO_DIR/vault/index.age" 2>/dev/null; }
blob=$(dec_index | jq -r '.secrets[] | select(.id=="env/60-secrets.conf") | .blob')
check "the index names path, scope and blob" "env/60-secrets.conf" \
  "$(dec_index | jq -r '.secrets[] | select(.id=="env/60-secrets.conf") | "\(.id)"')"
check "…with an opaque 128-bit blob id" "0" \
  "$(dec_index | jq -r '.secrets[].blob' | grep -cvE '^[0-9a-f]{32}$' || true)"
check_true "the blob file exists" test -f "$REPO_DIR/vault/blobs/$blob.age"
check "…and decrypts to the live file" "0" \
  "$(age -d -i "$KEYS" "$REPO_DIR/vault/blobs/$blob.age" 2>/dev/null | cmp -s - "$HOME/.config/environment.d/60-secrets.conf"; echo $?)"
sha_before=$(sha256sum "$REPO_DIR/vault/blobs/"*.age "$REPO_DIR/vault/index.age" | sha256sum | cut -d' ' -f1)
core_backup >/dev/null 2>&1
check "an unchanged secret keeps its ciphertext" "$sha_before" \
  "$(sha256sum "$REPO_DIR/vault/blobs/"*.age "$REPO_DIR/vault/index.age" | sha256sum | cut -d' ' -f1)"
printf 'FIRST=crypto-fixture-gamma\n' > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >/dev/null 2>&1
check "…and a changed one re-encrypts" "1" \
  "$(age -d -i "$KEYS" "$REPO_DIR/vault/blobs/$blob.age" 2>/dev/null | grep -c crypto-fixture-gamma || true)"
check "…under the same blob id" "$blob" \
  "$(dec_index | jq -r '.secrets[] | select(.id=="env/60-secrets.conf") | .blob')"
check "…with no stray blob" "0" \
  "$(comm -23 <(ls "$REPO_DIR/vault/blobs/" 2>/dev/null | sed 's/.age$//' | sort) <(dec_index | jq -r '.secrets[].blob' | sort) | grep -c . || true)"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "secrets in the vault" >/dev/null 2>&1

section "no plaintext where only ciphertext belongs"
check "the repo holds no live content" "0" \
  "$(grep -r --exclude-dir=.git -l 'crypto-fixture' "$REPO_DIR" 2>/dev/null | grep -c . || true)"
check "…nor does its history" "0" \
  "$(git -C "$REPO_DIR" log -p -- vault 2>/dev/null | grep -c 'crypto-fixture' || true)"
check "…nor the state dir" "0" \
  "$(grep -r -l 'crypto-fixture' "$REPLICANT_HOME/keys" "$REPLICANT_HOME/staged" 2>/dev/null | grep -c . || true)"
check "the identity never lands in the repo" "" \
  "$(find "$REPO_DIR" -name 'identity*' 2>/dev/null | head -n1)"
check "no plaintext temp is left behind" "0" "${#_VAULT_TEMPS[@]}"
out=$(core_status --json --no-fetch 2>/dev/null)
check "…nor in status output" "0" "$(printf '%s' "$out" | grep -c 'crypto-fixture' || true)"

section "status names locked without the key"
mv "$KEYS" "$TMP/identity.keep"
row=$(build_secrets_json | jq -c '[.[] | select(.id=="env/60-secrets.conf")][0]')
check "the row reads locked" "locked" "$(jq -r .sync_state <<<"$row")"
check "…flagged" "true" "$(jq -r .locked <<<"$row")"
check "…with no variable names" "0" "$(jq -r '.vars | length' <<<"$row")"
check "…and no content anywhere" "0" "$(build_secrets_json | grep -c 'crypto-fixture' || true)"
check_false "saving refuses without a key" core_backup
check_contains "…naming the import" "key import" "$(core_backup 2>&1 || true)"
check_false "…through the CLI too" "$CLI" key status
mv "$TMP/identity.keep" "$KEYS"
check "the row unlocks with the key back" "unpushed" \
  "$(build_secrets_json | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].sync_state')"

section "restore roundtrips with a backup"
printf 'FIRST=crypto-fixture-local-edit\n' > "$HOME/.config/environment.d/60-secrets.conf"
core_restore_file env/60-secrets.conf >/dev/null 2>&1
check "restore puts the vault copy back" "1" \
  "$(grep -c crypto-fixture-gamma "$HOME/.config/environment.d/60-secrets.conf" || true)"
bak=$(find "$HOME/.config/environment.d" -maxdepth 1 -name '60-secrets.conf.bak.*' | head -n1)
check "…keeping what was there as a backup" "1" "$(grep -c crypto-fixture-local-edit "$bak" 2>/dev/null || true)"

section "a tampered blob never replaces live data"
blob=$(age -d -i "$KEYS" "$REPO_DIR/vault/index.age" 2>/dev/null | jq -r '.secrets[] | select(.id=="env/60-secrets.conf") | .blob')
cp "$REPO_DIR/vault/blobs/$blob.age" "$TMP/blob.keep"
printf 'TAMPERED' | dd of="$REPO_DIR/vault/blobs/$blob.age" bs=1 seek=100 conv=notrunc status=none 2>/dev/null
check_false "restore refuses the tamper" core_restore_file env/60-secrets.conf
check "…leaving live data alone" "0" \
  "$(grep -c TAMPERED "$HOME/.config/environment.d/60-secrets.conf" || true)"
check "status asks for a save, never for calm" "unsaved" \
  "$(build_secrets_json | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].sync_state')"
core_backup >/dev/null 2>&1
check "…and the next save heals from live" "1" \
  "$(age -d -i "$KEYS" "$REPO_DIR/vault/blobs/$blob.age" 2>/dev/null | grep -c crypto-fixture-gamma || true)"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "healed tamper" >/dev/null 2>&1 || true
check "…back to unpushed once committed" "unpushed" \
  "$(build_secrets_json | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].sync_state')"

section "rotate replaces the key"
cp "$KEYS" "$TMP/identity.old"
ids_before=$(find "$REPO_DIR/vault/blobs" -maxdepth 1 -name '*.age' -printf '%f\n' | sort | tr '\n' ' ')
rec_before=$(cat "$RECIPIENT")
check_true "rotate works" key_rotate
check "…with a new recipient" "0" "$(grep -cF "$rec_before" "$RECIPIENT" || true)"
check "…keeping the blob ids" "$ids_before" \
  "$(find "$REPO_DIR/vault/blobs" -maxdepth 1 -name '*.age' -printf '%f\n' | sort | tr '\n' ' ')"
printf 'FIRST=post-rotate-edit\n' > "$HOME/.config/environment.d/60-secrets.conf"
core_restore_file env/60-secrets.conf >/dev/null 2>&1
check "…and the secret still decrypts" "1" \
  "$(grep -c crypto-fixture-gamma "$HOME/.config/environment.d/60-secrets.conf" || true)"
cp "$TMP/identity.old" "$TMP/identity.test"
mv "$KEYS" "$TMP/identity.new"
cp "$TMP/identity.test" "$KEYS"
check_false "the old key no longer matches" key_status
check_false "…and cannot save" core_backup
mv "$TMP/identity.new" "$KEYS"
check_true "the backup re-exports after rotation" key_export "$TMP/key-backup.txt"
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "rotated" >/dev/null 2>&1 || true

section "a second machine joins with import and restore"
M2="$TMP/m2"
mkdir -p "$M2/home/.config/environment.d"
git clone -q "$REPO_DIR" "$M2/replicant/repo" 2>/dev/null
out=$(HOME="$M2/home" OMARCHY_REPLICANT_HOME="$M2/replicant" bash -c '
  source "$1" 2>/dev/null; set +e +u
  key_import "'"$TMP"'/key-backup.txt" >/dev/null 2>&1 || { echo "IMPORT-FAILED"; exit 0; }
  printf "IMPORT-OK\n"
  ' _ "$CORE" 2>&1)
check_contains "the shared identity imports there" "IMPORT-OK" "$out"
out2=$(HOME="$M2/home" OMARCHY_REPLICANT_HOME="$M2/replicant" bash -c '
  source "$1" 2>/dev/null; set +e +u
  key_import "'"$TMP"'/key-backup.txt" >/dev/null 2>&1
  core_restore_file env/60-secrets.conf >/dev/null 2>&1
  cat "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null
  ' _ "$CORE" 2>&1)
check_contains "…and the secret restores from the vault" "crypto-fixture-gamma" "$out2"
check "…with no plaintext temp left on that machine" "" \
  "$(find "$M2" -name '*.bak.*' -o -name 'plain' 2>/dev/null | head -n1)"

section "untrack and forget drop vault entries"
dec() { age -d -i "$KEYS" "$REPO_DIR/vault/index.age" 2>/dev/null; }
n_before=$(dec | jq '.secrets | length')
core_untrack notes-private.conf >/dev/null 2>&1
check "untracking drops the index row" "$(( n_before - 1 ))" "$(dec | jq '.secrets | length')"
check "…and the blob file" "0" \
  "$(dec | jq -r '.secrets[].blob' | while read -r b; do test -f "$REPO_DIR/vault/blobs/$b.age" || echo "gone"; done | grep -c gone || true)"
rm -f "$HOME/.config/environment.d/60-secrets.conf"
core_forget env/60-secrets.conf >/dev/null 2>&1
check "forgetting drops the shipped secret too" "0" "$(dec | jq '.secrets | length')"
printf 'FIRST=crypto-fixture-gamma\n' > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "forgetting drops vault entries" >/dev/null 2>&1 || true

section "purge names the key before removing it"
check_contains "purge --repo warns about the key" "secret key" \
  "$("$CLI" purge --repo 2>&1)"
check "…and a plain purge keeps it" "0" \
  "$("$CLI" purge 2>&1 | grep -c 'secret key' || true)"

section "phase B: no var names, no defined-secrets, locked in brief, doctor"
out=$(build_secrets_json)
check "v2 status leaks no live content" "0" "$(printf '%s' "$out" | grep -c 'crypto-fixture' || true)"
check "v2 vars arrays are empty" "0" "$(printf '%s' "$out" | jq '[.[].vars | length] | add // 0')"
check "…but the env count stays" "1" "$(printf '%s' "$out" | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].var_count')"
check "no defined-secrets.txt is written" "0" "$(find "$REPO_DIR/state" -name 'defined-secrets.txt' 2>/dev/null | grep -c . || true)"
printf 'LEFTOVER=1\n' > "$STATE_DIR/defined-secrets.txt"
core_backup >/dev/null 2>&1
check "…and a backup sweeps a leftover away" "0" "$(find "$REPO_DIR/state" -name 'defined-secrets.txt' 2>/dev/null | grep -c . || true)"
check "brief carries locked 0 with the key" "0" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .locked)"
check "count_changes prints four fields" "4" \
  "$(count_changes 2>/dev/null | wc -w)"
check "…with none locked" "0" \
  "$(count_changes 2>/dev/null | awk '{print $3}')"
mv "$KEYS" "$TMP/identity.keep"
check "brief counts locked without the key" "1" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .locked)"
check "…and count_changes agrees" "1" \
  "$(count_changes 2>/dev/null | awk '{print $3}')"
check "full status marks the row locked" "locked" \
  "$(build_secrets_json 2>/dev/null | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].sync_state')"
check "a locked row carries no count either" "0" \
  "$(build_secrets_json 2>/dev/null | jq -r '[.[] | select(.id=="env/60-secrets.conf")][0].var_count')"
check_contains "doctor names the import remedy" "key import" \
  "$("$CLI" doctor 2>&1)"
check_contains "…with the exact command" "omarchy-replicant key import" \
  "$("$CLI" doctor 2>&1)"
check "remediation points at import when keyless" "omarchy-replicant key import <source>" \
  "$(key_remediation 2>/dev/null)"
mv "$TMP/identity.keep" "$KEYS"
check "brief is back to 0 with the key" "0" \
  "$(core_status --json --brief --no-fetch 2>/dev/null | jq -r .locked)"
check_contains "doctor reports the key ready" "secret key ready" \
  "$("$CLI" doctor 2>&1)"
check "remediation is a no-op when ready" "omarchy-replicant key status" \
  "$(key_remediation 2>/dev/null)"

section "the hook lets vault ciphertext through"
printf 'FIRST=crypto-fixture-delta\n' > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A vault/ >/dev/null 2>&1
check_true "a commit of ciphertext passes the hook" git -C "$REPO_DIR" commit -qm "vault through the hook"

summary
