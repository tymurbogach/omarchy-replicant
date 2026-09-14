import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The top of a list tab: a search field, "Collapse all", the filters, and the
// legend of the badges. Configs and Settings use the same one, in the same
// order, so a person finds each part in the same place on both tabs.
Column {
  id: fb
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string placeholder: ""
  property var options: []
  property string value: ""
  property string legend: ""
  property string collapseTip: ""
  signal searchEdited(string text)
  signal filterPicked(string value)
  function focusSearch() { field.forceActiveFocus() }
  spacing: Style.space(8)

  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: field
      width: parent.width - collapseBtn.width - Style.space(8)
      placeholderText: fb.placeholder
      foreground: panel.fg
      accent: Color.accent
      font.family: panel.ff
      onTextChanged: fb.searchEdited(text)
      onActiveFocusChanged: panel.noteFocus(field, activeFocus)
      Keys.onEscapePressed: { text = ""; panel.releaseFocus() }
    }
    Button {
      id: collapseBtn
      text: "Collapse all"; bordered: false
      foreground: panel.dim; fontFamily: panel.ff
      tooltipText: fb.collapseTip
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
      value: fb.value
      options: fb.options
      onChanged: function(v) { fb.filterPicked(v) }
    }
  }

  // The badges, once. Every row that needs a word says it in words too.
  Text {
    width: parent.width
    text: fb.legend
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
