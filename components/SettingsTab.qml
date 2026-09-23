import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The values a person changes, one control each, grouped the way Omarchy
// groups them. A change is written, applied and committed.
Column {
  id: st
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  function navigationItem(openCards) {
    for (var i = 0; i < groupRepeater.count; i++) {
      var item = groupRepeater.itemAt(i)
      if (item && openCards && openCards[item.navigationId]) return item
    }
    return null
  }
  function focusSearch() { filterBar.focusSearch() }
  spacing: Style.space(8)

  FilterBar {
    id: filterBar
    panel: st.panel
    width: st.width
    placeholder: "Filter settings…   (/)"
    options: panel.settingFilterOptions
    value: panel.settingFilter
    legend: "● yours    ○ default    · not here      A change is applied and saved at once."
    collapseTip: "Close every open group  (c)"
    onSearchEdited: function(t) { panel.setSettingSearch(t) }
    onFilterPicked: function(v) { panel.setSettingFilter(v) }
  }

  Text {
    width: parent.width
    visible: panel.settingGroups.length === 0
    text: panel.settingFilter === "customised" && panel.settingSearch === ""
          ? "Every value is at its default."
          : "Nothing matches that filter."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }

  Repeater {
    id: groupRepeater
    model: panel.settingGroups
    delegate: SettingCard {
      required property var modelData
      panel: st.panel
      group: modelData
      width: st.width
    }
  }
}
