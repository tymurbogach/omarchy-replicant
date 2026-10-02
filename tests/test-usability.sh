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
CLI="$ROOT/bin/replicant"
# Every QML file, the panel's parts in components/ included. A check that reads
# only Panel.qml stops seeing a label the day its component moves to a file.
QML=("$ROOT"/*.qml "$ROOT"/components/*.qml)

section "every button runs a command the CLI has"
# The panel builds its commands as [root.cli, "<subcommand>", ...]. A subcommand
# renamed in the CLI and not here is a button that runs, fails and says nothing.
# Only the dispatcher's arms count: they are the ones that shift or load the core.
known=$(grep -oE '^[[:space:]]+[a-z][a-z-]*\) (shift|ensure_core)' "$CLI" |
        sed -E 's/^[[:space:]]+([a-z-]+)\).*/\1/' | sort -u)
used=$(grep -ohE '(root|panel)\.cli, "[a-z][a-z-]*"' "${QML[@]}" | sed -E 's/.*"(.*)"/\1/' | sort -u)
check_true "the panel calls the CLI at all" test -n "$used"
for cmd in $used; do
  check_true "the CLI answers '$cmd'" grep -qx "$cmd" <<<"$known"
done

section "repository creation requires its explicit button"
check_false "Enter in the repository name does not create a repository" \
  grep -q 'onAccepted: root.createRepo()' "$PANEL"
check_true "the confirmation label fits its fixed button" \
  grep -q '"Create")' "$PANEL"

section "command output stays inside its reader"
VIEWER="$ROOT/components/TextViewer.qml"
check_true "output uses the reader width" grep -qF 'width: body.width' "$VIEWER"
check_true "long output lines wrap instead of clipping" \
  grep -qF 'Text.WrapAnywhere : Text.NoWrap' "$VIEWER"
check_true "output has a copy action" grep -qF 'panel.copyViewerText()' "$VIEWER"
check_true "the copy action passes the full output to wl-copy" \
  grep -qF 'root.viewerText' "$PANEL"

section "every key the panel answers is named where a person can find it"
# The keys work whether or not anybody knows them. `a` (straight to "Add more
# files") was handled and written down nowhere, so for everyone it did not exist.
# `st === ` is a sync state, not a key, hence the character before the t.
keys=$(grep -oE '(^|[^A-Za-z_])t === "[^"]+"' "$PANEL" | sed -E 's/.*"(.*)"/\1/' | sort -u)
check_true "the panel answers keys at all" test -n "$keys"
# Comments do not count. A mutation run proved it: the only "(a)" left after
# the label lost it was the comment explaining the label.
shown=$(cat "${QML[@]}" | grep -vE '^[[:space:]]*//')
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
  }' "${QML[@]}")
check "icon-only buttons with no tooltip" "" "$unlabelled"

section "every word on screen is English"
# The Language rule, which has no exception for a label: a string in a second
# language is the one a later grep misses.
foreign=$(grep -rnP '[áéíóúñÁÉÍÓÚÑ¿¡]' "${QML[@]}" "$ROOT"/replicant.js "$ROOT"/bin "$ROOT"/README.md \
            "$ROOT"/CONTRIBUTING.md "$ROOT"/docs 2>/dev/null || true)
check "lines with letters English does not use" "" "$foreign"

section "one word for one state"
# The scope button says Off, the legend says off and a card says "3 off". The
# row and the stat card said "not synced": two words for one state.
off_row=$(grep -oE 'if \(st === "off"\) return "[^"]+"' "$ROOT/replicant.js" | sed -E 's/.*return "(.*)"/\1/')
off_chip=$(grep -oE '"⊘ " \+ root\.nOff \+ " [^"]+"' "$PANEL" | sed -E 's/.*" ([^"]+)"$/\1/')
check_contains "the row calls it off"                  "off" "$off_row"
check_contains "…and so does its chip on the Overview" "off" "$off_chip"

section "panel actions say and do the same thing"
panel_code=$(cat "${QML[@]}")
check_false "the panel has no copy without saving action" grep -qF 'Copy without saving' <<<"$panel_code"
check_false "the removed copy action has no handler" grep -qF 'doBackup' "$PANEL"
check_true "the main Save uses the canonical full transaction" \
  grep -qF '[root.cli, "save", "--all", "--auto"]' "$PANEL"
check_true "Untrack has its own result job" \
  grep -qF 'controller.run("untrack", [root.cli, "untrack", id], { label: "Untrack" })' "$PANEL"
check_true "Forget has its own result job" \
  grep -qF 'controller.run("forget", [root.cli, "forget", arg], { label: "Forget" })' "$PANEL"
check_true "backup removal has its own result job" \
  grep -qF 'controller.run("prune-backups", [root.cli, "backups", "--prune", "--apply"], { label: "Remove backups" })' "$PANEL"
check_false "bulk confirmations hide internal action identifiers" \
  grep -qF '"Apply '\''" + action + "'\'' to "' "$PANEL"

section "status failure is not first-time setup"
check_true "the panel stores a status error" grep -qF 'property string statusError' "$PANEL"
check_true "the panel offers a status Retry action" grep -qF 'text: "Retry"' "$PANEL"
check_true "the header calls failed status unavailable" \
  grep -qF 'root.statusError !== "" ? "status unavailable"' "$PANEL"
check_true "the setup screen excludes status failures" \
  grep -qF 'visible: root.asked && root.statusError === "" && !root.ready' "$PANEL"

section "deferred panel data starts only when its view needs it"
open_body=$(sed -n '/^[[:space:]]*function open() {/,/^[[:space:]]*}/p' "$PANEL")
check_false "opening the panel does not load setup status" grep -qF 'loadSetupStatus' <<<"$open_body"
check_false "opening the panel does not load suggestions" grep -qF 'loadSuggestions' <<<"$open_body"
check_false "opening the panel does not load restore history" grep -Eq 'loadBackups|loadDeleted' <<<"$open_body"
check_true "the Configs tab loads suggestions" grep -qF 'root.activeTab === "configs"' "$PANEL"
check_true "the Restore tab loads backups" grep -qF 'root.activeTab === "restore"' "$PANEL"
check_true "keyboard help loads shortcuts on demand" grep -qF 'if (root.keyboardHelpOpen) root.loadShortcuts()' "$PANEL"
check_true "deferred errors offer a retry" grep -qF 'panel.suggestError !== ""' "$ROOT/components/AddFilesCard.qml"
check_true "restore history has an empty state" grep -qF 'No restore backups exist.' "$ROOT/components/RestoreTab.qml"

section "GitHub API auth and Git transport are separate"
check_false "the panel does not call API authentication HTTPS" grep -qF 'GitHub HTTPS' <<<"$panel_code"
check_true "the panel names GitHub API authentication" grep -qF 'GitHub API:' <<<"$panel_code"
check_true "SSH remains a transport choice" grep -qF 'text: root.sshReady() ? "SSH" : "SSH unavailable"' "$PANEL"

section "installation exposes and preserves the bar position"
check "new widgets default to the center section" "center" \
  "$(jq -r '.barWidget.defaultSection' "$ROOT/manifest.json")"
interactive_install='omarchy plugin add https://github.com/tymurbogach/replicant --enable'
check_true "the README shows the interactive install" grep -qF "$interactive_install" "$ROOT/README.md"
check_false "the interactive install does not bypass the position question" \
  grep -qF "$interactive_install --yes" "$ROOT/README.md"
check_true "the README gives an automatic add command" \
  grep -qF 'omarchy plugin add https://github.com/tymurbogach/replicant --yes' "$ROOT/README.md"
check_true "the automatic path chooses a section explicitly" \
  grep -qF 'omarchy plugin enable io.github.tymurbogach.replicant --section center --after omarchy.clock' "$ROOT/README.md"
check_true "later moves use the live Omarchy bar command" \
  grep -qF 'omarchy bar move io.github.tymurbogach.replicant --section <left|center|right>' "$ROOT/README.md"

section "the bar names the missing state"
# Regression test for the missing-file defect. A saved file
# deleted from this machine must move the bar off "in sync", so the bar has to
# read the missing state the way it reads unsaved and incoming. Comments do
# not count: only code outside comments moves the icon.
code=$(grep -vE '^[[:space:]]*//' "$ROOT/BarWidget.qml")
check_contains "the bar names the missing state" "missing" "$code"

section "a card's subtitle fits its card"
# A card header elides its subtitle, and the end goes first. The key check above
# passed while the panel showed "…backing up yet  (…": the "(a)" was in the
# file and not on the screen. Measured on a capture: 57 characters fit, 58 did
# not. Bound subtitles are the categories', which test-core.sh measures.
section "a card's subtitle fits its card"
# A card header elides its subtitle, and the end goes first. The key check above
# passed while the panel showed "…backing up yet  (…": the "(a)" was in the
# file and not on the screen. Measured on a capture: 57 characters fit, 58 did
# not. Bound subtitles are the categories', which test-core.sh measures.
while IFS= read -r sub; do
  [[ -n "$sub" ]] || continue
  check_true "fits in 57: ${sub:0:30}…" test "${#sub}" -le 57
done < <(grep -ohE 'subtitle: "[^"]*"' "${QML[@]}" | sed -E 's/subtitle: "(.*)"/\1/')

section "category icons survive as single glyphs"
# The category icons are pasted supplementary-plane glyphs (4-byte UTF-8). A
# stray re-encoding truncates them into different symbols with no error, the
# way Panel.qml's code-point comment describes. Pin the encoding and the shape.
check_true "categories.sh is valid UTF-8" iconv -f UTF-8 -t UTF-8 "$ROOT/bin/lib/categories.sh"
while IFS='|' read -r id icon rest; do
  [[ -n "$id" ]] || continue
  check "icon of $id is one glyph" "1" "${#icon}"
  check_false "icon of $id is not a replacement mark" test "$icon" = "?"
done < <(sed -n '/^CATEGORIES=(/,/^)/p' "$ROOT/bin/lib/categories.sh" | grep -oE '"[a-z]+\|[^|]+\|' | tr -d '"')

summary
