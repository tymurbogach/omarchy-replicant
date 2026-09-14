import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// The open half of a file row: where the file and its copy live, who syncs
// it, and every action that applies to it, each with its name. An action that
// does not apply is not drawn. A disabled glyph at a quarter opacity was a
// question every row asked and never answered.
Item {
  id: fd
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var row: ({})
  property string scope: "shared"
  property string syncState: "saved"
  readonly property bool missing: fd.row.exists === false
  readonly property bool isSecret: fd.row.secret === true
  readonly property bool isModified: fd.syncState === "unsaved" || fd.syncState === "unpushed"
  readonly property bool isIncoming: fd.syncState === "incoming"
  readonly property bool isUser: fd.row.source === "user"
  readonly property bool canRestore: fd.row.saved === true && fd.syncState !== "off"
                                     && (fd.syncState === "unsaved" || fd.isIncoming || fd.missing)
  readonly property bool canReset: !fd.missing && fd.row.has_default === true
                                   && fd.syncState !== "default" && fd.row.is_dir !== true

  implicitHeight: col.implicitHeight

  Column {
    id: col
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    // In line with the title of the row, past the badge.
    anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(22)
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Column {
      width: parent.width
      spacing: Style.space(2)
      FactRow { panel: fd.panel; label: "On this machine"
                value: panel.pretty(fd.row.src || "") + (fd.missing ? "   (gone)" : "") }
      FactRow { panel: fd.panel; label: "In your repo"
                value: fd.row.saved === true ? R.repoCopyText(fd.row, fd.scope, panel.profileName) : "not saved yet" }
    }

    // A file deleted from this machine asks one question: bring it back, or
    // stop saving it. The two buttons below are the two answers.
    Text {
      width: parent.width
      visible: fd.missing
      text: fd.row.saved === true
            ? "This file is gone from this machine, and your repo still has a copy. Restore it, or forget it: the copy leaves the repo, and git history keeps it."
            : "This file is not on this machine, and your repo has no copy of it."
      color: panel.warnColor
      font.family: panel.ff; font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Who syncs this file. Three explicit choices instead of a button that
    // cycled through them: a choice is one click, and it says where it lands.
    Item {
      width: parent.width
      height: Style.space(32)
      Text {
        id: syncLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
        text: "Sync"
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      }
      ButtonGroup {
        anchors.left: syncLabel.right
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        focusable: false
        spacing: Style.space(4)
        fontSize: Style.font.bodySmall
        foreground: panel.fg
        accent: Color.accent
        fontFamily: panel.ff
        value: fd.scope
        options: fd.isSecret
          ? [ { value: "shared", label: "Shared", icon: panel.icShared, tooltip: panel.scopeHint("shared") },
              { value: "off", label: "Off", icon: panel.icOff, tooltip: panel.scopeHint("off") } ]
          : [ { value: "shared", label: "Shared", icon: panel.icShared, tooltip: panel.scopeHint("shared") },
              { value: "profile", label: panel.profileName, icon: panel.icProfile, tooltip: panel.scopeHint("profile") },
              { value: "off", label: "Off", icon: panel.icOff, tooltip: panel.scopeHint("off") } ]
        onChanged: function(v) { if (v !== fd.scope) panel.setScope(fd.row.id, v) }
      }
    }
    Text {
      width: parent.width
      text: panel.scopeHint(fd.scope)
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Flow {
      width: parent.width
      spacing: Style.space(4)

      Button {
        visible: !fd.missing
        text: "Edit"; iconText: panel.icEdit; bordered: true
        fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
        tooltipText: "Open it in your editor"
        onClicked: panel.doEdit(fd.row.id)
      }
      Button {
        visible: !fd.missing
        text: fd.isSecret ? "Compare" : "Show changes"; iconText: panel.icDiff; bordered: true
        fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
        tooltipText: fd.isSecret ? "Say whether it differs from your repo. Its contents are never shown."
                                 : "What differs from your repo, or from Omarchy's default"
        onClicked: panel.doDiff(fd.row.id)
      }
      // Save, and Restore for an incoming file, are on the row's head already:
      // they are the one action that the state asks for.
      Button {
        visible: fd.canRestore && !fd.isIncoming
        text: "Restore from repo"; iconText: panel.icFromRepo; bordered: true
        fontSize: Style.font.bodySmall; foreground: fd.isIncoming || fd.missing ? panel.warnColor : panel.fg
        fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "Put back the copy saved in your repo. What is here now is kept as .bak.<epoch>."
        onClicked: panel.askRestoreFile(fd.row)
      }
      Button {
        visible: fd.canReset
        text: "Reset to default"; iconText: panel.icDefault; bordered: true
        fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "Put Omarchy's default back. What is here now is kept as .bak.<epoch>."
        onClicked: panel.ask("reset-file", fd.row.id,
                             "Replace " + fd.row.label + " with Omarchy's default?\n\nYour current version is kept as .bak.<epoch>.",
                             "Reset")
      }
      // Only on the user's own entries. A shipped entry is switched off
      // instead, which keeps its row and its copy.
      Button {
        visible: fd.isUser && !fd.missing
        text: "Stop tracking"; iconText: panel.icUntrack; bordered: true
        fontSize: Style.font.bodySmall; foreground: panel.dim; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "It leaves your list, and its copy leaves the repo. The file here is untouched, and git history keeps the copy."
        onClicked: panel.ask("untrack", fd.row.id,
                             "Stop tracking " + fd.row.label + "?\n\nThe file on this machine is untouched. Its copy leaves your repo, and git history keeps it: Restore, Deleted from your repo, brings it back.",
                             "Stop tracking")
      }
      Button {
        visible: fd.missing && fd.row.saved === true
        text: "Forget it"; iconText: panel.icUntrack; bordered: true
        fontSize: Style.font.bodySmall; foreground: panel.dim; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "The copy leaves your repo too. Git history keeps it, and the Restore tab can bring it back."
        onClicked: panel.ask("forget", fd.row.id,
                             "Forget " + fd.row.label + "?\n\nIt is gone from this machine. Its copy leaves your repo in one commit, and git history keeps it: Restore, Deleted from your repo, brings it back."
                             + (fd.isUser ? "" : "\n\nIt ships with the plugin, so it shows again if the file comes back on any machine."),
                             "Forget")
      }
    }
  }
}
