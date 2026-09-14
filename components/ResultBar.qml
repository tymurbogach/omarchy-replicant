import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// What the last action did, in one line: a tick or a cross, the sentence
// that matters, and the whole output one click away. While an action runs,
// it says which. Six lines of monospace used to sit here, cut at the end, on
// every tab.
Item {
  id: rb
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  readonly property bool running: panel.busy || panel.busyLabel !== ""
  visible: rb.running || panel.lastOutput !== ""
  implicitHeight: Style.space(38)

  PanelSeparator { id: sep; anchors.top: parent.top; width: parent.width }

  Item {
    anchors.top: sep.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom

    Text {
      id: icon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      text: rb.running ? panel.icRefresh : panel.lastOk ? panel.icCheck : panel.icAlert
      color: rb.running ? Color.accent : panel.lastOk ? panel.okColor : Color.urgent
      font.family: panel.ff; font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      rotation: 0
      RotationAnimation on rotation {
        from: 0; to: 360; duration: 900
        loops: Animation.Infinite
        running: rb.running
      }
    }
    Text {
      anchors.left: icon.right
      anchors.leftMargin: Style.space(8)
      anchors.right: buttons.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: rb.running ? panel.busyLabel : panel.resultLine
      color: rb.running ? panel.fg : panel.lastOk ? panel.fg : Color.urgent
      font.family: panel.ff; font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
    Row {
      id: buttons
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0
      Button {
        visible: !rb.running && panel.lastOutput.indexOf("\n") !== -1
        text: "Details"; bordered: false
        fontSize: Style.font.caption; foreground: panel.dim; fontFamily: panel.ff
        tooltipText: "Everything the command said"
        onClicked: panel.openViewer(panel.lastTitle, panel.lastOutput, "output")
      }
      Button {
        visible: !rb.running
        iconText: panel.icClose; bordered: false; foreground: panel.dim; fontFamily: panel.ff
        tooltipText: "Dismiss"
        onClicked: panel.lastOutput = ""
      }
    }
  }
}
