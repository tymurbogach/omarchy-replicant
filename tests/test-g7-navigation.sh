#!/bin/bash
# G7 navigation lifecycle wiring and transient-view restoration contract.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
PANEL="$ROOT/Panel.qml"
RESULT="$ROOT/components/ResultBar.qml"
pass=0; fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
has() {
  local label="$1" pattern="$2" file="$3"
  if grep -Eq "$pattern" "$file"; then ok "$label"; else bad "$label"; fi
}

printf '\n\033[1mG7 transient view lifecycle\033[0m\n'
has "transient views capture one navigation snapshot" 'function openTransient\(kind\)' "$PANEL"
has "transient views restore through one close function" 'function closeTransient\(\)' "$PANEL"
has "edit uses the transient lifecycle" 'root\.openTransient\("edit"\)' "$PANEL"
has "create dialog uses the transient lifecycle" 'root\.openTransient\("create-repo"\)' "$PANEL"
has "the reader uses the transient lifecycle" 'root\.openTransient\("viewer"\)' "$PANEL"
has "confirmations use the transient lifecycle" 'root\.openTransient\("confirmation"\)' "$PANEL"
has "Escape cancels and restores a confirmation" 'else if \(confirmDialog\.opened\) root\.cancelConfirmation\(\)' "$PANEL"
has "the confirmation cancel button restores navigation" 'onCanceled: root\.cancelConfirmation\(\)' "$PANEL"
has "the reader close path restores navigation" 'root\.closeTransient\(\)' "$PANEL"
has "create dialog cancellation restores navigation" 'function closeCreateDialog\(\)' "$PANEL"
has "refreshes do not consume an open transient snapshot" 'root\.navigationSnapshot && root\.transientView === ""' "$PANEL"
has "successful tab navigation clears stale snapshots" 'root\.navigationSnapshot = null' "$PANEL"

printf '\n\033[1mG7 navigation state\033[0m\n'
for field in activeTab openCards openRow openCommits fileSearch stateFilter settingSearch settingFilter manageMode selectedIds selectionAnchor manageCursor; do
  has "snapshot captures $field" "$field: root\.$field" "$PANEL"
done
has "snapshot captures scroll position" 'scrollY: root\.scrollPositions' "$PANEL"
has "snapshot captures logical focus index" 'focusIndex: root\.keyboardFocusIndex' "$PANEL"
has "snapshot captures keyboard focus id" 'focus: root\.keyboardFocus' "$PANEL"
has "snapshot captures text field focus" 'focusedField: root\.focusedFieldId' "$PANEL"
has "restoration restores surviving selections" 'R\.restoreSelection\(rows, snapshot\.selectedIds' "$PANEL"
has "restoration maps keyboard focus by stable id" 'R\.focusIndexFor\(root\.keyboardFocusItems' "$PANEL"
has "errors stay visible until dismissal" 'panel\.lastOutput !== ""' "$RESULT"
has "result bar derives its visible message" 'property string resultLine: R\.resultLine\(root\.lastOutput' "$PANEL"
has "only exclusive work blocks conflicting actions" 'controller\.currentMeta\.exclusive === true' "$PANEL"

echo
if (( fail == 0 )); then printf '\033[32mAll %d checks passed.\033[0m\n' "$pass"; exit 0
else printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1; fi
