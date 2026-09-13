import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// An accordion header. Fixed height on purpose: it holds a Row anchored to
// its vertical centre, and deriving the height from that Row at the same time
// is a parent-height <-> child-position feedback loop (Qt logs "polish()
// loop" and the row collapses to nothing).
Item {
  id: ch
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string icon: ""
  property string title: ""
  property string subtitle: ""
  property string statusText: ""
  property bool statusHighlight: false
  property string countText: ""
  property bool expanded: false
  signal toggled()

  implicitHeight: Style.space(46)

  MouseArea {
    id: hitbox
    anchors.fill: parent
    hoverEnabled: true
    onClicked: ch.toggled()
  }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(10)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      text: ch.expanded ? panel.icDown : panel.icRight
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      text: ch.icon
      color: hitbox.containsMouse || ch.expanded ? Color.accent : panel.fg
      font.family: panel.ff; font.pixelSize: Style.font.iconLarge
    }
    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(34) - statusCol.width - parent.spacing * 3
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        text: ch.title
        color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.subtitle; font.bold: true
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: ch.subtitle
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    Column {
      id: statusCol
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(84)
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: ch.countText
        color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.subtitle
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: ch.statusText
        color: ch.statusHighlight ? Color.accent : panel.dim
        font.family: panel.ff; font.pixelSize: Style.font.caption
      }
    }
  }
}
