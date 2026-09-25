#!/bin/bash
# The secret value is generated at runtime so this suite can inspect failures
# without placing a credential-shaped fixture in the repository.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
source "$HERE/lib.sh"

if ! command -v age-keygen >/dev/null 2>&1; then
  echo "age-keygen is not on PATH — skipped"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'live\n' > "$HOME/.config/hypr/input.lua"
sentinel="LEAK_SENTINEL_${RANDOM}_$(date +%s%N)"
printf 'TOKEN=%s\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"

# shellcheck source=bin/replicant-core.sh
source "$CORE" 2>/dev/null
set +e +u

if ! ( umask 077; age-keygen -pq -o "$TMP/probe" >/dev/null 2>&1 ) \
    || ! grep -q '^# public key: age1pq1' "$TMP/probe" 2>/dev/null; then
  echo "age-keygen does not support -pq — skipped"
  exit 0
fi

core_backup >"$TMP/setup.out" 2>"$TMP/setup.err"
key_init >"$TMP/key.out" 2>"$TMP/key.err"
core_backup >"$TMP/save.out" 2>"$TMP/save.err"

check_no_secret() {
  local label="$1" path="$2"
  check "$label" "0" "$(grep -R -l -F "$sentinel" -- "$path" 2>/dev/null | wc -l)"
}

section "successful secret operations do not disclose plaintext"
check "stdout is clean" "0" "$(grep -F -l "$sentinel" "$TMP/save.out" "$TMP/key.out" 2>/dev/null | wc -l)"
check "stderr is clean" "0" "$(grep -F -l "$sentinel" "$TMP/save.err" "$TMP/key.err" 2>/dev/null | wc -l)"
check_no_secret "the v2 repository stores no plaintext" "$REPO_DIR"
check_no_secret "transaction storage is clean" "$REPLICANT_HOME/transactions"
check_no_secret "staged storage is clean" "$REPLICANT_HOME/staged"

section "encryption failure logs stay clean"
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/age" <<'EOF'
#!/bin/sh
echo 'encryption failed' >&2
exit 23
EOF
chmod +x "$TMP/fakebin/age"
old_path="$PATH"
export PATH="$TMP/fakebin:$PATH"
printf 'TOKEN=%s_changed\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
rc=0
core_backup >"$TMP/fail.out" 2>"$TMP/fail.err" || rc=$?
export PATH="$old_path"
check "the injected encryption failure is reported" "1" "$rc"
check "failure stdout is clean" "0" "$(grep -F -c "$sentinel" "$TMP/fail.out" 2>/dev/null || true)"
check "failure stderr is clean" "0" "$(grep -F -c "$sentinel" "$TMP/fail.err" 2>/dev/null || true)"
check_no_secret "failed transaction storage is clean" "$REPLICANT_HOME"

section "restore operations do not disclose plaintext"
printf 'TOKEN=%s\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >"$TMP/resave.out" 2>"$TMP/resave.err"
printf 'TOKEN=%s_local\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_restore_file env/60-secrets.conf >"$TMP/restore.out" 2>"$TMP/restore.err"
check "restore stdout is clean" "0" "$(grep -F -c "$sentinel" "$TMP/restore.out" 2>/dev/null || true)"
check "restore stderr is clean" "0" "$(grep -F -c "$sentinel" "$TMP/restore.err" 2>/dev/null || true)"
check_no_secret "restore keeps state clean" "$REPLICANT_HOME"
check_no_secret "restore keeps the repo clean" "$REPO_DIR"
check "restore history is clean" "0" "$(git -C "$REPO_DIR" log -p -- vault 2>/dev/null | grep -c -F "$sentinel" || true)"
check "no journal carries the value" "0" "$(grep -R -l -F "$sentinel" "$REPLICANT_HOME/transactions" "$REPLICANT_HOME/staged" 2>/dev/null | wc -l)"

section "failed restore operations stay clean"
blob=$(age -d -i "$REPLICANT_HOME/keys/identity.txt" "$REPO_DIR/vault/index.age" 2>/dev/null | jq -r '.secrets[] | select(.id=="env/60-secrets.conf") | .blob')
cp "$REPO_DIR/vault/blobs/$blob.age" "$TMP/blob.keep"
printf 'TAMPERED' | dd of="$REPO_DIR/vault/blobs/$blob.age" bs=1 seek=100 conv=notrunc status=none 2>/dev/null
core_restore_file env/60-secrets.conf >"$TMP/tamper.out" 2>"$TMP/tamper.err" || true
check "tamper stdout is clean" "0" "$(grep -F -c "$sentinel" "$TMP/tamper.out" 2>/dev/null || true)"
check "tamper stderr is clean" "0" "$(grep -F -c "$sentinel" "$TMP/tamper.err" 2>/dev/null || true)"
check_no_secret "tamper failure keeps state clean" "$REPLICANT_HOME"
cp "$TMP/blob.keep" "$REPO_DIR/vault/blobs/$blob.age"

summary
