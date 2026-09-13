import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: srow
  // The panel this belongs to. Every value and every action comes from it.
  property var panel
  property var setting: ({})
  readonly property bool isNumber: setting.type === "number" || setting.type === "toml-int" || setting.type === "lua-int"
  readonly property bool isFloat:  setting.type === "toml-float"
  readonly property bool isBool:   setting.type === "bool" || setting.type === "lua-bool"
  readonly property bool isChoice: setting.type === "enum" || setting.type === "lua-enum"
                                || setting.type === "line-enum" || setting.type === "theme"
                                || setting.type === "ini-enum"
  readonly property bool isLongList: srow.isChoice && (setting.options || []).length > 8
  readonly property bool usable: setting.available === true && !panel.busy

  // Whether the exact value is worth repeating under the label. It is there
  // because the stepper rounds — 150 seconds is edited as 3 minutes, and the
  // row must never leave you guessing which number is real — but on the rows
  // where the control already shows the value exactly, repeating it cost the
  // hint its last words: seven of eight rows ended in "…". So it is printed
  // only when the control cannot say it: a rounded number, a value with a
  // name of its own ("never" for 0), or a choice, whose dropdown elides.
  readonly property string controlText: {
    var du = String(srow.setting.display_unit || "")
    return String(srow.setting.display_value) + (du !== "" ? " " + du : "")
  }
  readonly property bool showValue: srow.isChoice
                                    // A dropdown 160 wide shows about
                                    // seventeen characters; past that it
                                    // elides and the row has to say the value
                                    // in full underneath. "top" does not.
                                    ? String(srow.setting.value_text || "").length > 17
                                  : srow.isBool ? false
                                  : String(srow.setting.value_text || "") !== srow.controlText

  // What goes under the label, composed once so the height can be decided
  // from it. See showValue for when the value is part of it.
  readonly property string subtitleText: srow.setting.available !== true
      ? "not present in this machine's config"
      : (srow.showValue ? String(srow.setting.value_text) : "")
        + (srow.setting.implicit === true
           ? (srow.showValue ? "  (inherited)" : "inherited") : "")
        + ((srow.showValue || srow.setting.implicit === true) ? "  ·  " : "")
        + String(srow.setting.hint || "")

  // Two lines when one cannot hold it. Some hints carry a consequence worth
  // reading — "setting it stops the bar scaling with the font" — and cutting
  // them to fit would have deleted the reason the control exists. A character
  // count, NOT the text's own implicitHeight: this row's children are
  // verticalCenter-anchored to it, so a height derived from them is the
  // parent-height <-> child-position loop that renders the row at nothing.
  // 44 is what fits on one line at the panel's width, measured on a capture.
  readonly property string noticeText: String(srow.setting.notice || "")
  readonly property int subtitleLines: srow.subtitleText.length > 44 ? 2 : 1
  // The notice is counted too, and it was not. A row carrying one rendered
  // four lines of text in the two-line height and the notice was cut in half
  // — "Overridden: Omarchy Sleepwalker is blocki…", losing the clause that
  // said what the consequence was. Same character count, same reason: this
  // row's children are verticalCenter-anchored to it, so a height derived
  // from their own implicitHeight is the polish() loop that renders nothing.
  readonly property int noticeLines: srow.noticeText === "" ? 0
                                   : (srow.noticeText.length > 44 ? 2 : 1)
  implicitHeight: Style.space(34 + 16 * srow.subtitleLines + 16 * srow.noticeLines)
  opacity: srow.setting.available === true ? 1.0 : 0.45

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.space(8)

    Column {
      width: parent.width - controlSlot.width - revertRow.width - parent.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
      Text {
        width: parent.width
        text: srow.setting.label
        color: panel.fg; font.family: panel.ff; font.pixelSize: Style.font.subtitle
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: srow.subtitleText
        color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      // Only ever present when the value genuinely cannot do what it says —
      // see the single rule in build_settings_json. Not a warning strip that
      // is always on; a row that says nothing is a row that is fine.
      Text {
        width: parent.width
        visible: srow.noticeText !== ""
        text: srow.noticeText
        color: Color.accent; font.family: panel.ff; font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }

    // One control per type. Every control is instantiated on every row, so
    // each binding has to stay type-safe even on rows it is not used for —
    // an enum's string value assigned to NumberField.value is a runtime error.
    Item {
      id: controlSlot
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(160)
      height: Style.space(32)

      // Numbers are edited in the unit a person uses: idle timers in minutes,
      // never in seconds. The registry's `scale` does the conversion, and the
      // CLI still speaks the stored unit.
      Row {
        visible: srow.isNumber
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(5)
        NumberField {
          anchors.verticalCenter: parent.verticalCenter
          enabled: srow.usable
          foreground: panel.fg
          fontFamily: panel.ff
          fieldWidth: Style.space(96)
          from: srow.isNumber && typeof srow.setting.display_min === "number" ? srow.setting.display_min : 0
          to: srow.isNumber && typeof srow.setting.display_max === "number" ? srow.setting.display_max : 999999
          stepSize: srow.isNumber && typeof srow.setting.display_step === "number" ? srow.setting.display_step : 1
          value: srow.isNumber && typeof srow.setting.display_value === "number" ? srow.setting.display_value : 0
          onModified: function(v) {
            if (!srow.usable) return
            var scale = typeof srow.setting.scale === "number" && srow.setting.scale > 0 ? srow.setting.scale : 1
            panel.queueSetting(srow.setting.id, Math.round(v * scale))
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          text: srow.setting.display_unit || ""
          color: panel.dim; font.family: panel.ff; font.pixelSize: Style.font.caption
        }
      }

      // Floats get a slider: a stepper over 0.5–2.0 in 0.05 steps would be
      // thirty clicks from one end to the other.
      Row {
        visible: srow.isFloat
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          text: srow.isFloat && typeof srow.setting.value === "number" ? srow.setting.value.toFixed(2) : "—"
          color: panel.fg; font.family: panel.mono; font.pixelSize: Style.font.caption
        }
        PanelSlider {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(112)
          bar: panel.bar
          minimum: srow.isFloat && typeof srow.setting.min === "number" ? srow.setting.min : 0
          maximum: srow.isFloat && typeof srow.setting.max === "number" ? srow.setting.max : 1
          step: 0.05
          value: srow.isFloat && typeof srow.setting.value === "number" ? srow.setting.value : 0
          onReleased: function(v) { if (srow.usable) panel.queueSetting(srow.setting.id, Math.round(v * 100) / 100) }
        }
      }

      ToggleSwitch {
        visible: srow.isBool
        enabled: srow.usable
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: srow.setting.value === true || srow.setting.value === "true"
        foreground: panel.fg
        accent: Color.accent
        onToggled: if (srow.usable) panel.doSetSetting(srow.setting.id,
                      (srow.setting.value === true || srow.setting.value === "true") ? "false" : "true")
      }

      Dropdown {
        visible: srow.isChoice && !srow.isLongList
        enabled: srow.usable
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        showLabel: false
        value: srow.isChoice && typeof srow.setting.value === "string" ? srow.setting.value : ""
        options: srow.isChoice ? (srow.setting.options || []) : []
        fontFamily: panel.ff
        onChanged: function(v) { if (srow.usable && v !== srow.setting.value) panel.doSetSetting(srow.setting.id, v) }
      }

      // ~30 themes; a plain dropdown makes you hunt for the one you want.
      SearchableDropdown {
        visible: srow.isChoice && srow.isLongList
        enabled: srow.usable
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        showLabel: false
        placeholderText: "Search…"
        value: srow.isChoice && typeof srow.setting.value === "string" ? srow.setting.value : ""
        options: srow.isChoice ? (srow.setting.options || []) : []
        fontFamily: panel.ff
        onChanged: function(v) { if (srow.usable && v !== srow.setting.value) panel.doSetSetting(srow.setting.id, v) }
      }
    }

    // Two ways back for one value, without touching the rest of the file it
    // lives in. Shown only when they would actually change something.
    Row {
      id: revertRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0
      Button {
        iconText: panel.icDefault; bordered: false; foreground: panel.dim; fontFamily: panel.ff
        enabled: srow.setting.can_revert_default === true && !panel.busy
        opacity: srow.setting.can_revert_default === true ? 1.0 : 0.25
        tooltipText: srow.setting.can_revert_default === true
                     ? "Back to Omarchy's default: " + srow.setting.default_text
                     : "Already the Omarchy default"
        onClicked: panel.doRevert(srow.setting.id, "default")
      }
      Button {
        iconText: panel.icFromRepo; bordered: false; foreground: panel.dim; fontFamily: panel.ff
        enabled: srow.setting.can_revert_repo === true && !panel.busy
        opacity: srow.setting.can_revert_repo === true ? 1.0 : 0.25
        tooltipText: srow.setting.can_revert_repo === true
                     ? "Back to what your repo has: " + srow.setting.repo_text
                     : "Already matches your repo"
        onClicked: panel.doRevert(srow.setting.id, "repo")
      }
    }
  }
}
