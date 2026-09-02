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
  property var state: ({ initialized: false })
  property string lastOutput: ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  function effectiveCli() { return cli }

  function run(cmd) { if (bar) bar.run(cmd) }
  function runVisible(cmd) { run("omarchy-launch-floating-terminal-with-presentation '" + cmd.replace(/'/g, "'\\''") + "'") }

  function doPush() {
    lastOutput = "push…"
    pushProc.command = [effectiveCli(), "push", "-y"]
    pushProc.running = true
  }
  function doPull() {
    lastOutput = "pull…"
    pullProc.command = [effectiveCli(), "pull", "-y"]
    pullProc.running = true
  }
  function doStatus() {
    lastOutput = "status…"
    statusProc.command = [effectiveCli(), "status"]
    statusProc.running = true
  }
  function doCloneInTerminal() {
    runVisible(effectiveCli() + " clone")
    root.close()
  }
  function doCreateInTerminal() {
    runVisible(effectiveCli() + " create omarchy-replicant --public --push")
    root.close()
  }

  readonly property string summary: {
    if (!state.initialized) return "No inicializado"
    if ((state.ahead || 0) > 0 && (state.behind || 0) > 0) return "Divergido ↑" + state.ahead + " ↓" + state.behind
    if ((state.ahead || 0) > 0) return "↑ " + state.ahead + " por pushear"
    if ((state.behind || 0) > 0) return "↓ " + state.behind + " por bajar"
    if ((state.dirty || 0) > 0) return "● " + state.dirty + " modificados"
    return "✓ sincronizado"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // bar icon is in BarWidget; this Panel is only the popover. Provide dummy button for KeyboardPanel anchoring.
  Item { id: button; implicitWidth: 0; implicitHeight: 0 }

  Process {
    id: pushProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { root.lastOutput = text.slice(-800); hostWidget ? hostWidget.refresh() : null } }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: { if (text) root.lastOutput = text.slice(-800) } }
    onExited: function(code) { if (code !== 0) root.lastOutput = "push falló ("+code+")\n" + root.lastOutput; if (hostWidget) hostWidget.refresh() }
  }
  Process {
    id: pullProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { root.lastOutput = text.slice(-800); hostWidget ? hostWidget.refresh() : null } }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: { if (text) root.lastOutput = text.slice(-800) } }
    onExited: function(code) { if (code !== 0) root.lastOutput = "pull falló ("+code+")\n" + root.lastOutput; if (hostWidget) hostWidget.refresh() }
  }
  Process {
    id: statusProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { root.lastOutput = text.slice(-800) } }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: { if (text) root.lastOutput = text.slice(-800) } }
  }

  // We are rendered as Panel by BarWidget's Loader — hook its opened/anchor
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(560))

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

        Text {
          width: parent.width
          text: state.remote ? state.remote : "sin remote"
          color: root.dim
          font.family: root.ff
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
        Text {
          width: parent.width
          text: "branch: " + (state.branch || "main") + "   dirty: " + (state.dirty || 0) + "   ahead/behind: " + (state.ahead||0) + "/" + (state.behind||0)
          color: root.dim
          font.family: root.ff
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Button {
            text: "Push"
            iconText: "󰸝"
            bordered: true
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.ff
            enabled: state.initialized
            onClicked: root.doPush()
          }
          Button {
            text: "Pull"
            iconText: "󰸜"
            bordered: true
            foreground: root.fg
            accent: Color.accent
            fontFamily: root.ff
            enabled: state.initialized
            onClicked: root.doPull()
          }
          Button {
            text: "Status"
            iconText: "󰦒"
            bordered: false
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.doStatus()
          }
        }

        // uninitialized helper
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !state.initialized
          Text {
            width: parent.width
            text: "No hay repo local. Crea uno o clona el existente."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Row {
            spacing: Style.space(8)
            Button {
              text: "Create (public)"
              iconText: "󰘐"
              bordered: true
              foreground: root.fg
              accent: Color.accent
              fontFamily: root.ff
              onClicked: root.doCreateInTerminal()
            }
            Button {
              text: "Clone…"
              iconText: "󰓹"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              onClicked: root.doCloneInTerminal()
            }
          }
        }

        PanelSeparator { width: parent.width; visible: root.lastOutput !== "" }

        Text {
          width: parent.width
          visible: root.lastOutput !== ""
          text: root.lastOutput
          color: root.dim
          font.family: "monospace"
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          text: "CLI: omarchy-replicant status | push -m \"msg\" | clone <url> | restore --yes\nConfig: ~/.local/share/omarchy-replicant/config.toml"
          color: root.dim
          font.family: root.ff
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
