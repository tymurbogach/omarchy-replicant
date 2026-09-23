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
// A button that would change nothing is not drawn.
Column {
  id: rt
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  function navigationItem() { return null }
  spacing: Style.space(10)

  // ── from your repo ──────────────────────────────────────────────────────
  Card {
    panel: rt.panel
    width: rt.width
    icon: panel.icPull
    title: "From your repo"
    subtitle: "Put back what your repo holds, then apply it"
    statusText: panel.restoreDiffers > 0 ? R.plural(panel.restoreDiffers, "file") + " differ" : "matches"
    statusTone: panel.restoreDiffers > 0 ? "warn" : ""

    CardNote {
      panel: rt.panel
      text: "The theme is applied again, Hyprland reloads and terminals restart. Every file that a restore overwrites is kept as .bak.<epoch>."
    }
    Row {
      leftPadding: Style.spacing.rowPaddingX
      topPadding: Style.space(2)
      bottomPadding: Style.space(4)
      spacing: Style.space(8)
      Button {
        text: "Preview"; iconText: panel.icEye; bordered: true
        foreground: panel.fg; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: panel.busy ? "Disabled: another Replicant operation is running." : "Show what a restore would change. It writes nothing."
        onClicked: panel.runPreview("Restore everything: preview", ["restore", "--dry-run"])
      }
      Button {
        text: "Restore everything"; iconText: panel.icFromRepo; bordered: true
        foreground: panel.restoreDiffers > 0 ? panel.warnColor : panel.fg
        accent: Color.accent; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: panel.busy ? "Disabled: another Replicant operation is running." : "Write every area back from your repo, and run what each area needs"
        onClicked: panel.ask("restore-all", "",
          "Restore EVERYTHING from your GitHub repo onto this machine?\n\n"
          + (panel.restoreDiffers > 0 ? R.plural(panel.restoreDiffers, "file") + " differ from your repo. " : "")
          + "Every file it overwrites is backed up as .bak.<epoch> first.",
          "Restore")
      }
    }

    CardLabel { panel: rt.panel; text: "Or one area" }
    Repeater {
      model: panel.areaSummaries
      delegate: ListRow {
        id: areaRow
        required property var modelData
        panel: rt.panel
        width: rt.width
        icon: modelData.icon
        title: modelData.label
        meta: modelData.differ > 0 ? R.plural(modelData.differ, "file") + " differ"
                                   : "matches · " + R.plural(modelData.count, "file")
        metaColor: modelData.differ > 0 ? panel.warnColor : panel.dim
        Button {
          anchors.verticalCenter: parent.verticalCenter
          iconText: panel.icEye; bordered: false
          foreground: panel.dim; fontFamily: panel.ff
          enabled: !panel.busy
          tooltipText: panel.busy ? "Disabled: another Replicant operation is running." : "Preview " + areaRow.modelData.label + ". It writes nothing."
          onClicked: panel.runPreview(areaRow.modelData.label + ": preview",
                                      ["restore", "--dry-run", "--only", areaRow.modelData.id])
        }
        RowAction {
          panel: rt.panel
          anchors.verticalCenter: parent.verticalCenter
          visible: areaRow.modelData.differ > 0
          text: "Restore"; iconText: panel.icFromRepo
          foreground: panel.warnColor
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

  // ── Omarchy's defaults ──────────────────────────────────────────────────
  Card {
    panel: rt.panel
    width: rt.width
    icon: panel.icDefault
    title: "Omarchy's defaults"
    subtitle: "Throw away your changes to the files Omarchy ships"
    statusText: panel.resetDiffers > 0 ? R.plural(panel.resetDiffers, "file") + " differ" : "at default"

    CardNote {
      panel: rt.panel
      text: "Each file goes back through omarchy refresh config. Your repo keeps its copy, so you can restore from it afterwards."
    }
    Row {
      leftPadding: Style.spacing.rowPaddingX
      topPadding: Style.space(2)
      bottomPadding: Style.space(4)
      spacing: Style.space(8)
      Button {
        text: "Preview"; iconText: panel.icEye; bordered: true
        foreground: panel.fg; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: panel.busy ? "Disabled: another Replicant operation is running." : "Show what a reset would change. It writes nothing."
        onClicked: panel.runPreview("Reset to Omarchy's defaults: preview", ["reset-all", "--dry-run"])
      }
      Button {
        visible: panel.resetDiffers > 0
        text: "Reset to factory"; iconText: panel.icDefault; bordered: true
        foreground: panel.fg; accent: Color.urgent; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: panel.busy ? "Disabled: another Replicant operation is running." : "Put Omarchy's default back on every file listed in the preview"
        onClicked: panel.ask("reset-all", "",
          "Reset " + R.plural(panel.resetDiffers, "customised file") + " to the Omarchy default?\n\nYour repo keeps its copy, and each file is backed up as .bak.<epoch> first.",
          "Reset")
      }
    }
  }

  // ── deleted from your repo ──────────────────────────────────────────────
  // A copy that left the repo is still in git history: forgotten, untracked,
  // or deleted from a tracked folder. One button undoes one commit's worth.
  Card {
    panel: rt.panel
    width: rt.width
    visible: panel.deletedList.length > 0
    icon: panel.icRecover
    title: "Deleted from your repo"
    subtitle: "Git history kept these copies"
    countText: String(panel.deletedList.length)

    CardNote {
      panel: rt.panel
      text: "Bring back restores the copy, tracks it again if it was untracked, and puts it on this machine."
    }
    Repeater {
      model: panel.deletedList.slice(0, 8)
      delegate: ListRow {
        id: delRow
        required property var modelData
        readonly property var first: R.repoPathLabel(delRow.modelData.files[0])
        panel: rt.panel
        width: rt.width
        icon: panel.icFile
        title: delRow.first.label + (delRow.modelData.count > 1 ? "  +" + (delRow.modelData.count - 1) + " more" : "")
        detail: R.agoText(delRow.modelData.epoch) + "  ·  " + delRow.modelData.subject
        RowAction {
          panel: rt.panel
          anchors.verticalCenter: parent.verticalCenter
          text: "Bring back"; iconText: panel.icFromRepo
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
  Card {
    panel: rt.panel
    width: rt.width
    visible: panel.pendingReinstalls.length > 0
    icon: panel.icPlugin
    title: "Plugins and themes to install"
    subtitle: "In your inventory, and not on this machine"
    countText: String(panel.pendingReinstalls.length)

    CardNote {
      panel: rt.panel
      text: "They come from someone else's repo, so a restore never fetches them. Install brings in whatever is at that address right now."
    }
    Repeater {
      model: panel.pendingReinstalls
      delegate: ListRow {
        id: reinstallRow
        required property var modelData
        panel: rt.panel
        width: rt.width
        icon: reinstallRow.modelData.kind === "theme" ? panel.icTheme : panel.icPlugin
        title: reinstallRow.modelData.id
        detail: R.originLabel(reinstallRow.modelData.origin)
        RowAction {
          panel: rt.panel
          anchors.verticalCenter: parent.verticalCenter
          text: "Install"; iconText: panel.icFromRepo
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
  Card {
    panel: rt.panel
    width: rt.width
    visible: panel.backupRows.length > 0
    icon: panel.icHistory
    title: "Undo a restore"
    subtitle: "The version that each write replaced"
    countText: String(panel.backupRows.length)

    CardNote {
      panel: rt.panel
      text: "Undo swaps the newest backup back and keeps what it replaces, so an undo can be undone too."
    }
    Repeater {
      model: panel.backupRows
      delegate: ListRow {
        id: bakRow
        required property var modelData
        panel: rt.panel
        width: rt.width
        icon: panel.icFile
        title: bakRow.modelData.id
        titleColor: bakRow.modelData.state === "same" ? panel.dim : panel.fg
        // "same" is the one that is safe to drop, and the one where Undo
        // would change nothing, which is worth saying before it is pressed.
        detail: R.agoText(bakRow.modelData.epoch)
                + (bakRow.modelData.state === "gone" ? "  ·  the file itself is gone" : "")
                + (bakRow.modelData.older > 0 ? "  ·  +" + bakRow.modelData.older + " older" : "")
        meta: bakRow.modelData.state === "same" ? "identical to your file" : ""
        RowAction {
          panel: rt.panel
          anchors.verticalCenter: parent.verticalCenter
          visible: bakRow.modelData.state !== "same"
          text: "Undo"; iconText: panel.icDefault
          enabled: !panel.busy
          tooltipText: "Put this version back, and keep the current one as the new .bak"
          onClicked: panel.ask("undo", bakRow.modelData.id,
            "Put back the version of " + bakRow.modelData.id + " from "
              + R.agoText(bakRow.modelData.epoch) + "?\n\nThe version you have now becomes the new .bak.<epoch>, so this can be undone again.",
            "Undo")
        }
      }
    }
    Row {
      leftPadding: Style.spacing.rowPaddingX - Style.space(6)
      Button {
        text: "Remove all backups"; iconText: panel.icUntrack; bordered: false
        fontSize: Style.font.bodySmall; foreground: panel.dim; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "Delete every .bak.<epoch> beside your configs. Your repo is not touched."
        onClicked: panel.ask("prune-backups", "",
          "Delete every .bak.<epoch> next to your configs?\n\nThis is the only copy of what those files looked like before each restore. Your repo is not touched.",
          "Remove")
      }
    }
  }
}
