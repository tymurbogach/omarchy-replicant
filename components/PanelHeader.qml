import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The panel's title: the plugin's name and version, this machine's state in a
// few words, and the update and refresh buttons. Fixed height: every child is
// centred on it, and a height taken from those children would be the
// parent-height and child-position loop.
Item {
  id: hdr
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  implicitHeight: Style.space(56)

  Text {
    id: logo
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: panel.icReplicant
    color: Color.accent
    font.family: panel.ff
    font.pixelSize: Math.round(Style.font.display * 1.25)
  }

  Column {
    anchors.left: logo.right
    anchors.leftMargin: Style.space(12)
    anchors.right: trailing.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(3)

    Row {
      spacing: Style.space(8)
      Text {
        text: "Omarchy Replicant"
        color: panel.fg
        font.family: panel.ff
        font.pixelSize: Math.round(Style.font.heading * 1.25)
        font.bold: true
      }
      // The version, at the end of the name, where a person looks for it.
      BorderSurface {
        anchors.verticalCenter: parent.verticalCenter
        visible: panel.versionText !== ""
        implicitWidth: verText.implicitWidth + Style.space(12)
        implicitHeight: verText.implicitHeight + Style.space(4)
        color: "transparent"
        radius: Style.cornerRadius
        borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)
        Text {
          id: verText
          anchors.centerIn: parent
          text: panel.versionText
          color: panel.dim
          font.family: panel.ff
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
    Text {
      width: parent.width
      text: panel.metaText.toUpperCase()
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      elide: Text.ElideRight
    }
  }

  Row {
    id: trailing
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)

    // Only when there is something to install. The check itself runs when the
    // panel opens, at most every six hours, and from "Check for updates".
    Button {
      anchors.verticalCenter: parent.verticalCenter
      visible: panel.updateAvailable
      text: "Update to " + panel.updateInfo.latest
      iconText: panel.icUpdate
      bordered: true
      fontSize: Style.font.bodySmall
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      foreground: Color.accent
      accent: Color.accent
      fontFamily: panel.ff
      enabled: !panel.busy
      tooltipText: panel.updateTooltip
      onClicked: panel.askUpdate()
    }
    Button {
      anchors.verticalCenter: parent.verticalCenter
      iconText: panel.icRefresh
      iconSpinning: panel.busy
      bordered: false
      foreground: panel.busy ? Color.accent : panel.dim
      fontFamily: panel.ff
      tooltipText: panel.busy ? panel.busyLabel : "Re-check this machine against the repo  (r)"
      onClicked: panel.refresh()
    }
  }
}
