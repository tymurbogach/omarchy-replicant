import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BorderSurface {
  id: cc
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var card: ({})
  readonly property bool expanded: panel.isOpen(cc.card.id)

  // Height derives from the column, so the column is anchored to the TOP and
  // never centred — centring inside a parent sized by that same child is the
  // feedback loop described on CardHeader.
  implicitHeight: ccCol.implicitHeight
  radius: Style.cornerRadius
  color: cc.card.changed > 0 ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.07)
                             : Style.controlFill(false, false, panel.fg, Color.accent)
  borderSpec: Border.controlSpec(cc.expanded ? "focus" : "normal", panel.fg, Color.accent)

  Column {
    id: ccCol
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 0

    CardHeader { panel: cc.panel;
      width: parent.width
      icon: cc.card.icon
      title: cc.card.label
      subtitle: cc.card.description
      countText: String(cc.card.count)
      statusText: cc.card.incoming > 0 ? cc.card.incoming + " to restore"
                : cc.card.changed > 0 ? cc.card.changed + " changed"
                : cc.card.off > 0 ? cc.card.off + " off" : "in sync"
      statusHighlight: cc.card.changed > 0 || cc.card.incoming > 0
      expanded: cc.expanded
      onToggled: panel.toggleCard(cc.card.id)
    }

    Column {
      width: parent.width
      visible: cc.expanded
      spacing: Style.space(2)

      PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }

      // Shortcuts is the one area where the files are not the point: what you
      // want to see is the keyboard. The file row is still there below.
      Column {
        width: parent.width
        visible: cc.card.id === "shortcuts"
        spacing: Style.space(2)
        ShortcutsView { panel: cc.panel; width: parent.width }
      }

      Repeater {
        model: cc.expanded ? cc.card.rows : []
        delegate: FileRow { panel: cc.panel;
          required property var modelData
          config: modelData
          width: ccCol.width
        }
      }

      // The selling point, said out loud where it matters: not "we copied
      // your files back" but "here is the Omarchy command that puts this
      // back properly".
      Item {
        width: parent.width
        implicitHeight: Style.space(28)
        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.rightMargin: Style.spacing.rowPaddingX
          spacing: Style.space(6)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: panel.icInfo
            color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(20)
            text: cc.card.method
            color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
