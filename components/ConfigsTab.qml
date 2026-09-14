import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Everything that is backed up, by area. A filter and a search narrow it, and
// the last card adds more.
Column {
  id: ct
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  function focusSearch() { searchField.forceActiveFocus() }
  spacing: Style.space(8)

  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: searchField
      width: parent.width - collapseBtn.width - Style.space(8)
      placeholderText: "Filter by name or path…   (/)"
      foreground: panel.fg
      accent: Color.accent
      font.family: panel.ff
      onTextChanged: panel.fileSearch = text
      onActiveFocusChanged: panel.noteFocus(searchField, activeFocus)
      Keys.onEscapePressed: { text = ""; panel.releaseFocus() }
    }
    Button {
      id: collapseBtn
      text: "Collapse all"; bordered: false
      foreground: panel.dim; fontFamily: panel.ff
      tooltipText: "Close every open area and row  (c)"
      onClicked: panel.closeAllCards()
    }
  }

  Item {
    width: parent.width
    height: Style.space(34)
    ButtonGroup {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      focusable: false
      spacing: Style.space(4)
      fontSize: Style.font.bodySmall
      foreground: panel.fg
      accent: Color.accent
      fontFamily: panel.ff
      value: panel.stateFilter
      options: panel.filterOptions
      onChanged: function(v) { panel.stateFilter = v }
    }
  }

  // The badges, once. Every row that needs a word says it in words too.
  Text {
    width: parent.width
    text: "● unsaved    ↓ to restore    ↑ to push    ◆ saved    ○ default    ⊘ off    · not here"
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    width: parent.width
    visible: panel.categoryCards.length === 0
    text: panel.stateFilter === "changed" && panel.fileSearch === ""
          ? "Nothing to do: every file matches your repo."
          : "Nothing matches that filter."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }

  Repeater {
    model: panel.categoryCards
    delegate: CategoryCard { panel: ct.panel;
      required property var modelData
      card: modelData
      width: ct.width
    }
  }

  // The list above is what the plugin ships with plus what you have already
  // added. This is how you add more, kept last so it never competes with the
  // areas, and collapsed so it is an offer rather than a chore.
  AddFilesCard { panel: ct.panel; width: ct.width }
}
