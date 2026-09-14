import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One group of the Settings tab. A customised value is not tinted: it
// differs from what Omarchy ships, and it asks for nothing.
Card {
  id: sc
  property var group: ({})

  icon: sc.group.icon
  title: sc.group.name
  subtitle: sc.group.description
  countText: String((sc.group.items || []).length)
  // Not "changed": one tab to the left that word counts files waiting to be
  // saved, and here it counts values that differ from what Omarchy ships.
  // "customised" is the answer to this one, and it pairs with the text it
  // alternates with.
  statusText: sc.group.changed > 0 ? sc.group.changed + " customised" : "at default"
  statusTone: sc.group.changed > 0 ? "accent" : ""
  collapsible: true
  // Open while a filter is on, as on the Configs tab: the filter already
  // chose the rows, and a closed card would hide the answer.
  expanded: panel.isOpen(sc.group.id) || panel.settingFiltering
  onToggled: panel.toggleCard(sc.group.id)

  Repeater {
    model: sc.open ? (sc.group.items || []) : []
    delegate: SettingRow {
      required property var modelData
      panel: sc.panel
      setting: modelData
      width: sc.width
    }
  }
}
