import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// This machine at a glance: its state and the two buttons it asks for, the
// machines that share the repo, and what was saved lately.
Column {
  id: ot
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  readonly property string url: R.webUrl(panel.repoState.remote || "")
  spacing: Style.space(10)

  StatusCard { panel: ot.panel; width: ot.width }

  MachinesCard { panel: ot.panel; width: ot.width }

  Card {
    panel: ot.panel
    width: ot.width
    icon: panel.icHistory
    title: "Recent saves"
    subtitle: "Click a save to see the files it changed"

    CardNote { panel: ot.panel; visible: panel.recent.length === 0; text: "Nothing saved yet." }
    Repeater {
      model: panel.recent
      delegate: CommitRow {
        required property var modelData
        panel: ot.panel
        commit: modelData
        width: ot.width
      }
    }
    Row {
      leftPadding: Style.spacing.rowPaddingX - Style.space(6)
      visible: panel.recent.length >= panel.logCount && panel.logCount < 40
      Button {
        text: "Show older saves"; iconText: panel.icDown; bordered: false
        fontSize: Style.font.bodySmall; foreground: panel.dim; fontFamily: panel.ff
        tooltipText: "Eight more"
        onClicked: panel.showOlder()
      }
    }
  }

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
      text: "Repo folder"; iconText: panel.icFolderOpen; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      tooltipText: "Open " + (panel.repoState.repo_dir || "the repo") + " in your file manager"
      onClicked: panel.openRepoFolder()
    }
    Button {
      visible: ot.url !== ""
      text: "GitHub"; iconText: panel.icGithub; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      tooltipText: "Open " + ot.url
      onClicked: panel.openUrl(ot.url)
    }
    Button {
      text: "Copy without saving"; iconText: panel.icCopy; bordered: false
      fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
      enabled: !panel.busy
      tooltipText: "Copy this machine into the local repo. Nothing is committed or pushed."
      onClicked: panel.doBackup()
    }
  }
}
