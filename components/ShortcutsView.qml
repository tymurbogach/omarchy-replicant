import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Column {
  id: sv
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  spacing: Style.space(2)

  Item {
    width: parent.width
    implicitHeight: Style.space(26)
    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - allBtn.width - Style.space(8)
        text: panel.shortcutsLoaded
              ? (panel.shortcuts.own_count + " of your own · " + panel.shortcuts.active_count + " bound in total")
              : "reading your keybindings…"
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Button {
        id: allBtn
        anchors.verticalCenter: parent.verticalCenter
        text: panel.showAllShortcuts ? "Show mine" : "Show all"
        bordered: false; foreground: panel.dim; fontFamily: panel.ff
        tooltipText: "Omarchy's defaults are not backed up — they come with the distro. Only your overrides are."
        onClicked: panel.showAllShortcuts = !panel.showAllShortcuts
      }
    }
  }

  Text {
    width: parent.width - Style.spacing.rowPaddingX * 2
    x: Style.spacing.rowPaddingX
    visible: panel.shortcutsLoaded && !panel.showAllShortcuts && panel.shortcuts.own_count === 0
    text: "You have not overridden any binding — this machine runs Omarchy's defaults. Edit hypr/bindings.lua below to add one."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
  }

  Repeater {
    model: panel.shortcutsLoaded
           ? (panel.showAllShortcuts ? panel.shortcuts.active : panel.shortcuts.own)
           : []
    delegate: Item {
      id: keyRow
      required property var modelData
      width: sv.width
      implicitHeight: Style.space(20)
      Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(6)
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: Style.space(10)
        Text {
          width: Style.space(150)
          text: keyRow.modelData.key
          color: panel.fg; font.family: panel.mono; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          width: parent.width - Style.space(160)
          text: keyRow.modelData.kind === "unbind"
                ? "(unbound)"
                : (keyRow.modelData.description && keyRow.modelData.description !== ""
                   ? keyRow.modelData.description
                   : (keyRow.modelData.command || ""))
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }
}
