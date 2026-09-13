import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BorderSurface {
  id: sc
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var group: ({})
  readonly property bool expanded: panel.isOpen(sc.group.id)

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
      icon: sc.group.icon
      title: sc.group.name
      subtitle: sc.group.description
      countText: String((sc.group.items || []).length)
      // Not "changed": one tab to the left that word counts files waiting to
      // be saved, and here it counts values that differ from what Omarchy
      // ships — two different questions under one word, two tabs apart.
      // "customised" is the answer to this one, and it pairs with the text
      // it alternates with.
      statusText: sc.group.changed > 0 ? sc.group.changed + " customised" : "as Omarchy ships"
      statusHighlight: sc.group.changed > 0
      expanded: sc.expanded
      onToggled: panel.toggleCard(sc.group.id)
    }

    Column {
      width: parent.width
      visible: sc.expanded
      spacing: Style.space(2)
      PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }
      Repeater {
        model: sc.expanded ? (sc.group.items || []) : []
        delegate: SettingRow { panel: sc.panel;
          required property var modelData
          setting: modelData
          width: scCol.width
        }
      }
      Item { width: 1; height: Style.space(4) }
    }
  }
}
