import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BorderSurface {
  id: card
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string title: ""
  property string body: ""
  property string actionText: ""
  property bool actionAccent: false
  signal preview()
  signal act()

  implicitHeight: cardCol.implicitHeight + Style.spacing.controlPaddingY * 2
  radius: Style.cornerRadius
  color: Style.controlFill(false, false, panel.fg, Color.accent)
  borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)

  Column {
    id: cardCol
    // Anchored to the top, never verticalCenter: this card's height is
    // derived from this column, and centring the column inside a parent whose
    // height depends on it is a parent-height <-> child-position feedback
    // loop (Qt logs "polish() loop" and the card collapses to nothing).
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.spacing.controlPaddingY
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(6)

    Text {
      width: parent.width
      text: card.title
      color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.subtitle; font.bold: true
    }
    Text {
      width: parent.width
      text: card.body
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
    }
    Row {
      spacing: Style.space(8)
      Button {
        text: "Preview"; iconText: panel.icDiff; bordered: false
        foreground: panel.fg; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "Shows what would change and writes nothing"
        onClicked: card.preview()
      }
      Button {
        text: card.actionText; iconText: panel.icDefault; bordered: true
        foreground: panel.fg; accent: card.actionAccent ? Color.accent : Color.urgent; fontFamily: panel.ff
        enabled: !panel.busy
        onClicked: card.act()
      }
    }
  }
}
