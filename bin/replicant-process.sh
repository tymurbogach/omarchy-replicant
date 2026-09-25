#!/bin/bash
# Run one CLI command in a child process group that Quickshell can cancel.
# Quickshell signals only this wrapper. The wrapper forwards that signal to
# the complete command group, including git and age children.
set -uo pipefail

if (( $# == 0 )); then
  echo "replicant-process: command is required" >&2
  exit 2
fi

set -m
export REPLICANT_PROCESS_GROUP=1
child_pid=""

stop_command() {
  trap '' INT TERM
  if [[ -n "$child_pid" ]]; then
    kill -TERM -- "-$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit 143
}

trap stop_command INT TERM
"$@" &
child_pid=$!
wait "$child_pid"
result=$?
trap - INT TERM
exit "$result"
