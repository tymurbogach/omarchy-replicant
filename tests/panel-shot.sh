#!/bin/bash
# panel-shot.sh <out.png> [tab] [cards] [js]: render the panel offscreen into a
# PNG, with Omarchy's own components. It is for the nights when the session is
# locked or the display is off, and a shell restart is not allowed.
#
#   tests/panel-shot.sh /tmp/o.png                          the Overview
#   tests/panel-shot.sh /tmp/c.png configs appearance       Configs, one card open
#   tests/panel-shot.sh /tmp/c.png configs "" 'p.openRow = "hypr/input.lua"'
#
# STATUS=<file> renders a saved `status --json` payload instead of this
# machine's. SCROLL=<px> scrolls the body before the capture. LATE_JS runs
# just before the capture, after the panel's own commands have answered.
#
# The panel runs the plugin's real read-only commands (log, backups, suggest,
# deleted, update-check). The KeyboardPanel is replaced by a plain item that
# draws the same card, so the bar and the placement of the popup are not in
# the picture. It does not replace the check after a reload (hard rule 4).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
SHELL_DIR="${OMARCHY_SHELL:-/usr/share/omarchy/shell}"
out="${1:?usage: tests/panel-shot.sh <out.png> [tab] [cards] [js]}"
tab="${2:-overview}"; cards="${3:-}"; js="${4:-}"

[[ -d "$SHELL_DIR/Ui" ]] || { echo "panel-shot: needs the Omarchy shell at $SHELL_DIR" >&2; exit 2; }
command -v quickshell >/dev/null 2>&1 || { echo "panel-shot: needs quickshell" >&2; exit 2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r "$SHELL_DIR/Ui" "$work/Ui"
ln -s "$SHELL_DIR/Commons" "$work/Commons"
ln -s "$SHELL_DIR/services" "$work/services"

cat > "$work/Ui/KeyboardPanel.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Commons

// The real KeyboardPanel is a layer-shell window. This one draws the same
// card as a plain item, so that the panel renders in any window.
Item {
  id: root
  property Item anchorItem: null
  property QtObject bar: null
  property var owner: null
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  property bool open: false
  property Item focusTarget: null
  default property alias contentItem: holder.children
  readonly property real inset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)
  function fittedContentWidth(w, cap) {
    var d = Math.max(1, Number(w) || 1)
    return Math.round(cap !== undefined && Number(cap) > 0 ? Math.min(d, Number(cap)) : d)
  }
  function fittedContentHeight(h, cap) {
    var d = Math.max(inset, (Number(h) || 0) + inset)
    return Math.round(cap !== undefined && Number(cap) > 0 ? Math.min(d, Number(cap)) : d)
  }
  width: contentWidth
  height: contentHeight
  x: 8; y: 8
  BorderSurface {
    id: card
    anchors.fill: parent
    color: Color.popups.background
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    Item {
      id: holder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
    }
  }
}
QML

cat > "$work/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

ShellRoot {
  QtObject {
    id: fakeBar
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property string fontFamily: Style.font.family
    property string position: "top"
    function run(cmd) {}
  }
  FloatingWindow {
    id: win
    implicitWidth: Number(Quickshell.env("SHOT_W") || "720")
    implicitHeight: Number(Quickshell.env("SHOT_H") || "1100")
    color: "#101010"
    function findFlick(it) {
      if (!it) return null
      if (it.flickableDirection !== undefined && it.contentHeight > it.height + 1) return it
      var ch = it.children || []
      for (var i = 0; i < ch.length; i++) { var f = win.findFlick(ch[i]); if (f) return f }
      return null
    }
    function runJs(src) {
      if (src === "") return
      try { (new Function("p", src))(loader.item) } catch (e) { console.warn("panel-shot: " + e) }
    }
    Item {
      id: frame
      anchors.fill: parent
      Loader {
        id: loader
        source: Quickshell.env("SHOT_PANEL")
        onLoaded: { item.bar = fakeBar; statusFile.reload() }
      }
    }
    FileView {
      id: statusFile
      path: Quickshell.env("SHOT_STATUS")
      blockLoading: true
      onLoaded: {
        var p = loader.item
        if (!p) return
        p.repoState = JSON.parse(statusFile.text())
        p.asked = true
        p.open()
        p.activeTab = Quickshell.env("SHOT_TAB") || "overview"
        var cards = (Quickshell.env("SHOT_CARDS") || "").split(",").filter(function(s) { return s !== "" })
        for (var i = 0; i < cards.length; i++) p.toggleCard(cards[i])
        win.runJs(Quickshell.env("SHOT_JS") || "")
        settle.start()
      }
    }
    Timer {
      id: settle
      interval: 3500
      onTriggered: {
        win.runJs(Quickshell.env("SHOT_LATE_JS") || "")
        var sc = Number(Quickshell.env("SHOT_SCROLL") || "0")
        var f = sc > 0 ? win.findFlick(frame) : null
        if (f) f.contentY = Math.min(sc, f.contentHeight - f.height)
        grab.start()
      }
    }
    Timer {
      id: grab
      interval: 500
      onTriggered: frame.grabToImage(function(r) { r.saveToFile(Quickshell.env("SHOT_OUT")); Qt.quit() })
    }
  }
}
QML

status="${STATUS:-}"
if [[ -z "$status" ]]; then
  status="$work/status.json"
  "$ROOT/bin/omarchy-replicant" status --json --no-fetch > "$status"
fi
out=$(realpath -m -- "$out")
rm -f -- "$out"
SHOT_PANEL="file://$ROOT/Panel.qml" SHOT_STATUS="$status" SHOT_TAB="$tab" SHOT_CARDS="$cards" \
SHOT_JS="$js" SHOT_LATE_JS="${LATE_JS:-}" SHOT_SCROLL="${SCROLL:-0}" SHOT_OUT="$out" \
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  timeout 60 quickshell -p "$work" > "$work/log" 2>&1 || true
if [[ -f "$out" ]]; then
  printf '%s\n' "$out"
else
  echo "panel-shot: no image. What quickshell said:" >&2
  grep -E 'WARN|ERROR|Error' "$work/log" >&2 || cat "$work/log" >&2
  exit 1
fi
