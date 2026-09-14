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
//
// Track shows on the row under the pointer. A folder of forty entries was
// forty identical buttons, and the names were what a person came to read.
Item {
  id: br
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var entry: ({})
  readonly property bool isDir: br.entry.type === "d"
  readonly property bool isLink: br.entry.type === "l"
  readonly property bool isSecret: br.entry.kind === "secret"

  readonly property bool hot: hover.hovered
  implicitHeight: Style.space(32)

  HoverHandler { id: hover }

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: Style.space(4)
    anchors.rightMargin: Style.space(4)
    radius: Style.cornerRadius
    color: br.hot ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent"
  }

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    enabled: br.isDir
    cursorShape: br.isDir ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: panel.browseTo(br.entry.path)
  }

  ListRow {
    panel: br.panel
    anchors.fill: parent
    icon: br.isDir ? panel.icFolder : br.isLink ? panel.icLink : br.isSecret ? panel.icKey : panel.icFile
    iconColor: br.isDir ? Color.accent : br.isSecret ? panel.warnColor : panel.dim
    title: br.entry.name + (br.isDir ? "/" : "")
    titleColor: br.entry.tracked ? panel.dim : panel.fg
    meta: br.entry.tracked ? "tracked" : br.isLink ? "symlink"
        : br.hot || br.isDir ? "" : R.sizeText(br.entry.size)
    metaColor: br.entry.tracked ? panel.okColor : panel.dim

    RowAction {
      panel: br.panel
      anchors.verticalCenter: parent.verticalCenter
      visible: br.hot && !br.entry.tracked && !br.isLink
      text: br.isDir ? "Track folder" : br.isSecret ? "Track (600)" : "Track"
      iconText: panel.icPlus
      enabled: !panel.busy
      tooltipText: br.isDir ? "Track the whole folder: every file in it is saved, and a change anywhere inside shows up"
                 : br.isSecret ? "Track it as a secret: stored at mode 600, and its contents are never shown"
                 : "Add it to your list. It is saved with your next Save to GitHub."
      onClicked: panel.doTrack(br.isDir ? br.entry.path + "/" : br.entry.path, br.isSecret ? "secret" : "config")
    }
  }
}
