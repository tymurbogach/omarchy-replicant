import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The header of every card (Card.qml). The icon sits in the same column as
// the glyph of every row, and the chevron on the right edge.
//
// Fixed height on purpose: it holds a Row anchored to its vertical centre,
// and deriving the height from that Row at the same time is a parent-height
// <-> child-position feedback loop (Qt logs "polish() loop" and the row
// collapses to nothing).
Item {
  id: ch
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string icon: ""
  property string title: ""
  property string subtitle: ""
  property string statusText: ""
  // "" (dim), "accent" (yours, to save) or "warn" (from elsewhere, differs).
  property string statusTone: ""
  property string countText: ""
  // A card that is always open has no chevron and no click.
  property bool collapsible: true
  property bool expanded: false
  signal toggled()

  implicitHeight: Style.space(46)

  MouseArea {
    id: hitbox
    anchors.fill: parent
    enabled: ch.collapsible
    hoverEnabled: true
    cursorShape: ch.collapsible ? Qt.PointingHandCursor : Qt.ArrowCursor
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
      width: Style.space(20)
      horizontalAlignment: Text.AlignHCenter
      text: ch.icon
      color: (ch.collapsible && hitbox.containsMouse) || ch.expanded ? Color.accent : panel.fg
      font.family: panel.ff; font.pixelSize: Style.font.iconLarge
    }
    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(20) - statusCol.width - parent.spacing * 2
             - (ch.collapsible ? Style.space(14) + parent.spacing : 0)
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        text: ch.title
        color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.subtitle; font.bold: true
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: ch.subtitle !== ""
        text: ch.subtitle
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    Column {
      id: statusCol
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        visible: ch.countText !== ""
        horizontalAlignment: Text.AlignRight
        text: ch.countText
        color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.subtitle
      }
      Text {
        width: parent.width
        visible: ch.statusText !== ""
        horizontalAlignment: Text.AlignRight
        text: ch.statusText
        color: ch.statusTone === "warn" ? panel.warnColor : ch.statusTone === "accent" ? Color.accent : panel.dim
        font.family: panel.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
    // On the right edge, where a file row and a save have theirs.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: ch.collapsible
      width: Style.space(14)
      horizontalAlignment: Text.AlignHCenter
      text: ch.expanded ? panel.icDown : panel.icRight
      color: hitbox.containsMouse || ch.expanded ? panel.fg : panel.dim
      font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }
}
