import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The top of the Overview tab: what state this machine is in, in one sentence,
// the two buttons a person comes for, and the counts behind the sentence.
//
// The counts were four big cards that read 0 on most days and said nothing
// about what they counted. They are chips now: only the ones with something to
// say, each with a tooltip that names the files, and each one a click away
// from those files in the Configs tab.
BorderSurface {
  id: sc
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  readonly property var head: panel.head
  readonly property color toneColor: sc.head.tone === "ok" ? panel.okColor
                                   : sc.head.tone === "warn" ? panel.warnColor
                                   : sc.head.tone === "accent" ? Color.accent : panel.dim

  // Height from the column, which is anchored to the top and never centred.
  implicitHeight: col.implicitHeight + Style.spacing.controlPaddingY * 2 + Style.space(8)
  radius: Style.cornerRadius
  color: Qt.rgba(sc.toneColor.r, sc.toneColor.g, sc.toneColor.b, 0.07)
  borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)

  Column {
    id: col
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.spacing.controlPaddingY + Style.space(4)
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(10)

    Item {
      width: parent.width
      height: Style.space(44)
      // In the glyph column of every card, so the title lines up with theirs.
      Text {
        id: glyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        horizontalAlignment: Text.AlignHCenter
        text: sc.head.tone === "ok" ? panel.icCheck
            : sc.head.tone === "warn" ? panel.icAlert
            : sc.head.tone === "accent" ? panel.icSave : panel.icRefresh
        color: sc.toneColor
        font.family: panel.ff
        font.pixelSize: Style.font.display
      }
      Column {
        anchors.left: glyph.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: parent.width
          text: sc.head.title
          color: panel.fg
          font.family: panel.ff
          font.pixelSize: Style.font.heading
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          visible: text !== ""
          text: sc.head.detail
          color: panel.dim
          font.family: panel.ff
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    Row {
      spacing: Style.space(8)
      Button {
        text: panel.remoteState === "ahead" ? "Retry push" : "Save to GitHub"; iconText: panel.icPush; bordered: true
        foreground: panel.nDirty > 0 || panel.nAhead > 0 ? Color.accent : panel.fg
        accent: Color.accent; fontFamily: panel.ff
        iconSpinning: panel.saving
        enabled: panel.ready && !panel.busy
        tooltipText: !panel.ready ? "Disabled: configure a repository first."
                    : panel.busy ? "Disabled: another Replicant operation is running."
                    : panel.remoteState === "ahead" ? "Retry publishing the local commits" : "Copy this machine into the repo, commit and push  (s)"
        onClicked: panel.remoteState === "ahead" && panel.nDirty === 0 ? panel.doRetryPush() : panel.doSavegame()
      }
      Button {
        text: "Pull"; iconText: panel.icPull; bordered: true
        foreground: panel.nBehind > 0 ? panel.warnColor : panel.fg
        accent: Color.accent; fontFamily: panel.ff
        iconSpinning: panel.pulling
        enabled: panel.ready && !panel.busy
        tooltipText: !panel.ready ? "Disabled: configure a repository first."
                    : panel.busy ? "Disabled: another Replicant operation is running."
                    : "Bring down what another machine saved  (p)"
        onClicked: panel.doPull()
      }
    }

    Text {
      text: panel.remoteStateText
      color: panel.stateColor(panel.remoteState === "local-only" ? "off" : panel.remoteState === "synced" ? "saved" : "incoming")
      font.family: panel.ff; font.pixelSize: Style.font.caption
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: panel.chips
        delegate: Button {
          required property var modelData
          text: modelData.text
          bordered: true
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(3)
          foreground: modelData.tone === "warn" ? panel.warnColor
                    : modelData.tone === "accent" ? Color.accent
                    : modelData.tone === "dim" ? panel.dim : panel.fg
          fontFamily: panel.ff
          tooltipText: modelData.tooltip
          onClicked: panel.chipClicked(modelData.id)
        }
      }
    }
  }
}
