import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// One entry of the file picker. A folder opens on a click, and both a folder
// and a file can be tracked from here. A symlink cannot: track refuses one,
// and the row says to track what it points at.
Item {
  id: br
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var entry: ({})
  readonly property bool isDir: br.entry.type === "d"
  readonly property bool isLink: br.entry.type === "l"
  readonly property bool isSecret: br.entry.kind === "secret"

  implicitHeight: Style.space(30)

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: Style.space(4)
    anchors.rightMargin: Style.space(4)
    radius: Style.cornerRadius
    color: hit.containsMouse && br.isDir ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent"
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    enabled: br.isDir
    cursorShape: br.isDir ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: panel.browseTo(br.entry.path)
  }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(16)
      text: br.isDir ? panel.icFolder : br.isLink ? panel.icLink : br.isSecret ? panel.icKey : panel.icFile
      color: br.isDir ? Color.accent : br.isSecret ? panel.warnColor : panel.dim
      font.family: panel.ff; font.pixelSize: Style.font.body
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(16) - metaText.width - action.width - parent.spacing * 3
      text: br.entry.name + (br.isDir ? "/" : "")
      color: br.entry.tracked ? panel.dim : panel.fg
      font.family: panel.ff; font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }
    Text {
      id: metaText
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(64)
      horizontalAlignment: Text.AlignRight
      text: br.entry.tracked ? "tracked" : br.isLink ? "symlink" : br.isDir ? "" : R.sizeText(br.entry.size)
      color: br.entry.tracked ? panel.okColor : panel.dim
      font.family: panel.ff; font.pixelSize: Style.font.caption
    }
    Item {
      id: action
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(112)
      height: Style.space(26)
      Button {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !br.entry.tracked && !br.isLink
        text: br.isDir ? "Track folder" : br.isSecret ? "Track (600)" : "Track"
        iconText: panel.icPlus
        bordered: true
        fontSize: Style.font.caption
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(2)
        foreground: panel.fg
        fontFamily: panel.ff
        enabled: !panel.busy
        tooltipText: br.isDir ? "Track the whole folder: every file in it is saved, and a change anywhere inside shows up"
                   : br.isSecret ? "Track it as a secret: stored at mode 600, and its contents are never shown"
                   : "Add it to your list. It is saved with your next Save to GitHub."
        onClicked: panel.doTrack(br.isDir ? br.entry.path + "/" : br.entry.path, br.isSecret ? "secret" : "config")
      }
    }
  }
}
