import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A block of the panel: one header and what it holds. Every tab is built of
// cards, so every block starts the same way. A collapsible card opens on a
// click. Any other card is always open.
//
// What is declared inside a Card goes into its body, under the separator.
// Rows fill the width and pad themselves (Style.spacing.rowPaddingX).
BorderSurface {
  id: card
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property string icon: ""
  property string title: ""
  property string subtitle: ""
  property string countText: ""
  property string statusText: ""
  // "" (dim), "accent" (yours, to save) or "warn" (from elsewhere, differs).
  property string statusTone: ""
  property string keyboardId: ""
  // A tint says that the card asks for something. A value that only differs
  // from a default asks for nothing, and its card is not tinted.
  property string tint: ""
  property bool collapsible: false
  property bool expanded: true
  readonly property bool keyboardFocused: panel.keyboardFocus
      && panel.keyboardFocus.kind === "card"
      && panel.keyboardFocus.id === card.keyboardId
  default property alias content: body.data
  signal toggled()

  readonly property bool open: !card.collapsible || card.expanded
  readonly property color tintColor: card.tint === "warn" ? panel.warnColor : Color.accent

  // Height from the column, which is anchored to the top and never centred.
  implicitHeight: col.implicitHeight
  radius: Style.cornerRadius
  color: card.tint !== "" ? Qt.rgba(card.tintColor.r, card.tintColor.g, card.tintColor.b, 0.07)
                          : Style.controlFill(false, false, panel.fg, Color.accent)
  borderSpec: Border.controlSpec(card.keyboardFocused || (card.collapsible && card.expanded) ? "focus" : "normal", panel.fg, Color.accent)

  Column {
    id: col
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: 0

    CardHeader {
      panel: card.panel
      width: parent.width
      icon: card.icon
      title: card.title
      subtitle: card.subtitle
      countText: card.countText
      statusText: card.statusText
      statusTone: card.statusTone
      collapsible: card.collapsible
      expanded: card.open
      onToggled: card.toggled()
    }

    Column {
      width: parent.width
      visible: card.open
      spacing: Style.space(2)
      PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }
      Column {
        id: body
        width: parent.width
        spacing: Style.space(2)
      }
      Item { width: 1; height: Style.space(6) }
    }
  }
}
