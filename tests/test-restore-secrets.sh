#!/bin/bash
# G6 secret restore hardening: privilege before decrypt, same-directory
# atomic install, no plaintext below REPLICANT_HOME, no retained recovery
# copies, no cross-filesystem fallbacks, mode 0600 and owner preserved,
# independent age checks, and no leaks into output, logs, journals or args.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$HERE/../bin/replicant-core.sh"
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
export OUTSIDE="$TMP/outside"

mkdir -p "$HOME/.config/environment.d" "$HOME/.config/hypr" "$OMARCHY_PATH/config/hypr" "$OUTSIDE"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'my own input\n' > "$HOME/.config/hypr/input.lua"

sentinel="G6_SENTINEL_${RANDOM}_$(date +%s%N)"
printf 'TOKEN=%s\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"

# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u

KEYS="$REPLICANT_HOME/keys/identity.txt"

core_backup >/dev/null 2>&1
key_init >/dev/null 2>&1
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "g6 fixture" >/dev/null 2>&1 || true

no_plaintext() {
  local label="$1" path="$2"
  check "$label" "0" "$(grep -R -l -F "$sentinel" -- "$path" 2>/dev/null | wc -l)"
}

section "restore inside HOME is atomic at mode 0600"
printf 'TOKEN=%s_local_edit\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_restore_file env/60-secrets.conf >"$TMP/restore.out" 2>"$TMP/restore.err"
check "restore succeeds" "0" "$?"
check "…puts the vault copy back" "1" "$(grep -c -F "$sentinel" "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null || true)"
check "…at mode 600" "600" "$(stat -c '%a' "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null)"
check "restore stdout is clean" "0" "$(grep -F -c "$sentinel" "$TMP/restore.out" 2>/dev/null || true)"
check "restore stderr is clean" "0" "$(grep -F -c "$sentinel" "$TMP/restore.err" 2>/dev/null || true)"
no_plaintext "no plaintext below REPLICANT_HOME after HOME restore" "$REPLICANT_HOME"
check "no plaintext temp is tracked" "0" "${#_VAULT_TEMPS[@]}"

section "restore outside HOME never stages plaintext below REPLICANT_HOME"
printf 'OUTSIDE=%s_vault\n' "$sentinel" > "$OUTSIDE/app-secret.conf"
chmod 600 "$OUTSIDE/app-secret.conf"
core_track "$OUTSIDE/app-secret.conf" --secret >/dev/null 2>&1
core_backup >/dev/null 2>&1
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "outside secret" >/dev/null 2>&1 || true
printf 'OUTSIDE=%s_local\n' "$sentinel" > "$OUTSIDE/app-secret.conf"
# Privilege stubs that succeed by running the requested command locally.
privbin="$TMP/privbin-ok"
mkdir -p "$privbin"
cat > "$privbin/pkexec" <<'EOF'
#!/bin/bash
# Test-only pkexec: run the requested shell command without privilege.
# Usage in code is: pkexec /bin/sh -c '<script>' _ args...
if [[ "$1" == "/bin/sh" && "$2" == "-c" ]]; then
  script="$3"; shift 3
  /bin/sh -c "$script" "$@"
  exit $?
fi
"$@"
EOF
cat > "$privbin/sudo" <<'EOF'
#!/bin/bash
if [[ "$1" == "-n" ]]; then shift; fi
if [[ "$1" == "true" ]]; then exit 0; fi
if [[ "$1" == "/bin/sh" && "$2" == "-c" ]]; then
  script="$3"; shift 3
  /bin/sh -c "$script" "$@"
  exit $?
fi
"$@"
EOF
chmod +x "$privbin/pkexec" "$privbin/sudo"
old_path="$PATH"
export PATH="$privbin:$PATH"
core_restore_file misc/app-secret.conf >"$TMP/out.out" 2>"$TMP/out.err"
rc=$?
export PATH="$old_path"
check "outside restore succeeds with privilege" "0" "$rc"
check "…puts the vault copy back" "1" "$(grep -c -F "${sentinel}_vault" "$OUTSIDE/app-secret.conf" 2>/dev/null || true)"
check "…without the local edit" "0" "$(grep -c -F "${sentinel}_local" "$OUTSIDE/app-secret.conf" 2>/dev/null || true)"
check "…at mode 600" "600" "$(stat -c '%a' "$OUTSIDE/app-secret.conf" 2>/dev/null)"
no_plaintext "staged dir holds no plaintext" "$REPLICANT_HOME/staged"
no_plaintext "no plaintext below REPLICANT_HOME after outside restore" "$REPLICANT_HOME"

section "failed privilege leaves no plaintext and decrypts nothing recoverable"
chmod 555 "$OUTSIDE"
printf 'OUTSIDE=%s_again\n' "$sentinel" > "$OUTSIDE/app-secret.conf" 2>/dev/null || true
# Force the privilege path to fail even though the dir is shut.
failbin="$TMP/privbin-fail"
mkdir -p "$failbin"
printf '#!/bin/sh\nexit 97\n' > "$failbin/pkexec"
printf '#!/bin/sh\nexit 97\n' > "$failbin/sudo"
chmod +x "$failbin/pkexec" "$failbin/sudo"
export PATH="$failbin:$PATH"
core_restore_file misc/app-secret.conf >"$TMP/priv-fail.out" 2>"$TMP/priv-fail.err"
rc=$?
export PATH="$old_path"
check_false "privilege failure fails the restore" test "$rc" -eq 0
no_plaintext "failed privilege keeps staged clean" "$REPLICANT_HOME/staged"
no_plaintext "failed privilege keeps state clean" "$REPLICANT_HOME"
check "failure output is clean" "0" "$(grep -F -c "$sentinel" "$TMP/priv-fail.out" "$TMP/priv-fail.err" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
chmod 755 "$OUTSIDE"

section "no cross-filesystem fallback for HOME temps"
check "same-directory temp is used" "0" "$(grep -F -c 'mktemp -d -p "$(dirname' "$HERE/../bin/lib/crypto.sh" | awk '{print ($1>0)?0:1}')"
check "no fallback outside the destination filesystem" "0" "$(grep -F -c '|| mktemp -d' "$HERE/../bin/lib/crypto.sh")"

section "tampered index and blob never replace live data"
blob=$(age -d -i "$KEYS" "$REPO_DIR/vault/index.age" 2>/dev/null | jq -r '.secrets[] | select(.id=="env/60-secrets.conf") | .blob')
cp "$REPO_DIR/vault/blobs/$blob.age" "$TMP/blob.keep"
cp "$REPO_DIR/vault/index.age" "$TMP/index.keep"
printf 'TAMPERED' | dd of="$REPO_DIR/vault/blobs/$blob.age" bs=1 seek=100 conv=notrunc status=none 2>/dev/null
check_false "restore refuses a tampered blob" core_restore_file env/60-secrets.conf
check "…leaving live data alone" "0" "$(grep -c TAMPERED "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null || true)"
cp "$TMP/blob.keep" "$REPO_DIR/vault/blobs/$blob.age"
printf 'TAMPERED' | dd of="$REPO_DIR/vault/index.age" bs=1 seek=40 conv=notrunc status=none 2>/dev/null
check_false "restore refuses a tampered index" core_restore_file env/60-secrets.conf
cp "$TMP/index.keep" "$REPO_DIR/vault/index.age"
no_plaintext "tamper failures keep state clean" "$REPLICANT_HOME"

section "Git objects and history hold no plaintext"
check "repo tree is clean" "0" "$(grep -r --exclude-dir=.git -l -F "$sentinel" "$REPO_DIR" 2>/dev/null | grep -c . || true)"
check "repo history is clean" "0" "$(git -C "$REPO_DIR" log -p -- vault 2>/dev/null | grep -c -F "$sentinel" || true)"
check "transaction journals are clean" "0" "$(grep -R -l -F "$sentinel" "$REPLICANT_HOME/transactions" 2>/dev/null | wc -l)"

section "secret values never reach process arguments"
printf 'TOKEN=%s\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >/dev/null 2>&1
printf 'TOKEN=%s_poll\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_restore_file env/60-secrets.conf >/dev/null 2>&1 &
restore_pid=$!
leaked=0
for _ in 1 2 3 4 5 6 7 8; do
  ps -eo args 2>/dev/null > "$TMP/ps.out" || true
  if grep -F -q "$sentinel" "$TMP/ps.out" 2>/dev/null; then
    # The grep above reads a file, so a hit means a live process argument
    # carries the value (the file itself is never a process argument).
    leaked=1; break
  fi
  sleep 0.05
done
wait "$restore_pid" 2>/dev/null || true
check "no process argument carries the secret" "0" "$leaked"

section "write failures before and after temp creation fail clean"
printf 'TOKEN=%s_writefail\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
failmk="$TMP/fail-mktemp"
mkdir -p "$failmk"
printf '#!/bin/bash\nexit 1\n' > "$failmk/mktemp"
chmod +x "$failmk/mktemp"
export PATH="$failmk:$PATH"
check_false "restore fails when the same-directory temp cannot be created" core_restore_file env/60-secrets.conf
export PATH="$old_path"
no_plaintext "temp-creation failure keeps state clean" "$REPLICANT_HOME"
check "…leaving live data alone" "1" "$(grep -c -F "${sentinel}_writefail" "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null || true)"
failchmod="$TMP/fail-chmod"
mkdir -p "$failchmod"
cat > "$failchmod/chmod" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$failchmod/chmod"
export PATH="$failchmod:$PATH"
check_false "restore fails when mode 0600 cannot be applied" core_restore_file env/60-secrets.conf
export PATH="$old_path"
no_plaintext "chmod failure keeps state clean" "$REPLICANT_HOME"

section "interrupted restore leaves no plaintext"
printf 'TOKEN=%s_interrupt\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >/dev/null 2>&1
printf 'TOKEN=%s_interrupted_local\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
slowbin="$TMP/slow-age"
mkdir -p "$slowbin"
real_age=$(command -v age)
cat > "$slowbin/age" <<EOF
#!/bin/bash
sleep 2
exec "$real_age" "\$@"
EOF
chmod +x "$slowbin/age"
export PATH="$slowbin:$PATH"
core_restore_file env/60-secrets.conf >/dev/null 2>&1 &
slow_pid=$!
sleep 0.3
# TERM, not INT: background jobs ignore INT on entry and a non-interactive
# shell cannot trap it, so an INT here would never interrupt. TERM interrupts
# in every context the suites run in.
kill -TERM "$slow_pid" 2>/dev/null || true
wait "$slow_pid" 2>/dev/null || true
export PATH="$old_path"
no_plaintext "interrupted restore keeps state clean" "$REPLICANT_HOME"
vault_arm_traps
check "interrupt traps are armed" "1" "$(trap -p TERM 2>/dev/null | grep -c _vault_clean_temps || true)"
check_contains "restore arms its interrupt traps" "vault_arm_traps" "$(declare -f vault_restore_entry vault_restore_entry_privileged 2>/dev/null)"

section "age and age-keygen are verified independently"
out=$( ( command() { if [[ "${2:-}" == "age" ]]; then return 1; fi; builtin command "$@"; }; crypto_require_age 2>&1 ) || true)
check_contains "missing age names age" "age is not installed" "$out"
out=$( ( command() { if [[ "${2:-}" == "age-keygen" ]]; then return 1; fi; builtin command "$@"; }; crypto_require_keygen 2>&1 ) || true)
check_contains "missing age-keygen names age-keygen" "age-keygen is not installed" "$out"
check_contains "age probe stays independent of keygen" "crypto_require_keygen" "$(declare -f vault_identity_ok 2>/dev/null)"
check_contains "restore checks age on its own" "crypto_require_age" "$(declare -f vault_restore_entry 2>/dev/null)"

section "full restore handles vault secrets without showing contents"
printf 'TOKEN=%s_full\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
core_backup >/dev/null 2>&1
printf 'TOKEN=%s_full_local\n' "$sentinel" > "$HOME/.config/environment.d/60-secrets.conf"
plan=$(plan_for_category secrets 2>/dev/null)
check_contains "the secrets plan names the vault entry" "vault:env/60-secrets.conf" "$plan"
pending=$(restore_pending secrets 2>/dev/null)
check_contains "the secret is pending" "vault:env/60-secrets.conf" "$pending"
preview=$(restore_preview "$pending" 2>&1 || true)
check "the preview shows no plaintext" "0" "$(printf '%s' "$preview" | grep -F -c "$sentinel" || true)"
check_contains "…and says contents are never shown" "never shown" "$preview"
n=$(restore_apply secrets "$pending" 2>/dev/null)
check "the area restore writes one entry" "1" "$n"
check "…putting the vault copy back" "1" "$(grep -c -F "${sentinel}_full" "$HOME/.config/environment.d/60-secrets.conf" 2>/dev/null || true)"
no_plaintext "full restore keeps state clean" "$REPLICANT_HOME"

summary
