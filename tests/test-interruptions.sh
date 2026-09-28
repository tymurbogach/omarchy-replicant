#!/bin/bash
# Stop each save stage and verify the transaction boundary.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
CLI="$ROOT/bin/omarchy-replicant"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
REPO="$OMARCHY_REPLICANT_HOME/repo"; CONTROL="$TMP/control"; WRAPPERS="$TMP/wrappers"
REAL_GIT=$(command -v git); REAL_AGE=$(command -v age 2>/dev/null || true)
mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr" "$WRAPPERS" "$CONTROL"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'local input\n' > "$HOME/.config/hypr/input.lua"
printf 'FIRST=interrupt-fixture\n' > "$HOME/.config/environment.d/60-secrets.conf"

cat > "$WRAPPERS/git" <<'SH'
#!/bin/sh
set -eu
real=${REAL_GIT:?}; control=${INTERRUPT_CONTROL:?}; phase=${INTERRUPT_PHASE:-}; hit=""
for arg do case "$arg" in commit) hit=commit ;; merge) hit=fast-forward ;; push) hit=push ;; esac; done
if [ -n "$hit" ] && [ "$hit" = "$phase" ] && [ ! -e "$control/released" ]; then
  : > "$control/$hit"
  while [ ! -e "$control/released" ]; do sleep 0.02; done
fi
exec "$real" "$@"
SH
cat > "$WRAPPERS/age" <<'SH'
#!/bin/sh
set -eu
real=${REAL_AGE:?}; control=${INTERRUPT_CONTROL:?}
if [ "${INTERRUPT_PHASE:-}" = encrypt ] && printf '%s\n' "$*" | grep -Eq '(^| )-r( |$)'; then
  : > "$control/encrypt"
  while [ ! -e "$control/released" ]; do sleep 0.02; done
fi
exec "$real" "$@"
SH
chmod +x "$WRAPPERS/git" "$WRAPPERS/age"
export REAL_GIT REAL_AGE INTERRUPT_CONTROL="$CONTROL" PATH="$WRAPPERS:$PATH"

run() { "$CLI" "$@" 2>&1; }
head_now() { git -C "$REPO" rev-parse HEAD 2>/dev/null; }
wait_for() { local file="$1" i=0; while (( i < 200 )); do [[ -e "$CONTROL/$file" ]] && return 0; sleep 0.02; i=$((i + 1)); done; return 1; }
kill_tree() { local pid="$1" child; for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done; kill -TERM "$pid" 2>/dev/null || true; }
start_save_and_stop() {
  local phase="$1"; rm -f "$CONTROL"/*; export INTERRUPT_PHASE="$phase"
  run save --all --auto >"$TMP/$phase.out" 2>&1 & SAVE_PID=$!
  if ! wait_for "$phase"; then
    echo "interrupt test: wrapper did not reach $phase" >&2
    kill_tree "$SAVE_PID"; wait "$SAVE_PID" 2>/dev/null || true; return 1
  fi
  kill_tree "$SAVE_PID"; wait "$SAVE_PID" 2>/dev/null || true; unset INTERRUPT_PHASE
}
release() { : > "$CONTROL/released"; }
discard_all() { local id; for id in $(run tx list 2>/dev/null | cut -f1); do run tx discard "$id" --force >/dev/null 2>&1 || true; done; rm -f "$CONTROL"/*; }

run init >/dev/null 2>&1

if [[ -n "$REAL_AGE" ]] && command -v age-keygen >/dev/null 2>&1; then
  section "encryption interruption keeps plaintext out of transaction files"
  run key init >/dev/null 2>&1
  printf 'changed before encryption\n' >> "$HOME/.config/hypr/input.lua"
  printf 'SECOND=interrupt-fixture\n' >> "$HOME/.config/environment.d/60-secrets.conf"
  before=$(head_now); start_save_and_stop encrypt; release
  check "encryption does not move the active repository" "$before" "$(head_now)"
  check "the interrupted encryption has a journal" "1" "$(run tx list | grep -c . || true)"
  check "no transaction file contains plaintext" "0" "$(grep -R -l 'interrupt-fixture' "$OMARCHY_REPLICANT_HOME/transactions" 2>/dev/null | wc -l)"
  discard_all
else
  section "encryption interruption keeps plaintext out of transaction files"
  check_true "age with post-quantum support is unavailable" true
fi

section "commit interruption leaves the active repository unchanged"
printf 'commit interruption\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now); start_save_and_stop commit; release
check "commit interruption keeps the active repository" "$before" "$(head_now)"
check "commit interruption lists the transaction" "1" "$(run tx list | grep -c . || true)"
discard_all

section "fast-forward interruption leaves the active repository unchanged"
printf 'fast-forward interruption\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now); start_save_and_stop fast-forward; release
check "fast-forward interruption keeps the active repository" "$before" "$(head_now)"
check "fast-forward interruption lists the transaction" "1" "$(run tx list | grep -c . || true)"
discard_all

section "push interruption keeps the local commit and resumes"
REMOTE="$TMP/remote.git"; git init --bare -q -b main "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"; git -C "$REPO" push -q -u origin main
printf 'push interruption\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now); start_save_and_stop push; release; after=$(head_now)
check "push interruption keeps the local commit" "0" "$( [[ "$before" != "$after" ]] && echo 0 || echo 1 )"
check "push interruption lists the transaction" "1" "$(run tx list | grep -c . || true)"
tx=$(run tx list | cut -f1 | head -n1)
check_true "the interrupted push resumes" run tx resume "$tx"
check "the resumed commit reaches the remote" "$after" "$(git --git-dir="$REMOTE" rev-parse main)"
check "no transaction remains after resume" "0" "$(run tx list | grep -c . || true)"

summary
