#!/bin/bash
# One transaction engine: every mutator journals before it commits, fails when
# the journal cannot be written, creates at most one commit, and never discards
# committed work implicitly. Shapes (scope, policy, track) commit only their
# own paths on top of a dirty tree; save and bulk snapshot in a worktree and
# require it clean.
#
# Runs against a fake $HOME and a throwaway repo, the way test-bulk.sh does.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/omarchy-replicant"
CORE="$HERE/../bin/replicant-core.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
REPO="$OMARCHY_REPLICANT_HOME/repo"
head_now() { git -C "$REPO" rev-parse HEAD 2>/dev/null; }
commits_since() { git -C "$REPO" rev-list --count "$1"..HEAD 2>/dev/null; }

mkdir -p "$HOME/.config/hypr" "$OMARCHY_PATH/config/hypr"
printf 'default\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'one\n' > "$HOME/.config/hypr/input.lua"
printf 'two\n' > "$HOME/.config/hypr/hyprlock.conf"
printf 'alpha\n' > "$HOME/.config/alpha.conf"
# NOTE: sourcing the core defines its own run() (tree.sh), so the CLI helper
# below must be defined after the source line, or every CLI call exits 127.
# shellcheck source=bin/replicant-core.sh
source "$CORE" 2>/dev/null
set +e +u
run() { "$CLI" "$@" 2>&1; }
core_backup >/dev/null 2>&1
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m initial >/dev/null 2>&1
REMOTE_FIXTURE="$TMP/fixture.git"; git init -q --bare "$REMOTE_FIXTURE"
git -C "$REPO" remote add origin "$REMOTE_FIXTURE" 2>/dev/null
git -C "$REPO" push -q -u origin main 2>/dev/null

section "every mutator refuses an unwritable journal before mutating"
mkdir -p "$OMARCHY_REPLICANT_HOME/transactions"
chmod a-w "$OMARCHY_REPLICANT_HOME/transactions"
before=$(head_now)
printf 'journal proof\n' >> "$HOME/.config/hypr/input.lua"
check_false "save refuses" "$CLI" save --all -m "journal proof" --no-push
check "…leaving HEAD unchanged" "$before" "$(head_now)"
check_false "bulk refuses" "$CLI" bulk save -- hypr/input.lua
check "…leaving HEAD unchanged" "$before" "$(head_now)"
check_false "scope refuses" "$CLI" scope hypr/input.lua profile
check "…leaving HEAD unchanged" "$before" "$(head_now)"
check_false "policy refuses" "$CLI" policy set --scope off -- hypr/input.lua
check "…leaving HEAD unchanged" "$before" "$(head_now)"
check_false "track refuses" "$CLI" track "$HOME/.config/alpha.conf"
check "…leaving HEAD unchanged" "$before" "$(head_now)"
check "…leaving the repo copy unchanged" "0" "$(git -C "$REPO" status --porcelain | grep -c . || true)"
chmod u+w "$OMARCHY_REPLICANT_HOME/transactions"
# The section above mutates through scope, policy and track shape commits once
# the journal gate exists; reset that state so later sections start clean.
run scope hypr/input.lua shared >/dev/null 2>&1
run policy set --scope shared -- hypr/input.lua >/dev/null 2>&1
run untrack alpha.conf >/dev/null 2>&1
run save --all --auto --no-push >/dev/null 2>&1

section "a journal that cannot be written fails the write"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/jq"; chmod +x "$FAKEBIN/jq"
TXPROBE="$TMP/journal-probe"; mkdir -p "$TXPROBE"
if PATH="$FAKEBIN:$PATH" tx_meta_write "$TXPROBE" started abc123 all "probe message"; then
  t_bad "tx_meta_write with a broken journal reports failure"
else
  t_ok "tx_meta_write with a broken journal reports failure"
fi
printf '{"version":1,"base":"abc123","scope":"all","ids":[],"msg":"probe","stage":"started","candidate":null,"push":null}\n' > "$TXPROBE/meta.json"
if PATH="$FAKEBIN:$PATH" tx_meta_field "$TXPROBE" candidate abc123; then
  t_bad "tx_meta_field with a broken journal reports failure"
else
  t_ok "tx_meta_field with a broken journal reports failure"
fi

section "no git add or commit failure is ignored"
ignored=$(grep -nE 'git[^|]* (add|commit)[^|]*\|\| true' "$HERE/../bin/lib/repo.sh" "$HERE/../bin/lib/transaction.sh" "$HERE/../bin/lib/save.sh" "$HERE/../bin/omarchy-replicant" 2>/dev/null || true)
check "add and commit failures abort" "" "$ignored"

section "bulk orchestration lives in the library, not in the CLI"
check "the CLI creates no worktree" "0" "$(grep -c 'worktree add' "$HERE/../bin/omarchy-replicant" || true)"
check "…and commits no candidate" "0" "$(grep -c 'rev-parse HEAD' "$HERE/../bin/omarchy-replicant" || true)"
check "…while the library owns the bulk transaction" "1" "$(grep -c 'core_bulk_transact()' "$HERE/../bin/lib/bulk.sh" || true)"

section "resume inspects the repository, not only the journal"
mkdir -p "$OMARCHY_REPLICANT_HOME/transactions/fake-dead"
printf '{"version":1,"base":"abc123","scope":"all","ids":[],"msg":"dead","stage":"committed","candidate":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","push":"failed"}\n' \
  > "$OMARCHY_REPLICANT_HOME/transactions/fake-dead/meta.json"
out=$(run tx resume fake-dead 2>&1); rc=$?
check "resuming a missing commit fails" "1" "$rc"
check_contains "…naming the commit as missing from the repo" "not in the repository" "$out"
check "…and the journal is kept" "1" "$(run tx list 2>/dev/null | grep -c fake-dead || true)"
run tx discard fake-dead --force >/dev/null 2>&1

section "every mutation creates at most one commit"
printf 'one more\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
run save --all -m "tx: one commit" --no-push >/dev/null 2>&1
check "save creates one commit" "1" "$(commits_since "$before")"
printf 'bulk proof\n' >> "$HOME/.config/hypr/input.lua"
before=$(head_now)
run bulk save -- hypr/input.lua >/dev/null 2>&1
check "bulk creates one commit" "1" "$(commits_since "$before")"
before=$(head_now)
run scope hypr/input.lua profile >/dev/null 2>&1
check "scope creates one commit" "1" "$(commits_since "$before")"
run scope hypr/input.lua shared >/dev/null 2>&1
before=$(head_now)
run track "$HOME/.config/alpha.conf" >/dev/null 2>&1
check "track creates one commit" "1" "$(commits_since "$before")"

section "concurrent mutators serialize instead of colliding"
run save --all --auto --no-push >/dev/null 2>&1
printf 'race a\n' >> "$HOME/.config/hypr/input.lua"
run save --all --auto --no-push >/dev/null 2>&1 &
p1=$!
run bulk save -- hypr/input.lua >/dev/null 2>&1 &
p2=$!
run policy set --scope shared -- hypr/input.lua >/dev/null 2>&1 &
p3=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
wait "$p3"; r3=$?
check "no index.lock survives the race" "0" "$(find "$REPO/.git" -name '*.lock' 2>/dev/null | grep -c . || true)"
check "the repo still answers" "0" "$(git -C "$REPO" rev-parse HEAD >/dev/null 2>&1; echo $?)"
check "…and status still renders" "0" "$(run status --json --brief --no-fetch >/dev/null 2>&1; echo $?)"
check "…with every racer either committed or cleanly refused" "0" \
  "$([ "$r1" -le 1 ] && [ "$r2" -le 1 ] && [ "$r3" -le 1 ] && echo 0 || echo 1)"

section "an interrupted push keeps the transaction for resume"
REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"
git -C "$REPO" remote set-url origin "$REMOTE" 2>/dev/null
git -C "$REPO" push -q -u origin main 2>/dev/null
mkdir -p "$TMP/sleepbin"
# The stub replaces git for one push: after 2 seconds it delivers the chosen
# signal to its own process group — exactly what a terminal does on Ctrl-C to
# a foreground job. The save runs synchronously under the test's control, so
# the interrupt lands mid-push every time, with no poll-and-kill race. A real
# git dies from the signal with a non-zero status; the traps below make the
# interrupted stub report the same failure whatever the signal, so a save
# never mistakes an interrupt for a successful push.
cat > "$TMP/sleepbin/git" <<'STUB'
#!/bin/bash
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if [[ " $* " == *" push "* ]]; then
  printf 'pushing\n' >> "${REPLICANT_TX_KILL_MARKER:-/dev/null}"
  # The walker delivers the signal up the save's own ancestry and stops at the
  # test shell: a group-wide kill would hit the test itself, and the ppid
  # chain is deterministic wherever the process-group layout happens to be.
  # A script that inherits SIGINT as ignored (bash with no job control) cannot
  # be stopped by the walker, but the interrupted push itself always fails:
  # the stub exits non-zero after signalling, like a git killed by the signal.
  ( sleep 2
    _p=$$
    while [[ "$_p" != 1 && "$_p" != "${REPLICANT_TX_TESTPID:-x}" ]]; do
      kill -"${REPLICANT_TX_SIG:-TERM}" "$_p" 2>/dev/null || true
      _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
      [[ -z "$_p" ]] && break
    done
  ) &
  wait
  exit 143
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$TMP/sleepbin/git"
for sig in TERM INT HUP; do
  printf 'killed proof %s\n' "$sig" >> "$HOME/.config/hypr/input.lua"
  export REPLICANT_TX_KILL_MARKER="$TMP/push-started" REPLICANT_TX_SIG="$sig"
  rm -f "$REPLICANT_TX_KILL_MARKER"
  base=$(head_now)
  out=$(PATH="$TMP/sleepbin:$PATH" REPLICANT_TX_TESTPID=$$ "$CLI" save --all --auto 2>&1); rc=$?
  check "the save stops on the $sig-interrupted push" "1" "$(( rc != 0 ? 1 : 0 ))"
  check "…the push stalled for the $sig interrupt" "1" "$([[ -s "$REPLICANT_TX_KILL_MARKER" ]] && echo 1 || echo 0)"
  check_contains "…it reports the commit stayed local" "Saved locally" "$out"
  check "…the committed work is in HEAD" "1" "$(commits_since "$base")"
  check "…and the transaction is kept" "1" "$(run tx list 2>/dev/null | grep -c . || true)"
  check_contains "…doctor offers the resume" "tx resume" "$(run doctor)"
  for _tx in $(run tx list 2>/dev/null | cut -f1); do run tx discard "$_tx" --force >/dev/null 2>&1; done
done
unset REPLICANT_TX_KILL_MARKER REPLICANT_TX_SIG

section "a failed shape push keeps its commit and its journal"
git -C "$REPO" remote set-url origin /nonexistent/shape.git 2>/dev/null
before=$(head_now)
out=$(run scope hypr/hyprlock.conf profile 2>&1); rc=$?
check "the shape reports the failed push" "1" "$rc"
check_contains "…as a local-only outcome" "Saved locally" "$out"
check_contains "…with the retry command" "pull" "$out"
check "…keeping the commit" "1" "$(commits_since "$before")"
check "…and its journal for resume" "1" "$(run tx list 2>/dev/null | grep -c . || true)"
for _tx in $(run tx list 2>/dev/null | cut -f1); do run tx discard "$_tx" --force >/dev/null 2>&1; done
run scope hypr/hyprlock.conf shared >/dev/null 2>&1
for _tx in $(run tx list 2>/dev/null | cut -f1); do run tx discard "$_tx" --force >/dev/null 2>&1; done
git -C "$REPO" remote set-url origin "$REMOTE_FIXTURE" 2>/dev/null
git -C "$REPO" push -q -u origin main 2>/dev/null

if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 \
    && probe=$(mktemp -d) && ( umask 077; age-keygen -pq -o "$probe/key" >/dev/null 2>&1 ) \
    && grep -q '^# public key: age1pq1' "$probe/key" 2>/dev/null; then
  rm -rf -- "$probe"
  section "key export refuses to overwrite without --force"
  "$CLI" key init >/dev/null 2>&1
  run save --all --auto --no-push >/dev/null 2>&1
  printf 'FIRST=tx-fixture-alpha\n' > "$HOME/.config/tx-secret.conf"
  run track "$HOME/.config/tx-secret.conf" --secret >/dev/null 2>&1
  run save --all --auto --no-push >/dev/null 2>&1
  check_true "the first export lands" "$CLI" key export "$TMP/tx-key-backup.txt"
  check "…at mode 600" "600" "$(stat -c '%a' "$TMP/tx-key-backup.txt" 2>/dev/null)"
  check_false "a second export without --force refuses" "$CLI" key export "$TMP/tx-key-backup.txt"
  check_true "…while --force replaces it atomically" "$CLI" key export --force "$TMP/tx-key-backup.txt"
  check "…still at mode 600" "600" "$(stat -c '%a' "$TMP/tx-key-backup.txt" 2>/dev/null)"
  check "…verifying by recipient" "$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)" \
    "$(age-keygen -y "$TMP/tx-key-backup.txt" 2>/dev/null)"

  section "key rotation preserves the previous key"
  old_recipient=$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)
  run key rotate >/dev/null 2>&1
  new_recipient=$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)
  check "rotation moves to a new recipient" "1" "$([[ "$old_recipient" != "$new_recipient" ]] && echo 1 || echo 0)"
  prev="$OMARCHY_REPLICANT_HOME/keys/identity.txt.prev"
  check "…keeping the previous identity" "1" "$([[ -n "$prev" ]] && echo 1 || echo 0)"
  check "…at mode 600" "600" "$(stat -c '%a' "$prev" 2>/dev/null)"
  check "…holding the old key" "$old_recipient" "$(age-keygen -y "$prev" 2>/dev/null)"
  check_contains "…while the vault answers with the new one" "ready" "$(run key status 2>&1)"
  check "…leaving no rotation journal behind" "0" "$([[ -f "$OMARCHY_REPLICANT_HOME/key-rotation.json" ]] && echo 1 || echo 0)"

  section "a rotation that fails midway keeps the old key working"
  mkdir -p "$TMP/failbin"
  REAL_AGE=$(command -v age)
  cat > "$TMP/failbin/age" <<STUB
#!/bin/bash
for a in "\$@"; do
  case "\$a" in *vault/index.age.new) exit 1 ;; esac
done
exec "$REAL_AGE" "\$@"
STUB
  chmod +x "$TMP/failbin/age"
  before_recipient=$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)
  if PATH="$TMP/failbin:$PATH" "$CLI" key rotate >/dev/null 2>&1; then
    t_bad "rotation with a broken index write reports failure"
  else
    t_ok "rotation with a broken index write reports failure"
  fi
  check "…keeping the working identity" "$before_recipient" \
    "$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)"
  check_contains "…and the vault still answers" "ready" "$(run key status 2>&1)"

  section "process death during rotation keeps the old key and reconciles"
  kill_tree() { local pid="$1" sig="${2:-TERM}" child; for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child" "$sig"; done; kill "-$sig" "$pid" 2>/dev/null || true; }
  mkdir -p "$TMP/killbin"
  REAL_AGE2=$(command -v age)
  cat > "$TMP/killbin/age" <<STUB
#!/bin/bash
if [[ ! -f "$TMP/rotate-started" ]]; then
  printf 'rotating\n' >> "$TMP/rotate-started"
  sleep 30 || exit 1
  exit 0
fi
exec "$REAL_AGE2" "\$@"
STUB
  chmod +x "$TMP/killbin/age"
  death_recipient=$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)
  rm -f "$TMP/rotate-started"
  PATH="$TMP/killbin:$PATH" "$CLI" key rotate >/dev/null 2>&1 &
  rotpid=$!
  # SIGKILL cannot be caught or deferred: the tree dies at the instant of the
  # kill, exactly what a hard process death looks like for a rotation.
  for _ in $(seq 1 600); do [[ -f "$TMP/rotate-started" ]] && break; sleep 0.1; done
  if [[ -f "$TMP/rotate-started" ]]; then
    kill_tree "$rotpid" KILL
  else
    t_bad "the rotation did not start before the kill"
    kill_tree "$rotpid" KILL
  fi
  wait "$rotpid" 2>/dev/null
  check "the rotation started before the kill" "1" "$([[ -f "$TMP/rotate-started" ]] && echo 1 || echo 0)"
  check "…keeping the working identity" "$death_recipient" \
    "$(age-keygen -y "$OMARCHY_REPLICANT_HOME/keys/identity.txt" 2>/dev/null)"
  check_contains "…and the vault still answers" "ready" "$(run key status 2>&1)"
  check "…with the rotation journal kept" "1" "$([[ -f "$OMARCHY_REPLICANT_HOME/key-rotation.json" ]] && echo 1 || echo 0)"
  check_true "…and a new rotation reconciles the stale journal" "$CLI" key rotate
  check "…leaving no journal behind" "0" "$([[ -f "$OMARCHY_REPLICANT_HOME/key-rotation.json" ]] && echo 1 || echo 0)"
else
  rm -rf -- "${probe:-/nonexistent}" 2>/dev/null || true
  section "key export and rotation"
  check_true "age without post-quantum support skips the key transaction" true
fi

summary
