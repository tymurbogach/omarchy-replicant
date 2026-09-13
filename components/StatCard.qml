import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BorderSurface {
  id: statCard
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string label: ""
  property string value: ""
  property bool highlight: false
  // Which colour the highlight is. "to restore" is not the same kind of
  // attention as "unsaved" — one asks you to press Save and the other asks
  // you not to — so it borrows the amber the bar icon and the row badge
  // already use for it rather than sharing the accent.
  property color highlightColor: Color.accent
  // Explicit width: a Row gives its children no width, and a BorderSurface
  // with no width renders at zero — the cards were simply invisible.
  // The count is a property because the row grows a fifth card on the days
  // there is something to restore, and a hardcoded /4 left it overflowing.
  property int columns: 4
  width: (parent.width - Style.space(8 * (statCard.columns - 1))) / statCard.columns
  implicitHeight: Style.space(46)
  radius: Style.cornerRadius
  color: Style.controlFill(false, false, panel.fg, Color.accent)
  borderSpec: Border.controlSpec(statCard.highlight ? "focus" : "normal", panel.fg, statCard.highlightColor)
  Column {
    anchors.centerIn: parent
    spacing: 0
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: statCard.value
      color: statCard.highlight ? statCard.highlightColor : panel.fg
      font.family: panel.ff; font.pixelSize: Style.font.title; font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: statCard.label
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }
}
