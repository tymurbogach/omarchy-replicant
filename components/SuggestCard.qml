import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// ── "what else could I be backing up?" ────────────────────────────────────
// Auto-discovery is deliberately NOT how the manifest works: the guarantee
// that only what a human chose gets tracked is the point of the whole tool.
// So this proposes and the user disposes. Every row states why it is here,
// and nothing is added until a button is pressed.
BorderSurface {
  id: sc
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  readonly property bool expanded: panel.isOpen("__suggest")
  readonly property var items: panel.suggestions || []

  visible: sc.items.length > 0
  implicitHeight: scCol.implicitHeight
  radius: Style.cornerRadius
  color: Style.controlFill(false, false, panel.fg, Color.accent)
  borderSpec: Border.controlSpec(sc.expanded ? "focus" : "normal", panel.fg, Color.accent)

  Column {
    id: scCol
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 0

    CardHeader { panel: sc.panel;
      width: parent.width
      icon: panel.icPlus
      title: "Add more files"
      // "(a)" is the key that jumps here, and this is the one place a person
      // reading the list would look for it. It goes last, so it is the first
      // thing an elided subtitle loses: 58 characters were cut on a capture,
      // and test-usability.sh holds every literal subtitle to 57.
      subtitle: "Config on this machine not backed up yet  (a)"
      countText: String(sc.items.length)
      statusText: "not tracked"
      statusHighlight: false
      expanded: sc.expanded
      onToggled: panel.toggleCard("__suggest")
    }

    Column {
      width: parent.width
      visible: sc.expanded
      spacing: Style.space(2)

      PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }

      Repeater {
        model: sc.expanded ? sc.items : []
        delegate: SuggestRow { panel: sc.panel;
          required property var modelData
          item: modelData
          width: scCol.width
        }
      }
    }
  }
}
