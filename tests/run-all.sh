#!/bin/bash
# Runs every suite, plus the static checks that catch what the suites cannot.
# This is the one command to run before pushing.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
failed=0

banner() { printf '\n\033[1m══ %s\033[0m\n' "$1"; }

for suite in test-core.sh test-settings.sh test-cli.sh; do
  banner "$suite"
  "$HERE/$suite" || failed=$((failed+1))
done

banner "shell syntax"
for f in "$ROOT"/bin/omarchy-replicant "$ROOT"/bin/*.sh "$HERE"/*.sh; do
  if bash -n "$f" 2>/dev/null; then printf '  \033[32m✓\033[0m %s\n' "${f#"$ROOT"/}"
  else printf '  \033[31m✗\033[0m %s\n' "${f#"$ROOT"/}"; bash -n "$f"; failed=$((failed+1)); fi
done

banner "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # SC1091: sourced files resolved at runtime. SC2154: variables that come from
  # the sourced core. Both are noise here, not findings.
  if shellcheck -e SC1091,SC2154 -S warning "$ROOT"/bin/omarchy-replicant "$ROOT"/bin/*.sh "$HERE"/*.sh; then
    printf '  \033[32m✓\033[0m clean at warning level\n'
  else failed=$((failed+1)); fi
else
  printf '  \033[33m·\033[0m shellcheck not installed — skipped\n'
fi

banner "QML syntax"
QMLLINT=$(command -v qmllint-qt6 || command -v qmllint || true)
if [[ -n "$QMLLINT" ]]; then
  scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
  for f in "$ROOT"/*.qml; do
    # qmllint cannot parse `function name(): void`, which Quickshell's
    # IpcHandler requires for a function that returns nothing — it exits 255
    # with no diagnostic at all. Lint a copy with that annotation dropped so
    # the check still catches real errors in the same file.
    sed 's/): void {/) {/' "$f" > "$scratch/$(basename "$f")"
    if "$QMLLINT" -I /usr/share/omarchy/shell "$scratch/$(basename "$f")" >/dev/null 2>&1; then
      printf '  \033[32m✓\033[0m %s\n' "$(basename "$f")"
    else
      printf '  \033[31m✗\033[0m %s\n' "$(basename "$f")"
      "$QMLLINT" -I /usr/share/omarchy/shell "$scratch/$(basename "$f")"
      failed=$((failed+1))
    fi
  done
else
  printf '  \033[33m·\033[0m qmllint not installed — skipped\n'
fi

banner "the QML traps this plugin has actually hit"
qml_problem=0
# 1. `state` is a built-in property of every Item; a bare `state.` inside a
#    nested item resolves to that empty string, not to our data.
if grep -nE '(^|[^.a-zA-Z])state\.' "$ROOT"/*.qml | grep -v '^\S*:[0-9]*:\s*//'; then
  printf '  \033[31m✗\033[0m an unqualified `state.` — see CLAUDE.md\n'; qml_problem=1
fi
# 2. Style.spacing.rowPaddingY does not exist; it evaluates to NaN and the
#    delegate silently renders at zero height.
if grep -n 'rowPaddingY' "$ROOT"/*.qml | grep -v '^\S*:[0-9]*:\s*//'; then
  printf '  \033[31m✗\033[0m Style.spacing.rowPaddingY does not exist — use controlPaddingY\n'; qml_problem=1
fi
# 3. Debug logging left in a released panel.
if grep -n 'console\.log' "$ROOT"/*.qml; then
  printf '  \033[31m✗\033[0m console.log left in the panel\n'; qml_problem=1
fi
# 4. The UI must never look for the CLI on PATH. `omarchy plugin add` runs no
#    install hook, so nothing puts omarchy-replicant in ~/.local/bin, and a
#    fresh install pointing there leaves every button silently doing nothing.
if grep -n 'local/bin' "$ROOT"/*.qml | grep -v ':[0-9]*: *//'; then
  printf '  \033[31m✗\033[0m the UI resolves the CLI on PATH — use Qt.resolvedUrl("bin/...")\n'; qml_problem=1
fi
# 5. Each QML entry point resolves the CLI from its own location.
for f in "$ROOT"/Panel.qml "$ROOT"/BarWidget.qml "$ROOT"/Service.qml; do
  grep -q 'Qt.resolvedUrl("bin/omarchy-replicant")' "$f" || {
    printf '  \033[31m✗\033[0m %s does not resolve the CLI relative to itself\n' "$(basename "$f")"; qml_problem=1; }
done
if (( qml_problem == 0 )); then printf '  \033[32m✓\033[0m none present\n'; else failed=$((failed+1)); fi

banner "manifest"
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  if omarchy-plugin-validate "$ROOT" >/dev/null 2>&1; then printf '  \033[32m✓\033[0m valid\n'
  else printf '  \033[31m✗\033[0m invalid\n'; omarchy-plugin-validate "$ROOT"; failed=$((failed+1)); fi
else
  printf '  \033[33m·\033[0m omarchy-plugin-validate not on PATH — skipped\n'
fi

echo
if (( failed == 0 )); then printf '\033[32mEverything passed.\033[0m\n'; exit 0
else printf '\033[31m%d section(s) failed.\033[0m\n' "$failed"; exit 1; fi
