# shellcheck shell=bash disable=SC2034
# progress.sh: the JSON Lines protocol the panel streams while commands run.
# Sourced by replicant-core.sh, which sets the paths it uses. It defines
# functions and data and runs nothing.
#
# With --progress-json the CLI emits one JSON object per line on stderr:
#
#   {"protocol":1,"type":"stage","stage":"scan","cancellable":true,"message":"Scanning"}
#   {"protocol":1,"type":"result","outcome":"success","message":"Saved","recoveryCommand":null}
#
# Stages are run, scan, encrypt, commit and publish. Outcomes are success,
# noop, cancelled, local-only and failed. Human-readable output is unchanged:
# the JSON lines are extra lines on stderr, and every existing message stays.

# progress_enabled: true when the CLI was invoked with the global
# --progress-json option (REPLICANT_PROGRESS_JSON=1 in the environment).
progress_enabled() { [[ "${REPLICANT_PROGRESS_JSON:-0}" == 1 ]]; }

# progress_json_escape <text>: escape a string for one JSON string value.
progress_json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# progress_stage <stage> <cancellable> <message>: emit one stage event.
# Cancellable is the literal word true or false.
progress_stage() {
  progress_enabled || return 0
  local stage="${1:-scan}" cancellable="${2:-true}" message="${3:-}"
  [[ "$cancellable" == true || "$cancellable" == false ]] || cancellable=true
  printf '{"protocol":1,"type":"stage","stage":"%s","cancellable":%s,"message":"%s"}\n' \
    "$stage" "$cancellable" "$(progress_json_escape "$message")" >&2
  return 0
}

# progress_result <outcome> <message> [recoveryCommand]: emit the terminal event.
# RecoveryCommand is a plain string or empty for null.
progress_result() {
  progress_enabled || return 0
  local outcome="${1:-success}" message="${2:-}" recovery="${3:-}"
  case "$outcome" in
    success|noop|cancelled|local-only|failed) ;;
    *) outcome="failed" ;;
  esac
  if [[ -n "$recovery" ]]; then
    printf '{"protocol":1,"type":"result","outcome":"%s","message":"%s","recoveryCommand":"%s"}\n' \
      "$outcome" "$(progress_json_escape "$message")" "$(progress_json_escape "$recovery")" >&2
  else
    printf '{"protocol":1,"type":"result","outcome":"%s","message":"%s","recoveryCommand":null}\n' \
      "$outcome" "$(progress_json_escape "$message")" >&2
  fi
  REPLICANT_PROGRESS_RESULT_EMITTED=1
  return 0
}
