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
  function focusSearch() { filterBar.focusSearch() }
  spacing: Style.space(8)

  FilterBar {
    id: filterBar
    panel: ct.panel
    width: ct.width
    placeholder: "Filter by name or path…   (/)"
    options: panel.filterOptions
    value: panel.stateFilter
    legend: "● unsaved    ↓ to restore    ↑ to push    ◆ saved    ○ default    ⊘ off    · not here"
    collapseTip: "Close every open area and row  (c)"
    onSearchEdited: function(t) { panel.fileSearch = t }
    onFilterPicked: function(v) { panel.stateFilter = v }
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
    delegate: CategoryCard {
      required property var modelData
      panel: ct.panel
      card: modelData
      width: ct.width
    }
  }

  // The list above is what the plugin ships with plus what you have already
  // added. This is how you add more, kept last so it never competes with the
  // areas, and collapsed so it is an offer rather than a chore.
  AddFilesCard { panel: ct.panel; width: ct.width }
}
