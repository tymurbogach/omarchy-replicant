import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// Every machine that saves into this repo, its profile, and when it last
// saved. With two machines this answers "did the desktop actually push?",
// which is why the repo exists. The remote, the branch and this machine's
// name used to be a table of their own, and nobody read it.
Column {
  id: mc
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  readonly property string url: R.webUrl(panel.repoState.remote || "")
  spacing: Style.space(2)

  Item {
    width: mc.width
    implicitHeight: Style.space(28)
    PanelSectionHeader {
      anchors.left: parent.left
      anchors.right: ghBtn.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Machines on " + (panel.repoState.remote_name || "this repo")
      foreground: panel.fg
      fontFamily: panel.ff
    }
    Button {
      id: ghBtn
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: mc.url !== ""
      text: "Open on GitHub"; iconText: panel.icGithub; bordered: false
      foreground: panel.dim; fontFamily: panel.ff
      fontSize: Style.font.caption
      tooltipText: mc.url
      onClicked: panel.openUrl(mc.url)
    }
  }

  Repeater {
    model: panel.repoState.machines || []
    delegate: Item {
      id: machineRow
      required property var modelData
      width: mc.width
      implicitHeight: Style.space(26)
      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: panel.icMachine
          color: machineRow.modelData.current ? Color.accent : panel.dim
          font.family: panel.ff; font.pixelSize: Style.font.body
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: machineRow.modelData.name
          color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.body
          font.bold: machineRow.modelData.current
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: machineRow.modelData.current
          text: "this machine"
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          // A machine with no recorded profile guessed one from its chassis.
          text: machineRow.modelData.profile
              ? machineRow.modelData.profile + " profile"
              : (machineRow.modelData.current ? panel.profileName + " profile (guessed)" : "no profile")
          color: Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: (machineRow.modelData.last_epoch || 0) > 0
                ? "saved " + R.agoText(machineRow.modelData.last_epoch)
                : (machineRow.modelData.last_save ? "saved " + machineRow.modelData.last_save : "no saves yet")
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
