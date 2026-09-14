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
BorderSurface {
  id: ac
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  readonly property bool expanded: panel.isOpen("__suggest")
  readonly property var items: panel.suggestions || []
  readonly property var entries: (panel.browseData.entries || []).slice(0, 200)

  implicitHeight: acCol.implicitHeight
  radius: Style.cornerRadius
  color: Style.controlFill(false, false, panel.fg, Color.accent)
  borderSpec: Border.controlSpec(ac.expanded ? "focus" : "normal", panel.fg, Color.accent)

  Column {
    id: acCol
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 0

    CardHeader { panel: ac.panel;
      width: parent.width
      icon: panel.icPlus
      title: "Add files"
      // "(a)" is the key that jumps here. It goes last, so it is the first
      // thing an elided subtitle loses; test-usability.sh holds this to 57.
      subtitle: "Any file or folder you choose, or a suggestion  (a)"
      countText: ac.items.length > 0 ? String(ac.items.length) : ""
      statusText: ac.items.length > 0 ? "suggested" : ""
      statusHighlight: false
      expanded: ac.expanded
      onToggled: panel.toggleCard("__suggest")
    }

    Column {
      width: parent.width
      visible: ac.expanded
      spacing: Style.space(4)

      PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }

      Item {
        width: parent.width
        height: Style.space(36)
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

      // ── suggestions ─────────────────────────────────────────────────────
      Column {
        width: parent.width
        visible: panel.addMode === "suggest"
        spacing: Style.space(2)
        Text {
          x: Style.spacing.rowPaddingX
          width: parent.width - Style.spacing.rowPaddingX * 2
          visible: panel.suggestLoaded && ac.items.length === 0
          text: "Nothing to suggest: everything here that looks like config is tracked. Browse your files to add anything else."
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Repeater {
          model: ac.expanded && panel.addMode === "suggest" ? ac.items : []
          delegate: SuggestRow { panel: ac.panel;
            required property var modelData
            item: modelData
            width: acCol.width
          }
        }
      }

      // ── browse ──────────────────────────────────────────────────────────
      Column {
        width: parent.width
        visible: panel.addMode === "browse"
        spacing: Style.space(4)

        // A path typed or pasted in. Relative paths start at the folder shown.
        Item {
          width: parent.width
          height: Style.space(38)
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
          Button {
            id: trackTyped
            anchors.right: asSecret.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            text: "Track"; iconText: panel.icPlus; bordered: true
            fontSize: Style.font.bodySmall; foreground: panel.fg; fontFamily: panel.ff
            enabled: !panel.busy && pathField.text.trim() !== ""
            tooltipText: "Track this path. A folder is tracked whole."
            onClicked: if (panel.trackTyped(pathField.text, false)) pathField.text = ""
          }
          Button {
            id: asSecret
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "As secret"; iconText: panel.icKey; bordered: true
            fontSize: Style.font.bodySmall; foreground: panel.warnColor; fontFamily: panel.ff
            enabled: !panel.busy && pathField.text.trim() !== ""
            tooltipText: "Track it as a secret: stored at mode 600, and its contents are never shown"
            onClicked: if (panel.trackTyped(pathField.text, true)) pathField.text = ""
          }
        }

        // Where the picker is, and the way up.
        Item {
          width: parent.width
          height: Style.space(30)
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
          model: ac.expanded && panel.addMode === "browse" ? ac.entries : []
          delegate: BrowseRow { panel: ac.panel;
            required property var modelData
            entry: modelData
            width: acCol.width
          }
        }
        Text {
          x: Style.spacing.rowPaddingX
          visible: (panel.browseData.entries || []).length > ac.entries.length
          text: "+" + ((panel.browseData.entries || []).length - ac.entries.length) + " more. Type the path to reach one of them."
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        }
        Item { width: 1; height: Style.space(4) }
      }
    }
  }
}
