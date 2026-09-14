import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The name of a list inside a card, such as "Or one area". Omarchy's own
// section header, padded like a row.
Item {
  id: cl
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string text: ""
  width: parent ? parent.width : 0
  implicitHeight: Style.space(26)
  PanelSectionHeader {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    anchors.bottomMargin: Style.space(2)
    text: cl.text
    foreground: panel.fg
    fontFamily: panel.ff
    elide: Text.ElideRight
  }
}
