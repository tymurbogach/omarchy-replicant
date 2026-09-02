import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.tymurbogach.omarchy-replicant"

  readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-replicant"
  readonly property string cliFallback: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant"

  property var state: ({ initialized: false })
  property bool asked: false
  property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  // symbol by state
  readonly property string glyph: {
    if (!asked) return "󰸘" // hourglass
    if (!state.initialized) return "󰘐" // plus/box
    if ((state.ahead || 0) > 0 && (state.behind || 0) > 0) return "󰧜" // diverged
    if ((state.ahead || 0) > 0) return "󰸝" // up
    if ((state.behind || 0) > 0) return "󰸜" // down
    if ((state.dirty || 0) > 0) return "󰦒" // dot
    return "󰸞" // check
  }
  readonly property string tooltip: {
    if (!asked) return "Replicant — cargando…"
    if (!state.initialized) return "Replicant — no inicializado\nClick para configurar"
    var t = "Replicant"
    if (state.remote) t += " → " + state.remote
    else t += " (sin remote)"
    t += "\nbranch: " + (state.branch || "?")
    if ((state.ahead || 0) > 0) t += "\n↑ " + state.ahead + " por pushear"
    if ((state.behind || 0) > 0) t += "\n↓ " + state.behind + " por bajar"
    if ((state.dirty || 0) > 0) t += "\n● " + state.dirty + " archivos modificados"
    else if ((state.ahead || 0) === 0 && (state.behind || 0) === 0) t += "\n✓ sincronizado"
    t += "\nClick para abrir panel · Right-click refrescar"
    return t
  }
  readonly property color bg: {
    if (!asked || !state.initialized) return Qt.darker(bar ? bar.barForeground : Color.foreground, 1.6)
    if ((state.ahead || 0) > 0 || (state.dirty || 0) > 0) return Color.accent
    if ((state.behind || 0) > 0) return "#e6a23c"
    return bar ? bar.barForeground : Color.foreground
  }

  function refresh() {
    if (!probe.running) probe.running = true
  }

  Component.onCompleted: { console.log("replicant BarWidget loaded, cli:", cli); refresh() }

  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // when panel opens, refresh immediately
  onOpenedChanged: { console.log("replicant opened:", opened); if (opened) refresh() }

  Process {
    id: probe
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "{}")
          root.state = parsed
          // inject into panel if loaded
          if (panelLoader.item) panelLoader.item.state = parsed
          root.asked = true
        } catch(e) {
          // try fallback cli once
          if (probe.command[0] === root.cli) {
            probe.command = [root.cliFallback, "status", "--json"]
            probe.running = true
            return
          }
          root.state = ({ initialized: false })
          root.asked = true
        }
        probe.command = [root.cli, "status", "--json"]
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        if (probe.command[0] === root.cli) {
          probe.command = [root.cliFallback, "status", "--json"]
          probe.running = true
          return
        }
        root.asked = true
      }
      probe.command = [root.cli, "status", "--json"]
    }
  }

  // Anchor para KeyboardPanel — justo debajo del icono, alineado a la izquierda.
  // No usar visible:false porque QsWindow necesita anchor visible para mapear.
  Item {
    id: panelAnchor
    anchors.left: button.left
    anchors.top: button.bottom
    anchors.topMargin: Style.space(6)
    width: 520
    height: 1
    opacity: 0
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      item.bar = root.bar
      item.anchorItem = panelAnchor
      item.hostWidget = root
      item.state = root.state
      item.cli = root.cli
      item.cliFallback = root.cliFallback
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    bar: root.bar
    text: root.glyph
    tooltipText: root.tooltip
    foreground: root.bg
    onPressed: function(btn) {
      if (btn === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }
}
