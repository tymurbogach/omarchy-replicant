import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: srow
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var item: ({})
  readonly property bool isSecret: srow.item.kind === "secret"

  // Fixed height, like every other row here: a row whose height comes from
  // its own centred content is the parent-height/child-position loop.
  implicitHeight: Style.space(50)

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Column {
      width: parent.width - trackBtn.width - parent.spacing
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        text: srow.item.pretty || ""
        color: panel.fg
        font.family: panel.ff; font.pixelSize: Style.font.subtitle
        elide: Text.ElideMiddle
      }
      Text {
        width: parent.width
        text: srow.item.reason || ""
        // A file that holds a credential is not a normal suggestion: tracked
        // as ordinary config it would sit world-readable in a git checkout.
        color: srow.isSecret ? Color.urgent : panel.dim
        font.family: panel.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Button {
      id: trackBtn
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      enabled: !panel.busy
      bordered: true
      text: srow.isSecret ? "Track (600)" : "Track"
      iconText: panel.icPlus
      foreground: panel.fg
      fontFamily: panel.ff
      tooltipText: srow.isSecret
                   ? "Add it to your list as a secret: stored at mode 600, and its contents are never rendered"
                   : "Add it to your list. It is saved with your next Save to GitHub."
      onClicked: panel.doTrack(srow.item.path, srow.item.kind)
    }
  }
}
