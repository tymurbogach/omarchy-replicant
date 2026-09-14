import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One line of a list inside a card: a glyph, what it is, a word about it on
// the right, and the actions that apply. The machines, the areas, the backups
// and the plugins use it, so their lists line up the same way.
//
// What is declared inside a ListRow goes to the right edge: RowActions, or an
// icon button. An action that does not apply is not declared visible.
Item {
  id: lr
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string icon: ""
  property color iconColor: panel.dim
  property string title: ""
  property color titleColor: panel.fg
  property bool titleBold: false
  property string detail: ""
  property color detailColor: panel.dim
  property string meta: ""
  property color metaColor: panel.dim
  default property alias actions: actionRow.data

  // A fixed height from the text it has, never from the children, which are
  // centred on it.
  implicitHeight: lr.detail !== "" ? Style.space(42) : Style.space(32)

  Text {
    id: glyph
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(20)
    horizontalAlignment: Text.AlignHCenter
    text: lr.icon
    color: lr.iconColor
    font.family: panel.ff; font.pixelSize: Style.font.body
  }

  Column {
    anchors.left: glyph.right
    anchors.leftMargin: Style.space(10)
    anchors.right: metaText.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xs
    Text {
      width: parent.width
      text: lr.title
      color: lr.titleColor
      font.family: panel.ff; font.pixelSize: Style.font.subtitle; font.bold: lr.titleBold
      elide: Text.ElideMiddle
    }
    Text {
      width: parent.width
      visible: lr.detail !== ""
      text: lr.detail
      color: lr.detailColor
      font.family: panel.ff; font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Text {
    id: metaText
    anchors.right: actionRow.left
    anchors.rightMargin: actionRow.width > 0 ? Style.space(8) : 0
    anchors.verticalCenter: parent.verticalCenter
    text: lr.meta
    color: lr.metaColor
    font.family: panel.ff; font.pixelSize: Style.font.caption
  }

  Row {
    id: actionRow
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.rowPaddingX
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(4)
  }
}
