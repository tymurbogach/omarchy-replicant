import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// One save in the Overview's list. A save that touched files opens on a
// click and names them. "config: 15 files, alacritty.toml, +14 more" said
// fifteen files changed and named one of them.
Item {
  id: cr
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var commit: ({})
  readonly property int nfiles: cr.commit.nfiles || 0
  readonly property var files: cr.commit.files || []
  readonly property bool expandable: cr.nfiles > 0
  readonly property bool expanded: cr.expandable && panel.isCommitOpen(cr.commit.sha)

  // The head has a fixed height. The file list sits under it at a fixed y, so
  // the height taken from the list is no loop.
  implicitHeight: head.height + (cr.expanded ? filesCol.implicitHeight + Style.space(6) : 0)

  Rectangle {
    anchors.fill: head
    radius: Style.cornerRadius
    color: hit.containsMouse && cr.expandable ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent"
  }

  Item {
    id: head
    width: parent.width
    height: Style.space(26)

    MouseArea {
      id: hit
      anchors.fill: parent
      enabled: cr.expandable
      hoverEnabled: true
      cursorShape: cr.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: panel.toggleCommit(cr.commit.sha)
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(12)
        text: cr.expandable ? (cr.expanded ? panel.icDown : panel.icRight) : ""
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
        text: cr.commit.date || ""
        color: panel.dim; font.family: panel.mono; font.pixelSize: Style.font.caption
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(12) - Style.space(96) - countText.width - parent.spacing * 3
        // A run of identical saves is collapsed by core_log. The count says
        // the inventory commits are accounted for, not dropped.
        text: (cr.commit.subject || "") + ((cr.commit.count || 1) > 1 ? "   ×" + cr.commit.count : "")
        color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Text {
        id: countText
        anchors.verticalCenter: parent.verticalCenter
        text: cr.expandable ? R.plural(cr.nfiles, "file") : ""
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
      }
    }
  }

  Column {
    id: filesCol
    y: head.height + Style.space(2)
    x: Style.space(28)
    width: parent.width - x
    visible: cr.expanded
    spacing: Style.space(1)
    Repeater {
      model: cr.expanded ? cr.files : []
      delegate: Item {
        id: fileLine
        required property var modelData
        readonly property var lab: R.repoPathLabel(fileLine.modelData.path)
        width: filesCol.width
        implicitHeight: Style.space(18)
        Text {
          id: statusLetter
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16)
          text: fileLine.modelData.status
          color: fileLine.modelData.status === "A" ? panel.okColor
               : fileLine.modelData.status === "D" ? Color.urgent : Color.accent
          font.family: panel.mono; font.pixelSize: Style.font.caption; font.bold: true
        }
        Text {
          anchors.left: statusLetter.right
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: fileLine.lab.label + (fileLine.lab.note !== "" ? "   · " + fileLine.lab.note : "")
          color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
    }
    Text {
      visible: cr.nfiles > cr.files.length
      text: "+" + (cr.nfiles - cr.files.length) + " more"
      color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
    }
  }
}
