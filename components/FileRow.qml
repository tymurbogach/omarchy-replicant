import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

Item {
  id: frow
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var config: ({})
  readonly property string syncState: frow.config.sync_state || "saved"
  readonly property bool isDefault: frow.syncState === "default"
  // "Needs the Save button" — unsaved, or committed here but never pushed.
  // Deliberately NOT incoming: that row's difference belongs to another
  // machine, and the button it wants is the one next to this one.
  readonly property bool isModified: frow.syncState === "unsaved" || frow.syncState === "unpushed"
  readonly property bool isIncoming: frow.syncState === "incoming"
  // Anything with a button worth pressing reads bold, whichever button it is.
  readonly property bool needsAction: frow.isModified || frow.isIncoming
  readonly property string scope: frow.config.scope || "shared"
  readonly property bool isOff: frow.config.synced === false
  readonly property bool missing: frow.config.exists === false
  readonly property bool isSecret: frow.config.secret === true
  // "saved" and "default" are the states you do not have to act on, and the
  // one-line legend above the list is enough for them.
  readonly property bool needsWords: frow.syncState === "unsaved"
                                  || frow.syncState === "incoming"
                                  || frow.syncState === "unpushed"
                                  || frow.syncState === "off"
                                  || frow.syncState === "missing"

  implicitHeight: Style.space(50)

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      text: R.stateGlyph(frow.syncState)
      color: panel.stateColor(frow.syncState)
      font.family: panel.ff; font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      width: parent.width - Style.space(14) - syncSwitch.width - actions.width - parent.spacing * 3
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        text: frow.config.label
        color: frow.missing || frow.isOff ? panel.dim : panel.fg
        font.family: panel.ff; font.pixelSize: Style.font.subtitle; font.bold: frow.needsAction
        elide: Text.ElideMiddle
      }
      // Two texts, not one string. Appended to the end of the path the state
      // words were the first thing elided — on exactly the rows whose whole
      // point is that something needs doing, they were the half that got cut.
      // (The same bug was already fixed for a directory's file count by
      // moving it in front; this is that fix applied to the other half.)
      // So the words come first and are never elided; the path takes whatever
      // room is left, and it is the part that can afford to lose its head —
      // the title right above it is the same path without ~/.config/.
      Row {
        width: parent.width
        spacing: Style.space(6)
        Text {
          id: stateWords
          // A row that needs attention says so in words instead of relying on
          // the reader having learnt the badge. Only those rows: the forty
          // that are simply saved would be forty repetitions of "saved on
          // GitHub", which is how a legend becomes wallpaper.
          visible: frow.needsWords
          text: R.stateWord(frow.syncState)
          color: panel.stateColor(frow.syncState)
          font.family: panel.ff; font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width - (stateWords.visible ? stateWords.width + parent.spacing : 0)
          // Secrets describe themselves by what they ARE, never by what they
          // contain: a kind, a mode, and for env files the names of the
          // variables. No value ever reaches the screen.
          // The count goes FIRST for a directory — behind the path it was the
          // first thing elided, on the one row whose whole point is the count.
          text: frow.config.is_dir === true
              ? (frow.config.nfiles + " files"
                 + (panel.whereText(frow.config) !== "" ? "  ·  " + panel.whereText(frow.config) : ""))
            : frow.isSecret
              ? (frow.config.kind + "  ·  mode " + (frow.config.mode || "?")
                 + (frow.config.var_count > 0 ? "  ·  " + frow.config.var_count + " variables" : ""))
              : panel.whereText(frow.config)
          color: frow.isSecret && frow.config.kind === "private key" && frow.config.mode !== "600" ? Color.urgent : panel.dim
          font.family: panel.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    // The per-file scope control. Some files are about the machine, not about
    // the user — hypr/monitors.lua describes the screens physically plugged
    // into THIS box — and copying them between a desktop and a laptop is
    // actively wrong. Rather than the old on/off switch, which forced you to
    // choose between "wrong on one machine" and "no backup at all", this
    // cycles the three answers: shared, per profile, or off.
    Button {
      id: syncSwitch
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(96)
      enabled: !panel.busy
      bordered: true
      text: panel.scopeLabel(frow.scope)
      iconText: panel.scopeIcon(frow.scope)
      foreground: frow.scope === "off" ? panel.dim
                : frow.scope === "profile" ? Color.accent : panel.fg
      fontFamily: panel.ff
      tooltipText: panel.scopeHint(frow.scope, !frow.isSecret)
      onClicked: panel.doScope(frow.config.id, R.nextScope(frow.scope, !frow.isSecret))
    }

    Row {
      id: actions
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0
      Button {
        iconText: panel.icEdit; bordered: false; foreground: panel.fg; fontFamily: panel.ff
        enabled: !frow.missing
        tooltipText: "Open in your editor"
        onClicked: panel.doEdit(frow.config.id)
      }
      Button {
        iconText: panel.icDiff; bordered: false; foreground: panel.fg; fontFamily: panel.ff
        enabled: !frow.missing
        tooltipText: frow.isSecret ? "Say whether it changed (contents are never shown)" : "Show what changed"
        onClicked: panel.doDiff(frow.config.id)
      }
      Button {
        iconText: panel.icSave; bordered: false
        foreground: frow.isModified ? Color.accent : panel.dim; fontFamily: panel.ff
        enabled: !frow.missing && frow.isModified && !panel.busy
        tooltipText: frow.isModified ? "Commit and push just this file"
                   : frow.isIncoming ? "Your repo has a newer copy from another machine — restore it instead"
                   : "Already saved"
        onClicked: panel.doSaveFile(frow.config.id)
      }
      Button {
        iconText: panel.icFromRepo; bordered: false
        foreground: frow.isIncoming ? panel.warnColor : panel.dim; fontFamily: panel.ff
        enabled: !panel.busy && frow.syncState !== "off"
        tooltipText: frow.isIncoming ? "Bring down the newer copy another machine saved (keeps a .bak copy)"
                                     : "Put back the copy saved in your repo (keeps a .bak copy)"
        onClicked: panel.ask("restore-file", frow.config.id,
                            "Replace " + frow.config.label + " with the copy saved in your repo?\n\nYour current version is kept as .bak.<epoch>.",
                            "Restore")
      }
      Button {
        iconText: panel.icDefault; bordered: false; foreground: panel.dim; fontFamily: panel.ff
        // Only offered where there is a factory version to go back to.
        enabled: !frow.missing && frow.config.has_default === true && !frow.isDefault && !panel.busy
        opacity: frow.config.has_default === true ? 1.0 : 0.25
        tooltipText: frow.config.has_default === true
                     ? "Put Omarchy's default back (keeps a .bak copy)"
                     : "Omarchy ships no default for this file"
        onClicked: panel.ask("reset-file", frow.config.id,
                            "Replace " + frow.config.label + " with Omarchy's default?\n\nYour current version is kept as .bak.<epoch>.",
                            "Reset")
      }
      // Only on rows that came from the user's own list. A file the plugin
      // ships with is switched OFF instead, which keeps both the row and the
      // copy in the repo — untracking a shipped entry would make a file the
      // next version tracks again vanish from the panel with no way back.
      Button {
        visible: frow.config.source === "user"
        iconText: panel.icUntrack; bordered: false; foreground: panel.dim; fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: "Stop tracking this — it leaves your list and the copy in the repo goes with it"
        onClicked: panel.ask("untrack", frow.config.id,
                            "Stop tracking " + frow.config.label + "?\n\nThe file on this machine is untouched. The copy in your repo is removed, and git keeps its history.",
                            "Untrack")
      }
    }
  }
}
