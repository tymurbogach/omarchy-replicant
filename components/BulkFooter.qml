import QtQuick
import qs.Commons
import qs.Ui
import "../replicant.js" as R

BorderSurface {
  id: footer
  property var panel
  implicitHeight: body.implicitHeight + Style.space(16)
  color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
  borderSpec: Border.controlSpec("focus", panel.fg, Color.accent)
  Column {
    id: body
    anchors.fill: parent
    anchors.margins: Style.space(8)
    spacing: Style.space(4)
    Text {
      width: parent.width
      text: panel.selectionSummary.selected + " selected · " + panel.visibleConfigRows.length + " visible · "
            + panel.selectionSummary.files + " files · " + R.sizeText(panel.selectionSummary.bytes)
      color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
    Row {
      spacing: Style.space(6)
      Button { text: "Save"; visible: panel.bulkActions.indexOf("save") >= 0; bordered: true; foreground: panel.fg; accent: Color.accent; fontFamily: panel.ff; onClicked: panel.doBulk("save") }
      Button { text: "Track"; visible: panel.bulkActions.indexOf("track-config") >= 0; bordered: true; foreground: panel.fg; accent: Color.accent; fontFamily: panel.ff; onClicked: panel.doBulk("track-config") }
      Button { text: "Track secret"; visible: panel.bulkActions.indexOf("track-secret") >= 0; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.doBulk("track-secret") }
      Button { text: "Shared"; visible: panel.bulkActions.indexOf("scope-shared") >= 0; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.doBulk("scope-shared") }
      Button { text: "Profile"; visible: panel.bulkActions.indexOf("scope-profile") >= 0; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.doBulk("scope-profile") }
      Button { text: "Off"; visible: panel.bulkActions.indexOf("scope-off") >= 0; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.doBulk("scope-off") }
      Button { text: "Convert to secret"; visible: panel.bulkActions.indexOf("convert-secret") >= 0; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.doBulk("convert-secret") }
      Button { text: "Untrack"; visible: panel.bulkActions.indexOf("untrack") >= 0; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.doBulk("untrack") }
      Button { text: "Clear"; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.clearSelection() }
      Button { text: "Invert visible"; bordered: false; foreground: panel.dim; fontFamily: panel.ff; onClicked: panel.invertSelection() }
    }
  }
}
