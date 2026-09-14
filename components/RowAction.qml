import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A button on a row: bordered, small, and with its name on it. Every row
// action in the panel is one, so the buttons of a file, a backup and a plugin
// look alike. The actions of a whole card (Save, Restore everything) are
// full-size buttons instead.
Button {
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  bordered: true
  fontSize: Style.font.bodySmall
  horizontalPadding: Style.space(8)
  verticalPadding: Style.space(3)
  foreground: panel ? panel.fg : Color.foreground
  accent: Color.accent
  fontFamily: panel ? panel.ff : Style.font.family
}
