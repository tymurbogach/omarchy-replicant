#!/bin/bash
# What a person meets in the panel, checked without a screen: every button runs
# a command the CLI has, every key the panel answers is written down, every
# icon-only button says what it does, and every word is English with one meaning.
#
# Static on purpose. No suite can drive the panel, and each of these has been
# wrong before in a way the other suites could not see.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${USABILITY_ROOT:-$(cd -- "$HERE/.." && pwd)}"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

PANEL="$ROOT/Panel.qml"
CLI="$ROOT/bin/omarchy-replicant"

section "every button runs a command the CLI has"
# The panel builds its commands as [root.cli, "<subcommand>", ...]. A subcommand
# renamed in the CLI and not here is a button that runs, fails and says nothing.
# Only the dispatcher's arms count: they are the ones that shift or load the core.
known=$(grep -oE '^[[:space:]]+[a-z][a-z-]*\) (shift|ensure_core)' "$CLI" |
        sed -E 's/^[[:space:]]+([a-z-]+)\).*/\1/' | sort -u)
used=$(grep -ohE 'root\.cli, "[a-z][a-z-]*"' "$ROOT"/*.qml | sed -E 's/.*"(.*)"/\1/' | sort -u)
check_true "the panel calls the CLI at all" test -n "$used"
for cmd in $used; do
  check_true "the CLI answers '$cmd'" grep -qx "$cmd" <<<"$known"
done

section "every key the panel answers is named where a person can find it"
# The keys work whether or not anybody knows them. `a` (straight to "Add more
# files") was handled and written down nowhere, so for everyone it did not exist.
# `st === ` is a sync state, not a key, hence the character before the t.
keys=$(grep -oE '(^|[^A-Za-z_])t === "[^"]+"' "$PANEL" | sed -E 's/.*"(.*)"/\1/' | sort -u)
check_true "the panel answers keys at all" test -n "$keys"
# Comments do not count. A mutation run proved it: the only "(a)" left after
# the label lost it was the comment explaining the label.
shown=$(grep -vE '^[[:space:]]*//' "$PANEL")
for k in $keys; do
  check_true "key '$k' is named as ($k)" grep -qF "($k)" <<<"$shown"
done

section "every icon-only button says what it does"
# A glyph on its own is a guess, and its tooltip is the only label it has.
unlabelled=$(awk '
  /Button[[:space:]]*\{/ && !/ButtonGroup/ { inb = 1; depth = 0; block = ""; start = FNR }
  inb {
    block = block $0 "\n"
    depth += gsub(/\{/, "{") - gsub(/\}/, "}")
    if (depth <= 0) {
      inb = 0
      if (block ~ /iconText:/ && block !~ /[^A-Za-z]text:/ && block !~ /tooltipText:/)
        print FILENAME ":" start
    }
  }' "$ROOT"/*.qml)
check "icon-only buttons with no tooltip" "" "$unlabelled"

section "every word on screen is English"
# The Language rule, which has no exception for a label: a string in a second
# language is the one a later grep misses.
foreign=$(grep -rnP '[áéíóúñÁÉÍÓÚÑ¿¡]' "$ROOT"/*.qml "$ROOT"/bin "$ROOT"/README.md \
            "$ROOT"/CLAUDE.md "$ROOT"/docs 2>/dev/null || true)
check "lines with letters English does not use" "" "$foreign"

section "one word for one state"
# The scope button says Off, the legend says off and a card says "3 off". The
# row and the stat card said "not synced": two words for one state.
off_row=$(grep -oE 'if \(st === "off"\) return "[^"]+"' "$PANEL" | sed -E 's/.*return "(.*)"/\1/')
off_card=$(grep -oE 'label: "[^"]+"; value: String\(root\.countOff\)' "$PANEL" | sed -E 's/label: "([^"]+)".*/\1/')
check_contains "the row calls it off"        "off" "$off_row"
check_contains "…and so does the stat card"  "off" "$off_card"

summary
