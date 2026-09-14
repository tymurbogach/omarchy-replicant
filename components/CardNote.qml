import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A sentence inside a card: what an action does, or how an area comes back.
// It wraps, and it pads itself like a row. The height comes from the text,
// which sits at a fixed y, so it is no loop.
Item {
  id: note
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string text: ""
  property string icon: ""
  property color textColor: panel.dim
  width: parent ? parent.width : 0
  implicitHeight: label.implicitHeight + Style.space(8)

  Text {
    id: glyph
    x: Style.spacing.rowPaddingX
    y: Style.space(4)
    width: note.icon !== "" ? Style.space(20) : 0
    horizontalAlignment: Text.AlignHCenter
    visible: note.icon !== ""
    text: note.icon
    color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
  }
  Text {
    id: label
    x: glyph.x + glyph.width + (note.icon !== "" ? Style.space(10) : 0)
    y: Style.space(4)
    width: note.width - x - Style.spacing.rowPaddingX
    text: note.text
    color: note.textColor; font.family: panel.ff; font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
