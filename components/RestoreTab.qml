import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// Every way back, in the order a person reaches for them: what the repo
// holds, what Omarchy ships, what left the repo, the third-party code that
// is not installed here, and the version that a restore replaced.
//
// Each card says how much it would change before a button is pressed, and a
// preview opens in the reader instead of six lines at the foot of the panel.
Column {
  id: rt
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  spacing: Style.space(12)

  // ── from your repo ──────────────────────────────────────────────────────
  BorderSurface {
    width: rt.width
    implicitHeight: repoCol.implicitHeight + Style.spacing.controlPaddingY * 2 + Style.space(6)
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, panel.fg, Color.accent)
    borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)

    Column {
      id: repoCol
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.spacing.controlPaddingY + Style.space(3)
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Item {
        width: parent.width
        height: Style.space(40)
        Text {
          id: repoIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          text: panel.icPull
          color: panel.restoreDiffers > 0 ? panel.warnColor : Color.accent
          font.family: panel.ff; font.pixelSize: Style.font.display
        }
        Column {
          anchors.left: repoIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)
          Text {
            width: parent.width
            text: "From your repo"
            color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.heading; font.bold: true
          }
          Text {
            width: parent.width
            text: panel.restoreDiffers > 0
                  ? R.plural(panel.restoreDiffers, "file") + " on this machine differ from your repo"
                  : "This machine matches your repo"
            color: panel.restoreDiffers > 0 ? panel.warnColor : panel.dim
            font.family: panel.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
      Text {
        width: parent.width
        text: "Puts back what your repo holds, then runs what Omarchy needs: the theme is applied again, Hyprland reloads, terminals restart. Every file it overwrites is kept as .bak.<epoch>."
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
      }
      Row {
        spacing: Style.space(8)
        Button {
          text: "Preview"; iconText: panel.icEye; bordered: true
          foreground: panel.fg; fontFamily: panel.ff
          enabled: !panel.busy
          tooltipText: "Show what a restore would change. It writes nothing."
          onClicked: panel.runPreview("Restore everything: preview", ["restore", "--dry-run"])
        }
        Button {
          text: "Restore everything"; iconText: panel.icFromRepo; bordered: true
          foreground: Color.accent; accent: Color.accent; fontFamily: panel.ff
          enabled: !panel.busy
          onClicked: panel.ask("restore-all", "",
            "Restore EVERYTHING from your GitHub repo onto this machine?\n\n"
            + (panel.restoreDiffers > 0 ? R.plural(panel.restoreDiffers, "file") + " differ from your repo. " : "")
            + "Every file it overwrites is backed up as .bak.<epoch> first.",
            "Restore")
        }
      }

      PanelSeparator { width: parent.width }

      Text {
        width: parent.width
        text: "Or one area"
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; font.bold: true
      }
      Repeater {
        model: panel.areaSummaries
        delegate: Item {
          id: areaRow
          required property var modelData
          width: repoCol.width
          implicitHeight: Style.space(30)
          Text {
            id: areaIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            text: areaRow.modelData.icon
            color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body
          }
          Text {
            anchors.left: areaIcon.right
            anchors.right: areaStatus.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: areaRow.modelData.label
            color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            id: areaStatus
            anchors.right: areaButtons.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: areaRow.modelData.differ > 0 ? R.plural(areaRow.modelData.differ, "file") + " differ"
                                              : "matches · " + R.plural(areaRow.modelData.count, "file")
            color: areaRow.modelData.differ > 0 ? panel.warnColor : panel.dim
            font.family: panel.ff; font.pixelSize: Style.font.caption
          }
          Row {
            id: areaButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            Button {
              iconText: panel.icEye; bordered: false
              foreground: panel.dim; fontFamily: panel.ff
              enabled: !panel.busy
              tooltipText: "Preview " + areaRow.modelData.label + ". It writes nothing."
              onClicked: panel.runPreview(areaRow.modelData.label + ": preview",
                                          ["restore", "--dry-run", "--only", areaRow.modelData.id])
            }
            Button {
              text: "Restore"; bordered: false
              fontSize: Style.font.caption
              foreground: areaRow.modelData.differ > 0 ? panel.fg : panel.dim
              fontFamily: panel.ff
              enabled: !panel.busy
              tooltipText: areaRow.modelData.method
              onClicked: panel.ask("restore-cat", areaRow.modelData.id,
                "Restore " + areaRow.modelData.label + " from your repo?\n\n" + areaRow.modelData.method
                + "\n\nEvery file it overwrites is backed up as .bak.<epoch> first.",
                "Restore")
            }
          }
        }
      }
    }
  }

  // ── Omarchy's defaults ──────────────────────────────────────────────────
  BorderSurface {
    width: rt.width
    implicitHeight: resetCol.implicitHeight + Style.spacing.controlPaddingY * 2 + Style.space(6)
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, panel.fg, Color.accent)
    borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)

    Column {
      id: resetCol
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.spacing.controlPaddingY + Style.space(3)
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Item {
        width: parent.width
        height: Style.space(40)
        Text {
          id: resetIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          text: panel.icDefault
          color: panel.dim
          font.family: panel.ff; font.pixelSize: Style.font.display
        }
        Column {
          anchors.left: resetIcon.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)
          Text {
            width: parent.width
            text: "Omarchy's defaults"
            color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.heading; font.bold: true
          }
          Text {
            width: parent.width
            text: panel.resetDiffers > 0
                  ? R.plural(panel.resetDiffers, "file") + " differ from what Omarchy ships"
                  : "Every file with a default is at it"
            color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
      Text {
        width: parent.width
        text: "Throws away your changes to each file Omarchy ships a default for, through omarchy refresh config. Your repo keeps its copy, so you can restore from it afterwards."
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
      }
      Row {
        spacing: Style.space(8)
        Button {
          text: "Preview"; iconText: panel.icEye; bordered: true
          foreground: panel.fg; fontFamily: panel.ff
          enabled: !panel.busy
          tooltipText: "Show what a reset would change. It writes nothing."
          onClicked: panel.runPreview("Reset to Omarchy's defaults: preview", ["reset-all", "--dry-run"])
        }
        Button {
          text: "Reset to factory"; iconText: panel.icDefault; bordered: true
          foreground: panel.fg; accent: Color.urgent; fontFamily: panel.ff
          enabled: !panel.busy && panel.resetDiffers > 0
          onClicked: panel.ask("reset-all", "",
            "Reset " + R.plural(panel.resetDiffers, "customised file") + " to the Omarchy default?\n\nYour repo keeps its copy, and each file is backed up as .bak.<epoch> first.",
            "Reset")
        }
      }
    }
  }

  // ── deleted from your repo ──────────────────────────────────────────────
  // A copy that left the repo is still in git history: forgotten, untracked,
  // or deleted from a tracked folder. One button undoes one commit's worth.
  Column {
    width: rt.width
    visible: panel.deletedList.length > 0
    spacing: Style.space(2)
    PanelSectionHeader { width: parent.width; text: "Deleted from your repo"; foreground: panel.fg; fontFamily: panel.ff }
    Text {
      width: parent.width
      text: "Git history kept these. Bring back restores the copy, tracks it again if it was untracked, and puts it on this machine."
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
    }
    Item { width: 1; height: Style.space(4) }
    Repeater {
      model: panel.deletedList.slice(0, 8)
      delegate: Item {
        id: delRow
        required property var modelData
        readonly property var first: R.repoPathLabel(delRow.modelData.files[0])
        width: rt.width
        implicitHeight: Style.space(38)
        Text {
          id: delIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          text: panel.icRecover
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body
        }
        Column {
          anchors.left: delIcon.right
          anchors.right: bringBack.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs
          Text {
            width: parent.width
            text: delRow.first.label + (delRow.modelData.count > 1 ? "  +" + (delRow.modelData.count - 1) + " more" : "")
            color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
          Text {
            width: parent.width
            text: R.agoText(delRow.modelData.epoch) + "  ·  " + delRow.modelData.subject
            color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        Button {
          id: bringBack
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Bring back"; iconText: panel.icRecover; bordered: true
          fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
          enabled: !panel.busy
          tooltipText: "From " + delRow.modelData.short + ":\n" + R.nameList(delRow.modelData.files.map(function(f) { return R.repoPathLabel(f).label }), 10)
          onClicked: panel.askRecover(delRow.modelData)
        }
      }
    }
  }

  // ── third-party plugins and themes ──────────────────────────────────────
  // Recorded in the inventory, not installed here. Restoring never fetches
  // someone else's current code on its own: one Install button each.
  Column {
    width: rt.width
    visible: panel.pendingReinstalls.length > 0
    spacing: Style.space(2)
    PanelSectionHeader { width: parent.width; text: "Third-party plugins and themes"; foreground: panel.fg; fontFamily: panel.ff }
    Text {
      width: parent.width
      text: "Recorded in your inventory, not installed here. They come from someone else's repo, so restoring never fetches them: Install brings in whatever is at that address right now."
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
    }
    Repeater {
      model: panel.pendingReinstalls
      delegate: Item {
        id: reinstallRow
        required property var modelData
        width: rt.width
        implicitHeight: Style.space(32)
        Text {
          id: riIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          text: reinstallRow.modelData.kind === "theme" ? panel.icTheme : panel.icPlugin
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.body
        }
        Text {
          anchors.left: riIcon.right
          anchors.right: reinstallBtn.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: reinstallRow.modelData.id + "   " + reinstallRow.modelData.origin
          color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Button {
          id: reinstallBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Install"; iconText: panel.icFromRepo; bordered: true
          fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
          enabled: !panel.busy
          tooltipText: "Fetch " + reinstallRow.modelData.origin + " and install it now"
          onClicked: panel.askInstall(reinstallRow.modelData.kind, reinstallRow.modelData.id,
                                      reinstallRow.modelData.origin)
        }
      }
    }
  }

  // ── the safety net ──────────────────────────────────────────────────────
  // Everything above promises "a .bak.<epoch> is kept". This is where that
  // promise is collected on: the bottom of the tab, where a person stands
  // when a restore went wrong.
  Column {
    width: rt.width
    visible: panel.backupRows.length > 0
    spacing: Style.space(2)
    PanelSectionHeader { width: parent.width; text: "Undo a restore"; foreground: panel.fg; fontFamily: panel.ff }
    Text {
      width: parent.width
      text: "Every write kept the version it replaced. Undo swaps the newest one back, and keeps what it replaces, so an undo can be undone too."
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
    }
    Repeater {
      model: panel.backupRows
      delegate: Item {
        id: bakRow
        required property var modelData
        width: rt.width
        implicitHeight: Style.space(32)
        Text {
          anchors.left: parent.left
          anchors.right: undoBtn.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          // "same" is the one that is safe to drop, and the one where Undo
          // would change nothing, which is worth saying before it is pressed.
          text: bakRow.modelData.id + "   " + R.agoText(bakRow.modelData.epoch)
              + (bakRow.modelData.state === "same" ? "   ·  identical to the file you have"
                : bakRow.modelData.state === "gone" ? "   ·  the file itself is gone" : "")
              + (bakRow.modelData.older > 0 ? "   ·  +" + bakRow.modelData.older + " older" : "")
          color: bakRow.modelData.state === "same" ? panel.dim : panel.fg
          font.family: panel.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Button {
          id: undoBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Undo"; iconText: panel.icDefault; bordered: false
          fontSize: Style.font.bodySmall
          foreground: bakRow.modelData.state === "same" ? panel.dim : panel.fg
          fontFamily: panel.ff
          enabled: !panel.busy && bakRow.modelData.state !== "same"
          tooltipText: bakRow.modelData.state === "same"
            ? "This backup is identical to the file you have. Undoing it would change nothing."
            : "Put this version back, and keep the current one as the new .bak"
          onClicked: panel.ask("undo", bakRow.modelData.id,
            "Put back the version of " + bakRow.modelData.id + " from "
              + R.agoText(bakRow.modelData.epoch) + "?\n\nThe version you have now becomes the new .bak.<epoch>, so this can be undone again.",
            "Undo")
        }
      }
    }
    Button {
      text: "Remove all backups"; iconText: panel.icUntrack; bordered: false
      fontSize: Style.font.caption; foreground: panel.dim; fontFamily: panel.ff
      enabled: !panel.busy
      tooltipText: "Delete every .bak.<epoch> beside your configs. Your repo is not touched."
      onClicked: panel.ask("prune-backups", "",
        "Delete every .bak.<epoch> next to your configs?\n\nThis is the only copy of what those files looked like before each restore. Your repo is not touched.",
        "Remove")
    }
  }
}
