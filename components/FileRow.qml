import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// One tracked file. Closed, it says what state the file is in and offers the
// one action that state asks for. A click opens it: where the file and its
// copy live, who syncs it, and every other action, each with its name.
//
// The closed row used to carry the scope button and six icon buttons, most of
// them disabled at a quarter opacity. Forty rows of that was a wall of glyphs,
// and a person had to hover each one to learn what it did.
Item {
  id: frow
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var config: ({})
  property string navigationId: ""
  readonly property bool keyboardFocused: panel.keyboardCursorId === frow.config.id
  // A scope change shows at once, before the status that confirms it arrives.
  readonly property string scope: R.effectiveScope(frow.config, panel.scopeOverrides)
  readonly property string syncState: R.displayState(frow.config, panel.scopeOverrides) || "saved"
  // "Needs the Save button": unsaved, or committed here and never pushed. Not
  // incoming: that difference belongs to another machine, and it asks for
  // Restore instead.
  readonly property bool isModified: frow.syncState === "unsaved" || frow.syncState === "unpushed"
  readonly property bool isIncoming: frow.syncState === "incoming"
  readonly property bool missing: frow.config.exists === false
  readonly property bool isSecret: frow.config.secret === true
  readonly property bool needsAction: frow.isModified || frow.isIncoming || frow.missing
  // "saved" and "default" need no words: the legend above the list covers them.
  readonly property bool needsWords: R.needsAttention(frow.syncState)
                                  || frow.syncState === "off" || frow.syncState === "pending"
  readonly property bool expanded: panel.isRowOpen(frow.config.id)
  readonly property bool selected: panel.selectedIds.indexOf(frow.config.id) !== -1

  // The head has a fixed height, and the details sit under it at a fixed y.
  implicitHeight: head.height + (frow.expanded ? details.implicitHeight + Style.space(10) : 0)

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: Style.space(4)
    anchors.rightMargin: Style.space(4)
    radius: Style.cornerRadius
    color: frow.expanded ? Style.hoverFillFor(panel.fg, Color.accent)
         : hit.containsMouse ? Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.04) : "transparent"
    border.width: frow.keyboardFocused ? 1 : 0
    border.color: Color.accent
  }

  Item {
    id: head
    width: parent.width
    height: Style.space(48)

    MouseArea {
      id: hit
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: panel.manageMode ? panel.toggleSelected(frow.config.id, false) : panel.toggleRow(frow.config.id)
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(10)

      Text {
        visible: panel.manageMode
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        text: frow.selected ? "[x]" : "[ ]"
        color: frow.selected ? Color.accent : panel.dim
        font.family: panel.ff; font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        text: R.stateGlyph(frow.syncState)
        color: panel.stateColor(frow.syncState)
        font.family: panel.ff; font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(20) - chevron.width - parent.spacing * 2
               - (primary.visible ? primary.width + parent.spacing : 0)
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: frow.config.label
          color: frow.missing || frow.syncState === "off" ? panel.dim : panel.fg
          font.family: panel.ff; font.pixelSize: Style.font.subtitle; font.bold: frow.needsAction
          elide: Text.ElideMiddle
        }
        // The words come first and are never elided. The path takes what is
        // left, and it can lose its end: the title above is the same path.
        // A row with nothing to add has no second line, so its title centres.
        Row {
          width: parent.width
          visible: stateWords.visible || profileTag.visible || detailText.text !== ""
          spacing: Style.space(6)
          Text {
            id: stateWords
            visible: frow.needsWords
            text: R.stateWord(frow.syncState)
            color: panel.stateColor(frow.syncState)
            font.family: panel.ff; font.pixelSize: Style.font.caption
          }
          Text {
            id: profileTag
            visible: frow.scope === "profile"
            text: panel.profileName + " profile"
            color: Color.accent
            font.family: panel.ff; font.pixelSize: Style.font.caption
          }
          Text {
            id: detailText
            width: parent.width - (stateWords.visible ? stateWords.width + parent.spacing : 0)
                                - (profileTag.visible ? profileTag.width + parent.spacing : 0)
            // A secret describes itself by what it is, never by what it holds:
            // a kind, a mode, and for an env file the number of variables.
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

      // The one action this row's state asks for, with its name on it.
      RowAction {
        id: primary
        panel: frow.panel
        anchors.verticalCenter: parent.verticalCenter
        visible: frow.isModified || frow.isIncoming
        text: frow.isIncoming ? "Restore" : "Save"
        iconText: frow.isIncoming ? panel.icFromRepo : panel.icSave
        foreground: frow.isIncoming ? panel.warnColor : Color.accent
        enabled: !panel.busy
        disabledReason: panel.busy ? "Another Replicant operation is running." : ""
        tooltipText: (!enabled ? "Disabled while another operation runs. " : "") + (frow.isIncoming
                     ? "Bring down the newer copy that another machine saved (keeps a .bak copy)"
                     : "Commit and push just this file")
        onClicked: frow.isIncoming ? panel.askRestoreFile(frow.config) : panel.doSaveFile(frow.config.id)
      }

      Text {
        id: chevron
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        text: frow.expanded ? panel.icDown : panel.icRight
        color: hit.containsMouse || frow.expanded ? panel.fg : panel.dim
        font.family: panel.ff; font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  FileDetails {
    id: details
    panel: frow.panel
    y: head.height
    width: parent.width
    visible: frow.expanded
    row: frow.config
    scope: frow.scope
    syncState: frow.syncState
  }
}
