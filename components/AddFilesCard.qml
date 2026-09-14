import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// ── what else could I be backing up? ──────────────────────────────────────
// Two ways in. Suggestions are what the plugin found that looks like config.
// Browse is everything else: any file or folder, anywhere a person can read,
// or a path typed in. The manifest stays a list that a human chose, because
// nothing here is tracked until a Track button is pressed.
Card {
  id: ac
  readonly property var items: panel.suggestions || []
  readonly property var entries: (panel.browseData.entries || []).slice(0, 200)

  icon: panel.icPlus
  title: "Add files"
  // "(a)" is the key that jumps here. It goes last, so it is the first thing
  // an elided subtitle loses; test-usability.sh holds this to 57.
  subtitle: "Any file or folder you choose, or a suggestion  (a)"
  countText: ac.items.length > 0 ? String(ac.items.length) : ""
  statusText: ac.items.length > 0 ? "suggested" : ""
  collapsible: true
  expanded: panel.isOpen("__suggest")
  onToggled: panel.toggleCard("__suggest")

  Item {
    width: parent.width
    height: Style.space(38)
    ButtonGroup {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      focusable: false
      spacing: Style.space(4)
      fontSize: Style.font.bodySmall
      foreground: panel.fg
      accent: Color.accent
      fontFamily: panel.ff
      value: panel.addMode
      options: [
        { value: "suggest", label: "Suggestions  " + ac.items.length, icon: panel.icInfo,
          tooltip: "Config on this machine that nothing backs up yet" },
        { value: "browse", label: "Browse your files", icon: panel.icFolderOpen,
          tooltip: "Any file or folder: a project's .env, a script, a folder outside ~/.config" }
      ]
      onChanged: function(v) { panel.setAddMode(v) }
    }
  }

  // ── suggestions ─────────────────────────────────────────────────────────
  CardNote {
    panel: ac.panel
    visible: panel.addMode === "suggest" && panel.suggestLoaded && ac.items.length === 0
    text: "Nothing to suggest: everything here that looks like config is tracked. Browse your files to add anything else."
  }
  Repeater {
    model: ac.open && panel.addMode === "suggest" ? ac.items : []
    delegate: SuggestRow {
      required property var modelData
      panel: ac.panel
      item: modelData
      width: ac.width
    }
  }

  // ── browse ──────────────────────────────────────────────────────────────
  // A path typed or pasted in. Relative paths start at the folder shown.
  Item {
    width: parent.width
    height: Style.space(38)
    visible: panel.addMode === "browse"
    TextField {
      id: pathField
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.right: trackTyped.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      placeholderText: "Type a path: ~/Projects/app/.env"
      foreground: panel.fg
      accent: Color.accent
      font.family: panel.ff
      onActiveFocusChanged: panel.noteFocus(pathField, activeFocus)
      onAccepted: if (panel.trackTyped(text, false)) text = ""
      Keys.onEscapePressed: { text = ""; panel.releaseFocus() }
    }
    RowAction {
      id: trackTyped
      panel: ac.panel
      anchors.right: asSecret.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      text: "Track"; iconText: panel.icPlus
      enabled: !panel.busy && pathField.text.trim() !== ""
      tooltipText: "Track this path. A folder is tracked whole."
      onClicked: if (panel.trackTyped(pathField.text, false)) pathField.text = ""
    }
    RowAction {
      id: asSecret
      panel: ac.panel
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      text: "As secret"; iconText: panel.icKey
      foreground: panel.warnColor
      enabled: !panel.busy && pathField.text.trim() !== ""
      tooltipText: "Track it as a secret: stored at mode 600, and its contents are never shown"
      onClicked: if (panel.trackTyped(pathField.text, true)) pathField.text = ""
    }
  }

  // Where the picker is, and the way up.
  Item {
    width: parent.width
    height: Style.space(30)
    visible: panel.addMode === "browse"
    Button {
      id: upBtn
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX - Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: panel.icUp; bordered: false
      foreground: panel.fg; fontFamily: panel.ff
      enabled: (panel.browseData.dir || "/") !== "/"
      tooltipText: "Up to " + R.prettyPath(panel.browseData.parent || "/", panel.repoState.home || "")
      onClicked: panel.browseUp()
    }
    Button {
      id: homeBtn
      anchors.left: upBtn.right
      anchors.verticalCenter: parent.verticalCenter
      text: "~"; bordered: false
      foreground: panel.fg; fontFamily: panel.ff
      tooltipText: "Your home folder"
      onClicked: panel.browseTo(panel.repoState.home || "~")
    }
    Text {
      anchors.left: homeBtn.right
      anchors.leftMargin: Style.space(6)
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      text: panel.browseLoading ? "Reading…"
          : panel.browseData.error ? R.prettyPath(panel.browseData.dir, panel.repoState.home || "") + " " + panel.browseData.error
          : R.prettyPath(panel.browseData.dir || "", panel.repoState.home || "")
            + "   " + R.plural((panel.browseData.entries || []).length, "entry", "entries")
      color: panel.browseData.error ? Color.urgent : panel.dim
      font.family: panel.mono; font.pixelSize: Style.font.caption
      elide: Text.ElideLeft
    }
  }

  Repeater {
    model: ac.open && panel.addMode === "browse" ? ac.entries : []
    delegate: BrowseRow {
      required property var modelData
      panel: ac.panel
      entry: modelData
      width: ac.width
    }
  }
  CardNote {
    panel: ac.panel
    visible: panel.addMode === "browse" && (panel.browseData.entries || []).length > ac.entries.length
    text: "+" + ((panel.browseData.entries || []).length - ac.entries.length) + " more. Type the path to reach one of them."
  }
}
