import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: fact
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string label: ""
  property string value: ""
  width: parent ? parent.width : 0
  implicitHeight: Style.space(18)
  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(10)
    Text {
      width: Style.space(96)
      text: fact.label
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
    Text {
      width: parent.width - Style.space(106)
      text: fact.value
      color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
