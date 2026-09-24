#!/bin/bash
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
CORE="$HERE/../bin/replicant-core.sh"
source "$HERE/lib.sh"

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "age or age-keygen is not on PATH, bulk v3 tests skipped"
  exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
mkdir -p "$HOME/.config" "$OMARCHY_PATH/config"

if ! "$CLI" init >/dev/null 2>&1; then
  t_bad "fresh v3 repository initializes"
  summary
fi
# shellcheck source=/dev/null
source "$CORE" 2>/dev/null
set +e +u
if [[ "$(repo_data_version 2>/dev/null)" != 3 ]]; then
  t_bad "bulk v3 suite starts with a v3 repository"
  summary
fi
if ! "$CLI" key init >/dev/null 2>&1; then
  echo "age-keygen here cannot create the required post-quantum identity, bulk v3 tests skipped"
  exit 0
fi

secret_file="$HOME/.config/g5-secret.conf"
printf 'ordinary sample data\n' > "$secret_file"
section "bulk tracks a v3 secret into the encrypted vault"
check_true "a custom secret tracks in one transaction" \
  "$CLI" bulk track --kind secret --yes -- "$secret_file"
idx=$(vault_index_decrypt)
blob=$(vault_index_blob "$idx" g5-secret.conf)
check_true "the encrypted index records the secret" test -n "$blob"
check_true "the blob is encrypted in the repository" \
  test -f "$REPO_DIR/vault/blobs/$blob.age"
check "the secret text stays out of Git" "0" \
  "$(git -C "$REPO_DIR" grep -F -c 'ordinary sample data' HEAD 2>/dev/null || echo 0)"
check "the encrypted blob decrypts to the live file" "0" \
  "$(age -d -i "$REPLICANT_HOME/keys/identity.txt" "$REPO_DIR/vault/blobs/$blob.age" 2>/dev/null | cmp -s - "$secret_file"; echo $?)"

section "bulk saves changes to a tracked v3 secret"
printf 'updated sample data\n' > "$secret_file"
check_true "a selected v3 secret saves" \
  "$CLI" bulk save -- g5-secret.conf
idx=$(vault_index_decrypt)
blob=$(vault_index_blob "$idx" g5-secret.conf)
check "the new blob decrypts to the updated file" "0" \
  "$(age -d -i "$REPLICANT_HOME/keys/identity.txt" "$REPO_DIR/vault/blobs/$blob.age" 2>/dev/null | cmp -s - "$secret_file"; echo $?)"
check "the updated secret text stays out of Git" "0" \
  "$(git -C "$REPO_DIR" grep -F -c 'updated sample data' HEAD 2>/dev/null || echo 0)"

section "bulk converts a v3 config entry to a secret"
plain_file="$HOME/.config/g5-convert.conf"
printf 'convert sample data\n' > "$plain_file"
check_true "a config tracks before conversion" \
  "$CLI" bulk track --kind config --yes -- "$plain_file"
check_true "a v3 config converts in one transaction" \
  "$CLI" bulk convert-secret --yes -- g5-convert.conf
idx=$(vault_index_decrypt)
blob=$(vault_index_blob "$idx" g5-convert.conf)
check_true "the converted entry is in the vault" test -n "$blob"
check_true "the converted blob decrypts to the source" \
  age -d -i "$REPLICANT_HOME/keys/identity.txt" "$REPO_DIR/vault/blobs/$blob.age"
check "the converted plaintext is absent from Git" "0" \
  "$(git -C "$REPO_DIR" grep -F -c 'convert sample data' HEAD 2>/dev/null || echo 0)"

summary
