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
  function navigationItem(openRow, openCards) {
    for (var i = 0; i < categoryRepeater.count; i++) {
      var item = categoryRepeater.itemAt(i)
      if (item) {
        var found = item.navigationItem(openRow, openCards)
        if (found) return found
      }
    }
    return addFiles.navigationId && openCards && openCards["__suggest"] ? addFiles : null
  }
  function focusSearch() { filterBar.focusSearch() }
  spacing: Style.space(8)

  FilterBar {
    id: filterBar
    panel: ct.panel
    width: ct.width
    placeholder: "Filter by name or path…   (/)"
    options: panel.filterOptions
    value: panel.stateFilter
    legend: "● unsaved    ↓ to restore    ↑ to push    ◆ saved    ○ default    ⊘ off    · not here    ⚠ locked"
    collapseTip: "Close every open area and row  (c)"
    onSearchEdited: function(t) { panel.setFileSearch(t) }
    onFilterPicked: function(v) { panel.setStateFilter(v) }
  }

  Row {
    width: parent.width
    spacing: Style.space(8)
    Button {
      text: panel.manageMode ? "Done" : "Manage"
      bordered: true
      foreground: panel.fg; accent: Color.accent; fontFamily: panel.ff
      tooltipText: "Select several entries  (m)"
      onClicked: panel.toggleManage()
    }
    Text {
      visible: panel.manageMode
      anchors.verticalCenter: parent.verticalCenter
      text: "Space select · Shift range · Ctrl+A visible"
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }

  Text {
    width: parent.width
    text: "Counts: all " + panel.nTracked + " · changed " + panel.nChanged
          + " · incoming " + panel.nIncoming + " · missing " + panel.nMissing
          + " · locked " + panel.nLocked + " · large " + panel.nLarge + " · off " + panel.nOff
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Row {
    visible: panel.categoryCards.length === 0
    spacing: Style.space(8)
    Button {
      visible: panel.filtering
      text: "Clear filter"; bordered: true
      foreground: panel.fg; accent: Color.accent; fontFamily: panel.ff
      tooltipText: "Show every tracked entry"
      onClicked: { panel.setFileSearch(""); panel.setStateFilter("all") }
    }
    Button {
      visible: !panel.filtering
      text: panel.suggestions.length > 0 ? "Review suggestions" : "Refresh"
      bordered: true
      foreground: panel.fg; accent: Color.accent; fontFamily: panel.ff
      tooltipText: panel.suggestions.length > 0 ? "Review files that are not tracked" : "Refresh the repository status"
      onClicked: panel.suggestions.length > 0 ? panel.toggleCard("__suggest") : panel.refresh()
    }
  }

  Text {
    width: parent.width
    visible: panel.categoryCards.length === 0
    text: panel.stateFilter === "changed" && panel.fileSearch === ""
          ? "Nothing to do: every file matches your repo."
          : "Nothing matches that filter."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }

  Text {
    width: parent.width
    visible: panel.filtering && panel.categoryCards.length > 0
    text: {
      var visibleCount = 0, totalCount = 0
      for (var i = 0; i < panel.categoryCards.length; i++) {
        visibleCount += panel.categoryCards[i].count
        totalCount += panel.categoryCards[i].total
      }
      return "Showing " + visibleCount + " of " + totalCount + " tracked entries"
    }
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }

  Repeater {
    id: categoryRepeater
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
  AddFilesCard { id: addFiles; panel: ct.panel; width: ct.width; navigationId: "__suggest" }
}
