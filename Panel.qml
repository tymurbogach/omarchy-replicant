import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.tymurbogach.omarchy-replicant"
  manageIpc: false

  property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-replicant"
  property string cliFallback: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant"
  property var state: ({ initialized: false, configs: [], secrets: [] })
  // true once a real status response has come back at least once. Gates the
  // "not initialized, create/clone" section — showing it before we actually
  // know the state let a stray click re-point an already-configured remote
  // (a real incident: a click during this window ran `create` and pointed the
  // repo's origin at the plugin's own public repo).
  property bool asked: false
  property string lastOutput: ""
  property string busyId: ""
  // True while a write operation is in flight, so buttons can disable and spin
  // instead of letting the user fire a second one into the repo lock.
  readonly property bool busy: saveProc.running || setProc.running || pullProc.running || pushProc.running || backupProc.running

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  function effectiveCli() { return cli }
  function run(cmd) { if (bar) bar.run(cmd) }
  function runVisible(cmd) { run("omarchy-launch-floating-terminal-with-presentation '" + cmd.replace(/'/g, "'\\''") + "'") }

  function doPush() { lastOutput = "push…"; pushProc.command = [effectiveCli(), "push", "-y"]; pushProc.running = true }
  function doPull() { lastOutput = "pull…"; pullProc.command = [effectiveCli(), "pull", "-y"]; pullProc.running = true }
  function doStatus() { lastOutput = "status…"; statusProc.command = [effectiveCli(), "status"]; statusProc.running = true }
  function doCloneInTerminal() { runVisible(effectiveCli() + " clone"); root.close() }
  function doCreateInTerminal() { runVisible(effectiveCli() + " create --push"); root.close() }
  function doSavegame() { lastOutput = "savegame…"; saveProc.command = [effectiveCli(), "savegame"]; saveProc.running = true }
  function doBackup() { lastOutput = "backup…"; backupProc.command = [effectiveCli(), "backup"]; backupProc.running = true }
  function doRestoreDry() { runVisible(effectiveCli() + " restore --dry-run") }
  function doEdit(id) {
    // launch editor in a floating terminal so it doesn't block the panel
    busyId = id
    runVisible(effectiveCli() + " edit '" + id.replace(/'/g, "'\\''") + "'")
    // refresh after a moment
    Qt.callLater(function(){ refreshTimer.restart() })
  }
  function doDiff(id) {
    runVisible(effectiveCli() + " diff '" + id.replace(/'/g, "'\\''") + "'")
  }
  function doReset(id) {
    runVisible(effectiveCli() + " reset '" + id.replace(/'/g, "'\\''") + "'")
  }
  function doResetAll() { runVisible(effectiveCli() + " reset-all --apply"); root.close() }
  function doRestoreAllFromGitHub() { runVisible(effectiveCli() + " restore --apply --all"); root.close() }
  function doSetSetting(id, value) {
    lastOutput = "Saving " + id + " = " + value + "…"
    setProc.command = [effectiveCli(), "set", id, String(value)]
    setProc.running = true
  }
  // Debounce for controls that emit a burst of values (holding a stepper).
  // Only the value the user lands on gets written and committed.
  // Collapsible sections: the panel has more content than its max height, and
  // nesting a scroll area inside a scrolling panel fights the wheel. Sections
  // that fold keep everything reachable with one obvious click.
  property bool showSettings: true
  property bool showConfigs: false
  property string pendingSettingId: ""
  property string pendingSettingValue: ""
  function queueSetting(id, value) {
    pendingSettingId = id
    pendingSettingValue = String(value)
    lastOutput = id + " = " + value + " (saving shortly…)"
    settingDebounce.restart()
  }
  Timer {
    id: settingDebounce
    interval: 900
    onTriggered: if (root.pendingSettingId !== "") root.doSetSetting(root.pendingSettingId, root.pendingSettingValue)
  }

  // flat config list, sorted so same-group entries sit together (feeds ListView's
  // section.property below — a plain Column+Repeater-of-Repeater nesting here caused
  // a QQuickItem::polish() loop in practice; ListView avoids that whole class of bug)
  readonly property var groupOrder: ["shell","git/ssh","claude","dev","hypr","session","omarchy","terminal","plugins","scripts","branding","system","replicant","other"]
  readonly property var sortedConfigs: {
    var arr = (root.state.configs || []).slice()
    var order = root.groupOrder
    arr.sort(function(a, b) {
      var ra = order.indexOf(a.group || "other"); if (ra === -1) ra = order.length
      var rb = order.indexOf(b.group || "other"); if (rb === -1) rb = order.length
      return ra - rb
    })
    return arr
  }

  readonly property string summary: {
    if (!root.state.initialized) return "Not initialized"
    if ((root.state.ahead || 0) > 0 && (root.state.behind || 0) > 0) return "Diverged ↑" + root.state.ahead + " ↓" + root.state.behind
    if ((root.state.ahead || 0) > 0) return "↑ " + root.state.ahead + " to push"
    if ((root.state.behind || 0) > 0) return "↓ " + root.state.behind + " to pull"
    if ((root.state.dirty || 0) > 0) return "● " + root.state.dirty + " modified"
    return "✓ in sync"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  Item { id: button; implicitWidth: 0; implicitHeight: 0 }

  Timer { id: refreshTimer; interval: 1500; onTriggered: if (hostWidget) hostWidget.refresh() }

  Process {
    id: pushProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-800); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = text.slice(-800) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="push failed ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }
  Process {
    id: pullProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-800); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = text.slice(-800) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="pull failed ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = text.slice(-800) }
    }
  }
  Process {
    id: saveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = (root.lastOutput + "\n" + text).slice(-1200) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="savegame failed ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }
  Process {
    id: backupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = (root.lastOutput + "\n" + text).slice(-1200) }
    }
  }
  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = (root.lastOutput + "\n" + text).slice(-1200) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="set failed ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }

  property var bar
  property var anchorItem
  property var hostWidget
  property bool opened: false
  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      // One scroll surface for the whole panel. The tracked-files list below is
      // deliberately non-interactive so there is never a nested scroll fighting
      // this one for the wheel.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

      Column {
        id: col
        width: scroller.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Omarchy Replicant"
          meta: root.summary
          foreground: root.fg
          fontFamily: root.ff
          iconComponent: Component { Text { text: "󰸞"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.display } }
        }
        Text {
          width: parent.width
          text: root.state.remote_name ? ("Private repo: " + root.state.remote_name) : (root.state.initialized ? "No remote yet — nothing is being backed up off this machine" : "")
          visible: text !== ""
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle
        }
        Text {
          width: parent.width
          visible: !!(root.state.initialized && (root.state.dirty || 0) > 0)
          text: (root.state.dirty || 0) + " change(s) not saved to the repo yet — press Save to commit and push"
          color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          visible: !!(root.state.initialized && (root.state.behind || 0) > 0)
          text: "↓ " + (root.state.behind || 0) + " change(s) waiting on GitHub — press Pull to bring them down"
          color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width; spacing: Style.space(8)
          Button {
            text: root.busy ? "Saving…" : "Save to GitHub"; iconText: "󰆓"; bordered: true
            foreground: root.fg; accent: Color.accent; fontFamily: root.ff
            iconSpinning: root.busy
            enabled: !!(root.state && root.state.initialized === true) && !root.busy
            tooltipText: "Copy this machine's configs into the repo, commit and push"
            onClicked: root.doSavegame()
          }
          Button {
            text: "Pull"; iconText: "󰸜"; bordered: false; foreground: root.fg; fontFamily: root.ff
            enabled: !!(root.state && root.state.initialized === true) && !root.busy
            tooltipText: "Bring down what another machine saved"
            onClicked: root.doPull()
          }
          Button {
            text: "Refresh"; iconText: "󰦒"; bordered: false; foreground: root.fg; fontFamily: root.ff
            tooltipText: "Re-check this machine against the repo"
            onClicked: if (hostWidget) hostWidget.refresh()
          }
        }
        Row {
          width: parent.width; spacing: Style.space(8)
          Button {
            text: "Preview restore"; iconText: "󰦛"; bordered: false; foreground: root.fg; fontFamily: root.ff
            enabled: !!(root.state && root.state.initialized === true)
            tooltipText: "Show what restoring from the repo would change — writes nothing"
            onClicked: root.doRestoreDry()
          }
          Button {
            text: "Copy files only"; iconText: "󰃨"; bordered: false; foreground: root.fg; fontFamily: root.ff
            enabled: !root.busy
            tooltipText: "Refresh the local copy without committing or pushing"
            onClicked: root.doBackup()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !!(root.state && root.state.initialized === true && root.state.settings && root.state.settings.length > 0)

          PanelSeparator { width: parent.width }
          Button {
            width: parent.width
            leftAlign: true
            bordered: false
            foreground: root.fg
            fontFamily: root.ff
            iconText: root.showSettings ? "󰅀" : "󰅂"
            text: "Settings (" + (root.state.settings ? root.state.settings.length : 0) + ")"
            tooltipText: "Values you can change from here"
            onClicked: root.showSettings = !root.showSettings
          }
          Text {
            width: parent.width
            visible: root.showSettings
            text: "Change a value here and it is written to the real config and committed to your repo automatically."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Repeater {
            model: root.showSettings ? root.state.settings : []
            delegate: BorderSurface {
              id: settingRow
              required property var modelData
              readonly property bool isNumber: modelData.type === "number" || modelData.type === "toml-number"
              readonly property bool isBool: modelData.type === "bool"
              readonly property bool isEnum: modelData.type === "enum"
              width: parent.width
              // Fixed height on purpose: deriving it from the children while the
              // inner Row is verticalCenter-anchored to this same item is a
              // parent-height <-> child-position feedback loop (Qt: "polish() loop").
              implicitHeight: 62
              radius: Style.cornerRadius
              color: Style.controlFill(false, false, root.fg, Color.accent)
              borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

              Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.rowPaddingX

                Column {
                  id: settingCol
                  // Fixed control width on purpose: deriving it from the control's
                  // own children, while the label's wrapped text height feeds back
                  // into the row height, is a layout feedback loop (Qt logs
                  // "polish() loop" and the section renders at zero height).
                  width: parent.width - control.width - parent.spacing
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs
                  Text {
                    width: parent.width
                    text: settingRow.modelData.label
                    color: root.fg
                    font.family: root.ff
                    font.pixelSize: Style.font.subtitle
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: !!settingRow.modelData.hint
                    text: settingRow.modelData.hint
                    color: root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // One control per type. The CLI is the source of truth: we send
                // the new value and let the next status refresh confirm it.
                Item {
                  id: control
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(150)
                  height: Math.max(numberField.implicitHeight, toggleSwitch.implicitHeight, enumDrop.implicitHeight)

                  // Every control is instantiated for every row, so each binding
                  // must stay type-safe even on rows it isn't used for — an enum's
                  // string value assigned to NumberField.value is a runtime error.
                  NumberField {
                    id: numberField
                    visible: settingRow.isNumber
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    foreground: root.fg
                    fontFamily: root.ff
                    from: settingRow.isNumber && settingRow.modelData.min !== null && settingRow.modelData.min !== undefined ? settingRow.modelData.min : 0
                    to: settingRow.isNumber && settingRow.modelData.max !== null && settingRow.modelData.max !== undefined ? settingRow.modelData.max : 999999
                    stepSize: settingRow.modelData.unit === "s" ? 30 : 1
                    value: settingRow.isNumber && typeof settingRow.modelData.value === "number" ? settingRow.modelData.value : 0
                    // Debounced: holding the stepper fires many changes, and each
                    // one would otherwise be its own commit+push.
                    onModified: function(v) { root.queueSetting(settingRow.modelData.id, v) }
                  }

                  ToggleSwitch {
                    id: toggleSwitch
                    visible: settingRow.isBool
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: settingRow.modelData.value === true
                    foreground: root.fg
                    accent: Color.accent
                    onToggled: root.doSetSetting(settingRow.modelData.id, settingRow.modelData.value === true ? "false" : "true")
                  }

                  Dropdown {
                    id: enumDrop
                    visible: settingRow.isEnum
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    showLabel: false
                    value: settingRow.isEnum && typeof settingRow.modelData.value === "string" ? settingRow.modelData.value : ""
                    options: settingRow.isEnum ? (settingRow.modelData.options || []) : []
                    fontFamily: root.ff
                    onChanged: function(v) { if (v !== settingRow.modelData.value) root.doSetSetting(settingRow.modelData.id, v) }
                  }
                }
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !!(root.state && root.state.initialized === true)

          PanelSeparator { width: parent.width }
          Text {
            width: parent.width
            text: "Danger zone — restore EVERYTHING"
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            text: "Each button opens a terminal showing what will change, and asks for confirmation. Both create .bak.<epoch> copies before overwriting anything."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Row {
            spacing: Style.space(8)
            Button {
              text: "Reset to Omarchy (all)"; iconText: "󰦒"; bordered: true; foreground: root.fg; fontFamily: root.ff
              tooltipText: "Resets everything with a known Omarchy default back to factory"
              onClicked: root.doResetAll()
            }
            Button {
              text: "Restore from GitHub (all)"; iconText: "󰸜"; bordered: true; foreground: root.fg; accent: Color.accent; fontFamily: root.ff
              tooltipText: "Brings EVERYTHING saved in the repo/GitHub down to this system"
              onClicked: root.doRestoreAllFromGitHub()
            }
          }
        }

        Text {
          width: parent.width; visible: !root.asked
          text: "Checking status…"
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
        }
        Column {
          // only once we've truly heard back "not initialized" — not just because
          // that's the property's default value before the first response arrives
          width: parent.width; spacing: Style.space(6); visible: root.asked && !(root.state && root.state.initialized)
          Text { width: parent.width; text: "No local repo yet. Create a private one or clone an existing one (everything: config+secrets+state)."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
          Row { spacing: Style.space(8)
            Button { text: "Create private"; iconText: "󰘐"; bordered: true; foreground: root.fg; accent: Color.accent; fontFamily: root.ff; onClicked: root.doCreateInTerminal() }
            Button { text: "Clone…"; iconText: "󰓹"; bordered: true; foreground: root.fg; fontFamily: root.ff; onClicked: root.doCloneInTerminal() }
          }
        }

        // ——— Editable per-config list ———
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !!(root.state && root.state.initialized && root.state.configs && root.state.configs.length > 0)

          PanelSeparator { width: parent.width }

          Button {
            width: parent.width
            leftAlign: true
            bordered: false
            foreground: root.fg
            fontFamily: root.ff
            iconText: root.showConfigs ? "󰅀" : "󰅂"
            text: "Tracked files (" + (root.state.configs ? root.state.configs.length : 0) + ")"
            tooltipText: "Every file this plugin backs up, and whether it is saved"
            onClicked: root.showConfigs = !root.showConfigs
          }
          Text {
            width: parent.width
            visible: root.showConfigs
            text: "○ default · ● modified · ◆ saved on GitHub"
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            visible: root.showConfigs
            text: "Edit opens the file in your editor. 'default' = identical to Omarchy's default. 'modified' = changed but not committed, or not pushed yet. 'saved' = matches what's in your GitHub repo."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Scroll for the ~37 rows. A ListView (not a hand-rolled Flickable +
          // Column + nested Repeater) — that nesting caused a real
          // QQuickItem::polish() loop in practice; section.property/section.delegate
          // gives us the per-group headers without a second Repeater level.
          ListView {
            visible: root.showConfigs
            interactive: false
            width: parent.width
            height: root.showConfigs ? contentHeight : 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(6)
            model: root.sortedConfigs
            section.property: "group"
            section.criteria: ViewSection.FullString
            section.delegate: PanelSectionHeader {
              width: ListView.view.width
              text: section
              foreground: root.fg
              fontFamily: root.ff
            }
            delegate: BorderSurface {
              id: configRow
              required property var modelData
              // 3 states: "default" (○ Omarchy default) | "modified" (● changed/not pushed) | "saved" (◆ saved on GitHub)
              readonly property string syncState: modelData.sync_state || (modelData.is_default ? "default" : (modelData.dirty ? "modified" : "saved"))
              readonly property bool isDefault: syncState === "default"
              readonly property bool isModified: syncState === "modified"
              readonly property bool isSaved: syncState === "saved"
              readonly property color savedColor: "#4caf50"
              width: ListView.view.width
              // minimum height so the badge and buttons fit
              implicitHeight: Math.max(64, row.implicitHeight + Style.spacing.controlPaddingY * 2)
              radius: Style.cornerRadius
              color: isModified ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08) : Style.controlFill(false, false, root.fg, Color.accent)
              borderSpec: Border.controlSpec(isModified ? "focus" : "normal", root.fg, Color.accent)

              Row {
                id: row
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.rowPaddingX
                // left: label + src
                Column {
                  width: parent.width - badgeCol.width - btnCol.width - parent.spacing*2
                  spacing: Style.spacing.xs
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    width: parent.width
                    text: configRow.modelData.label + (configRow.isModified ? " ●" : "")
                    color: configRow.modelData.exists ? root.fg : Qt.darker(root.fg, 1.6)
                    font.family: root.ff
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: configRow.modelData.src
                    color: root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
                // badge — 3 states at a glance: default / modified / saved on GitHub
                Column {
                  id: badgeCol
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2
                  width: 92
                  Text {
                    text: !configRow.modelData.exists ? "missing" : configRow.isDefault ? "default" : configRow.isModified ? "modified" : "saved"
                    color: !configRow.modelData.exists ? Qt.darker(root.fg, 1.6) : configRow.isDefault ? root.dim : configRow.isModified ? Color.accent : configRow.savedColor
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    font.bold: configRow.modelData.exists && !configRow.isDefault
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                  }
                  Text {
                    text: configRow.isDefault ? "○" : configRow.isModified ? "●" : "◆"
                    color: configRow.isDefault ? root.dim : configRow.isModified ? Color.accent : configRow.savedColor
                    font.family: root.ff
                    font.pixelSize: Style.font.body
                    horizontalAlignment: Text.AlignHCenter
                    width: parent.width
                  }
                }
                // actions
                Column {
                  id: btnCol
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 4
                  Button {
                    text: "Edit"; iconText: "󰏫"; bordered: false; foreground: root.fg; fontFamily: root.ff
                    enabled: configRow.modelData.exists
                    onClicked: root.doEdit(configRow.modelData.id)
                  }
                  Row { spacing: 4
                    Button {
                      text: "Diff"; iconText: "󰦓"; bordered: false; foreground: root.fg; fontFamily: root.ff
                      // Diff only makes sense if there's a default to compare against
                      enabled: !configRow.isDefault
                      tooltipText: configRow.isDefault ? "identical to default — nothing to diff" : "diff vs /usr/share/omarchy"
                      onClicked: root.doDiff(configRow.modelData.id)
                    }
                    Button {
                      text: "Reset"; iconText: "󰦛"; bordered: false; foreground: root.fg; fontFamily: root.ff
                      enabled: !configRow.isDefault && configRow.modelData.exists
                      tooltipText: "restores the default (omarchy refresh), with .bak"
                      onClicked: root.doReset(configRow.modelData.id)
                    }
                  }
                }
              }
              // clicking the row opens edit (shortcut)
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (configRow.modelData.exists) root.doEdit(configRow.modelData.id) }
            }
          }
        }

        PanelSeparator { width: parent.width; visible: root.lastOutput !== "" }
        Text { width: parent.width; visible: root.lastOutput !== ""; text: root.lastOutput; color: root.dim; font.family: "monospace"; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
        Text {
          width: parent.width
          text: "Local copy: " + (root.state.repo_dir || "not set up yet") + "\nSame from a terminal: omarchy-replicant --help"
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
        }
      }
      }
    }
  }
}
