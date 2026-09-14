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
  function focusSearch() { settingSearchField.forceActiveFocus() }
  spacing: Style.space(8)

  Text {
    width: parent.width
    text: "A change is written, applied and committed.    ● yours    ○ as Omarchy ships"
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
  }

  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: settingSearchField
      width: parent.width - settingsCollapseBtn.width - Style.space(8)
      placeholderText: "Filter settings…   (/)"
      foreground: panel.fg
      accent: Color.accent
      font.family: panel.ff
      onTextChanged: panel.settingSearch = text
      onActiveFocusChanged: panel.noteFocus(settingSearchField, activeFocus)
      Keys.onEscapePressed: { text = ""; panel.releaseFocus() }
    }
    Button {
      id: settingsCollapseBtn
      text: "Collapse all"; bordered: false
      foreground: panel.dim; fontFamily: panel.ff
      tooltipText: "Close every open group  (c)"
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
      value: panel.settingFilter
      options: panel.settingFilterOptions
      onChanged: function(v) { panel.settingFilter = v }
    }
  }

  Repeater {
    model: panel.settingGroups
    delegate: SettingCard { panel: st.panel;
      required property var modelData
      group: modelData
      width: st.width
    }
  }

  Text {
    width: parent.width
    visible: panel.settingGroups.length === 0
    text: panel.settingFilter === "customised" && panel.settingSearch === ""
          ? "Every value is as Omarchy ships it."
          : "Nothing matches that filter."
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }
}
