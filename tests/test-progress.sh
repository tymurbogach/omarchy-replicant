#!/bin/bash
# Progress protocol: --progress-json streams stage and result events on
# stderr while human output stays compatible.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
CLI="$ROOT/bin/omarchy-replicant"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

TMP=$(mktemp -d)
CANCEL_PID=""
kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
}
cleanup() {
  if [[ -n "$CANCEL_PID" ]]; then kill_tree "$CANCEL_PID"; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home" OMARCHY_PATH="$TMP/omarchy" OMARCHY_REPLICANT_HOME="$TMP/replicant"
export REPLICANT_TEST_ALLOW_LEGACY_WRITES=1
REPO="$OMARCHY_REPLICANT_HOME/repo"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/environment.d" "$OMARCHY_PATH/config/hypr"
printf 'default input\n' > "$OMARCHY_PATH/config/hypr/input.lua"
printf 'local input\n' > "$HOME/.config/hypr/input.lua"

run() { "$CLI" "$@" 2>&1; }

section "progress-json streams stages and a success result"
run init >/dev/null 2>&1
REMOTE="$TMP/remote.git"; git init --bare -q -b main "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"
printf 'progress fixture\n' >> "$HOME/.config/hypr/input.lua"
"$CLI" --progress-json save --all --auto >"$TMP/out.txt" 2>"$TMP/err.txt"
save_rc=$?
check "progress save exits successfully" "0" "$save_rc"
check_contains "progress emits a scan stage" '"stage":"scan"' "$(cat "$TMP/err.txt")"
check_contains "progress disables cancel before commit" '"stage":"commit","cancellable":false' "$(cat "$TMP/err.txt")"
check_contains "progress emits a success result" '"outcome":"success"' "$(cat "$TMP/err.txt")"
check_contains "human output still reports the push" "Everything saved and pushed." "$(cat "$TMP/err.txt")"
check "protocol events parse as JSON" "true" "$(jq -R 'fromjson? | select(.protocol == 1)' "$TMP/err.txt" | jq -s 'length > 0')"

section "progress-json reports noop when nothing changed"
"$CLI" --progress-json save --all --auto >"$TMP/out2.txt" 2>"$TMP/err2.txt"
check_contains "noop outcome is explicit" '"outcome":"noop"' "$(cat "$TMP/err2.txt")"

section "progress-json reports local-only with --no-push"
printf 'local only fixture\n' >> "$HOME/.config/hypr/input.lua"
"$CLI" --progress-json save --all --auto --no-push >"$TMP/out3.txt" 2>"$TMP/err3.txt"
check_contains "local-only outcome is explicit" '"outcome":"local-only"' "$(cat "$TMP/err3.txt")"
check_contains "local-only names the retry" "omarchy-replicant push" "$(cat "$TMP/err3.txt")"

section "normal output stays compatible without the flag"
printf 'compat fixture\n' >> "$HOME/.config/hypr/input.lua"
"$CLI" save --all --auto >"$TMP/out4.txt" 2>"$TMP/err4.txt"
check "no JSON protocol without the flag" "" "$(grep -o '"protocol":1' "$TMP/err4.txt" || true)"
check_contains "human output still reports the push" "Everything saved and pushed." "$(cat "$TMP/err4.txt")"

section "read-only commands receive a terminal result event"
"$CLI" --progress-json status --json --no-fetch >"$TMP/out5.txt" 2>"$TMP/err5.txt"
check_true "status JSON stays valid on stdout" jq -e . "$TMP/out5.txt"
check_contains "commands emit a live run stage" '"stage":"run"' "$(cat "$TMP/err5.txt")"
check_contains "status emits a success result" '"outcome":"success"' "$(cat "$TMP/err5.txt")"

section "failed commands emit a failed result and keep their exit code"
if "$CLI" --progress-json not-a-replicant-command >"$TMP/out-error.txt" 2>"$TMP/err-error.txt"; then error_rc=0; else error_rc=$?; fi
check "failed command keeps a nonzero exit" "1" "$error_rc"
check_contains "failed command emits a failed result" '"outcome":"failed"' "$(cat "$TMP/err-error.txt")"

section "shape mutations stream commit and publish stages"
printf 'tracked fixture\n' > "$HOME/.config/hypr/custom.lua"
"$CLI" --progress-json track "$HOME/.config/hypr/custom.lua" >"$TMP/out6.txt" 2>"$TMP/err6.txt"
check_contains "track emits its commit boundary" '"stage":"commit","cancellable":false' "$(cat "$TMP/err6.txt")"
check_contains "track emits its publish stage" '"stage":"publish"' "$(cat "$TMP/err6.txt")"
check_contains "track emits one success result" '"outcome":"success"' "$(cat "$TMP/err6.txt")"
check "shape command emits one result event" "1" "$(jq -R 'fromjson? | select(.type == "result")' "$TMP/err6.txt" | jq -s 'length')"

section "shape mutations report a local-only result without a remote"
git -C "$REPO" remote remove origin
printf 'local shape fixture\n' > "$HOME/.config/hypr/local-only.lua"
"$CLI" --progress-json track "$HOME/.config/hypr/local-only.lua" >"$TMP/out7.txt" 2>"$TMP/err7.txt"
check_contains "no-remote shape outcome is local-only" '"outcome":"local-only"' "$(cat "$TMP/err7.txt")"
check_contains "no-remote shape gives its recovery command" "omarchy-replicant create --push" "$(cat "$TMP/err7.txt")"

section "cancel before commit stops the complete process group"
WRAPPERS="$TMP/wrappers"; CONTROL="$TMP/control"
mkdir -p "$WRAPPERS" "$CONTROL"
REAL_GIT=$(command -v git)
cat > "$WRAPPERS/git" <<'SH'
#!/bin/sh
case " $* " in
  *" worktree add "*)
    : > "$CANCEL_MARKER"
    while [ ! -e "$CANCEL_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$WRAPPERS/git"
export REAL_GIT CANCEL_MARKER="$CONTROL/ready" CANCEL_RELEASE="$CONTROL/release"
export PATH="$WRAPPERS:$PATH"
printf 'cancel before commit\n' >> "$HOME/.config/hypr/input.lua"
before=$(git -C "$REPO" rev-parse HEAD)
"$ROOT/bin/replicant-process.sh" "$CLI" --progress-json save --all --auto >"$TMP/cancel.out" 2>"$TMP/cancel.err" &
CANCEL_PID=$!
ready=0
for _ in {1..200}; do
  if [[ -e "$CANCEL_MARKER" ]]; then ready=1; break; fi
  sleep 0.01
done
if (( ready )); then
  kill -TERM "$CANCEL_PID" 2>/dev/null || true
  cancelled=0
  for _ in {1..100}; do
    if grep -q '"outcome":"cancelled"' "$TMP/cancel.err" 2>/dev/null; then cancelled=1; break; fi
    sleep 0.01
  done
  children_alive=0
  pgrep -P "$CANCEL_PID" >/dev/null 2>&1 && children_alive=1
  cancel_output=$(cat "$TMP/cancel.err")
  after_signal=$(git -C "$REPO" rev-parse HEAD)
else
  t_bad "save did not reach the cancellable scan stage"
  cancelled=0; children_alive=1; cancel_output=""; after_signal=$(git -C "$REPO" rev-parse HEAD)
fi
check "the first signal reports cancellation" "1" "$cancelled"
check "the first signal stops CLI child processes" "0" "$children_alive"
check_contains "cancellation emits a cancelled result" '"outcome":"cancelled"' "$cancel_output"
check "cancelled save leaves the active commit unchanged" "$before" "$after_signal"
kill_tree "$CANCEL_PID"
: > "$CANCEL_RELEASE"
wait "$CANCEL_PID" 2>/dev/null || true
CANCEL_PID=""
PATH=${PATH#"$WRAPPERS":}; export PATH
unset REAL_GIT CANCEL_MARKER CANCEL_RELEASE

summary
