import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// The panel's reader: a diff, a restore preview, a health check or the whole
// output of an action. Text that is read, not interacted with, belongs in the
// panel next to what it describes, and not in a terminal that has to be
// dismissed. The six-line footer used to be the only place a preview went.
Rectangle {
  id: tv
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  visible: panel.viewerOpen
  color: Color.popups.background
  function resetScroll() {
    if (scroll) Qt.callLater(function() { scroll.contentY = 0 })
  }
  onVisibleChanged: if (visible) tv.resetScroll()
  Connections {
    target: tv.panel
    function onViewerTextChanged() { if (tv.visible) tv.resetScroll() }
  }

  // Clicks stop here, so nothing under the reader is pressed through it.
  MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

  Item {
    id: bar
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: Style.space(36)
    Text {
      anchors.left: parent.left
      anchors.right: nav.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: panel.viewerTitle
      color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.title
      font.bold: true; elide: Text.ElideMiddle
    }
    Row {
      id: nav
      anchors.right: closeBtn.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      visible: panel.viewerKind === "diff"
      Button {
        text: "Previous"; bordered: false
        foreground: panel.fg; fontFamily: panel.ff; fontSize: Style.font.caption
        tooltipText: "Previous changed entry"
        onClicked: panel.moveDiff(-1)
      }
      Button {
        text: "Next"; bordered: false
        foreground: panel.fg; fontFamily: panel.ff; fontSize: Style.font.caption
        tooltipText: "Next changed entry"
        onClicked: panel.moveDiff(1)
      }
    }
    Button {
      id: closeBtn
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Close"; iconText: panel.icClose; bordered: false
      foreground: panel.fg; fontFamily: panel.ff
      tooltipText: "Back to the panel  (Esc)"
      onClicked: panel.closeViewer()
    }
  }
  PanelSeparator { id: sep; anchors.top: bar.bottom; width: parent.width }

  Flickable {
    id: scroll
    anchors.top: sep.bottom
    anchors.topMargin: Style.space(6)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    contentWidth: Math.max(width, body.implicitWidth)
    contentHeight: body.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: body
      Repeater {
        model: panel.viewerText.split("\n")
        delegate: Text {
          required property string modelData
          readonly property string role: R.lineRole(modelData, panel.viewerKind)
          text: modelData === "" ? " " : modelData
          font.family: panel.mono
          font.pixelSize: Style.font.caption
          font.bold: role === "head"
          textFormat: Text.PlainText
          color: role === "add" || role === "ok" ? panel.okColor
               : role === "del" || role === "bad" ? Color.urgent
               : role === "hunk" || role === "accent" ? Color.accent
               : role === "warn" ? panel.warnColor
               : role === "dim" ? panel.dim
               : panel.fg
        }
      }
    }
  }
}
