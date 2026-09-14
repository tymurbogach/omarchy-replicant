import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// This machine at a glance: its state and the two buttons it asks for, the
// machines that share the repo, and what was saved lately.
Column {
  id: ot
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  spacing: Style.space(14)

  StatusCard { panel: ot.panel; width: ot.width }

  MachinesCard { panel: ot.panel; width: ot.width }

  Column {
    width: ot.width
    spacing: Style.space(1)
    PanelSectionHeader { width: parent.width; text: "Recent saves"; foreground: panel.fg; fontFamily: panel.ff }
    Item { width: 1; height: Style.space(4) }
    Text {
      width: parent.width
      visible: panel.recent.length === 0
      text: "Nothing saved yet."
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
    Repeater {
      model: panel.recent
      delegate: CommitRow { panel: ot.panel;
        required property var modelData
        commit: modelData
        width: ot.width
      }
    }
    Button {
      visible: panel.recent.length >= panel.logCount && panel.logCount < 40
      text: "Show older saves"; iconText: panel.icHistory; bordered: false
      fontSize: Style.font.caption; foreground: panel.dim; fontFamily: panel.ff
      tooltipText: "Eight more"
      onClicked: panel.showOlder()
    }
  }

  PanelSeparator { width: ot.width }

  // The tools. Each one is read-only or copies into the local repo only.
  Flow {
    width: ot.width
    spacing: Style.space(4)
    Button {
      text: "Health check"; iconText: panel.icShield; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      enabled: !panel.checking
      tooltipText: "Check login, that the repo is private, the hooks and the permissions. It fixes nothing."
      onClicked: panel.doDoctor()
    }
    Button {
      text: "Open repo folder"; iconText: panel.icFolderOpen; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      tooltipText: panel.repoState.repo_dir || ""
      onClicked: panel.openRepoFolder()
    }
    Button {
      text: "Copy without saving"; iconText: panel.icCopy; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      enabled: !panel.busy
      tooltipText: "Copy this machine into the local repo. Nothing is committed or pushed."
      onClicked: panel.doBackup()
    }
    Button {
      text: "Check for updates"; iconText: panel.icUpdate; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      enabled: !panel.updateChecking
      tooltipText: panel.updateTooltip
      onClicked: panel.checkUpdates(true)
    }
  }
}
