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
  property string lastOutput: ""
  property string busyId: ""

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

  // group the editable list by "group"
  readonly property var grouped: {
    var m = {}
    var arr = state.configs || []
    for (var i=0;i<arr.length;i++) {
      var e = arr[i]
      var g = e.group || "other"
      if (!m[g]) m[g] = []
      m[g].push(e)
    }
    var order = ["shell","git/ssh","claude","dev","hypr","session","omarchy","terminal","plugins","scripts","branding","system","replicant","other"]
    var out = []
    for (var oi=0; oi<order.length; oi++) if (m[order[oi]]) out.push({group: order[oi], items: m[order[oi]]})
    for (var k in m) if (order.indexOf(k)===-1) out.push({group:k, items:m[k]})
    return out
  }

  readonly property string summary: {
    if (!state.initialized) return "Not initialized"
    if ((state.ahead || 0) > 0 && (state.behind || 0) > 0) return "Diverged ↑" + state.ahead + " ↓" + state.behind
    if ((state.ahead || 0) > 0) return "↑ " + state.ahead + " to push"
    if ((state.behind || 0) > 0) return "↓ " + state.behind + " to pull"
    if ((state.dirty || 0) > 0) return "● " + state.dirty + " modified"
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
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: col
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Omarchy Replicant"
          meta: root.summary
          foreground: root.fg
          fontFamily: root.ff
          iconComponent: Component { Text { text: "󰸞"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.display } }
        }
        Text { width: parent.width; text: state.remote ? state.remote : "no remote"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle }
        Text { width: parent.width; text: "branch: " + (state.branch || "main") + "   dirty: " + (state.dirty || 0) + "   ahead/behind: " + (state.ahead||0) + "/" + (state.behind||0); color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        Text { width: parent.width; visible: !!(state.pending && String(state.pending).trim() !== ""); text: "pending:" + (state.pending || ""); color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption }

        Row {
          width: parent.width; spacing: Style.space(8)
          Button { text: "Savegame"; iconText: "󰆓"; bordered: true; foreground: root.fg; accent: Color.accent; fontFamily: root.ff; enabled: !!(state && state.initialized === true); tooltipText: "backup + auto-commit state + push"; onClicked: root.doSavegame() }
          Button { text: "Backup"; iconText: "󰃨"; bordered: false; foreground: root.fg; fontFamily: root.ff; onClicked: root.doBackup() }
          Button { text: "Status"; iconText: "󰦒"; bordered: false; foreground: root.fg; fontFamily: root.ff; onClicked: root.doStatus() }
        }
        Row {
          width: parent.width; spacing: Style.space(8)
          Button { text: "Push"; iconText: "󰸝"; bordered: false; foreground: root.fg; fontFamily: root.ff; enabled: !!(state && state.initialized === true); onClicked: root.doPush() }
          Button { text: "Pull"; iconText: "󰸜"; bordered: false; foreground: root.fg; fontFamily: root.ff; enabled: !!(state && state.initialized === true); onClicked: root.doPull() }
          Button { text: "Restore (dry)"; iconText: "󰦛"; bordered: false; foreground: root.fg; fontFamily: root.ff; onClicked: root.doRestoreDry() }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !!(state && state.initialized === true)

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

        Column {
          width: parent.width; spacing: Style.space(6); visible: !(state && state.initialized)
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
          visible: !!(state && state.initialized && state.configs && state.configs.length > 0)

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            text: "Configs (" + (state.configs ? state.configs.length : 0) + ") — ○ default · ● modified · ◆ saved on GitHub"
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            text: "Edit opens the file in your editor. 'default' = identical to Omarchy's default. 'modified' = changed but not committed, or not pushed yet. 'saved' = matches what's in your GitHub repo."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Scroll for the ~37 rows — fixed 420 Flickable so it never collapses to 0
          Flickable {
            width: parent.width
            height: 420
            contentHeight: groupedCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
              id: groupedCol
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: root.grouped
                delegate: Column {
                  required property var modelData
                  anchors.left: parent.left
                  anchors.right: parent.right
                  spacing: Style.space(6)

                  PanelSectionHeader {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    text: modelData.group
                    foreground: root.fg
                    fontFamily: root.ff
                  }

                  Repeater {
                    model: modelData.items
                    delegate: BorderSurface {
                  required property var modelData
                  // 3 states: "default" (○ Omarchy default) | "modified" (● changed/not pushed) | "saved" (◆ saved on GitHub)
                  readonly property string syncState: modelData.sync_state || (modelData.is_default ? "default" : (modelData.dirty ? "modified" : "saved"))
                  readonly property bool isDefault: syncState === "default"
                  readonly property bool isModified: syncState === "modified"
                  readonly property bool isSaved: syncState === "saved"
                  readonly property color savedColor: "#4caf50"
                  anchors.left: parent.left
                  anchors.right: parent.right
                  // minimum height so the badge and buttons fit
                  implicitHeight: Math.max(64, row.implicitHeight + Style.spacing.rowPaddingY * 2)
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
                        text: modelData.label + (isModified ? " ●" : "")
                        color: modelData.exists ? root.fg : Qt.darker(root.fg, 1.6)
                        font.family: root.ff
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        text: modelData.src
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
                        text: !modelData.exists ? "missing" : isDefault ? "default" : isModified ? "modified" : "saved"
                        color: !modelData.exists ? Qt.darker(root.fg, 1.6) : isDefault ? root.dim : isModified ? Color.accent : savedColor
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                        font.bold: modelData.exists && !isDefault
                        horizontalAlignment: Text.AlignHCenter
                        width: parent.width
                      }
                      Text {
                        text: isDefault ? "○" : isModified ? "●" : "◆"
                        color: isDefault ? root.dim : isModified ? Color.accent : savedColor
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
                        enabled: modelData.exists
                        onClicked: root.doEdit(modelData.id)
                      }
                      Row { spacing: 4
                        Button {
                          text: "Diff"; iconText: "󰦓"; bordered: false; foreground: root.fg; fontFamily: root.ff
                          // Diff only makes sense if there's a default to compare against
                          enabled: !isDefault
                          tooltipText: isDefault ? "identical to default — nothing to diff" : "diff vs /usr/share/omarchy"
                          onClicked: root.doDiff(modelData.id)
                        }
                        Button {
                          text: "Reset"; iconText: "󰦛"; bordered: false; foreground: root.fg; fontFamily: root.ff
                          enabled: !isDefault && modelData.exists
                          tooltipText: "restores the default (omarchy refresh), with .bak"
                          onClicked: root.doReset(modelData.id)
                        }
                      }
                    }
                  }
                  // clicking the row opens edit (shortcut)
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (modelData.exists) root.doEdit(modelData.id) }
                }
              }
            }
          }
        }
      }
    }

        PanelSeparator { width: parent.width; visible: root.lastOutput !== "" }
        Text { width: parent.width; visible: root.lastOutput !== ""; text: root.lastOutput; color: root.dim; font.family: "monospace"; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
        Text { width: parent.width; text: "CLI: savegame | backup | edit <id> | diff <id> | reset <id> | reset-all | restore --apply --all\nPrivate repo: ~/.local/share/omarchy-replicant/repo (config/secrets/state)"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      }
    }
  }
}
