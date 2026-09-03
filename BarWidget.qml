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

  property var repoState: ({ initialized: false })
  property bool asked: false
  property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  // symbol by state
  readonly property string glyph: {
    if (!asked) return "⟳"
    if (!repoState.initialized) return "＋"
    if ((repoState.ahead || 0) > 0 && (repoState.behind || 0) > 0) return "⇅"
    if ((repoState.ahead || 0) > 0) return "↑"
    if ((repoState.behind || 0) > 0) return "↓"
    if ((repoState.dirty || 0) > 0) return "●"
    return "R"
  }
  readonly property string tooltip: {
    if (!asked) return "Replicant — loading…"
    if (!repoState.initialized) return "Replicant — not initialized\nClick to set up"
    var t = "Replicant"
    if (repoState.remote) t += " → " + repoState.remote
    else t += " (no remote)"
    t += "\nbranch: " + (repoState.branch || "?")
    if ((repoState.ahead || 0) > 0) t += "\n↑ " + repoState.ahead + " to push"
    if ((repoState.behind || 0) > 0) t += "\n↓ " + repoState.behind + " to pull"
    if ((repoState.dirty || 0) > 0) t += "\n● " + repoState.dirty + " modified files"
    else if ((repoState.ahead || 0) === 0 && (repoState.behind || 0) === 0) t += "\n✓ in sync"
    t += "\nClick to open panel · Right-click to refresh"
    return t
  }
  readonly property color bg: {
    if (!asked || !repoState.initialized) return Qt.darker(bar ? bar.barForeground : Color.foreground, 1.6)
    if ((repoState.ahead || 0) > 0 || (repoState.dirty || 0) > 0) return Color.accent
    if ((repoState.behind || 0) > 0) return "#e6a23c"
    return bar ? bar.barForeground : Color.foreground
  }

  // force = ask the CLI to contact GitHub. The background poll deliberately
  // does not: `status` only fetches when its own throttle has expired, so the
  // once-a-minute tick costs a local git read and nothing else. Opening the
  // panel, pressing refresh, or finishing a write is when a fresh answer
  // actually matters.
  function refresh(force) {
    if (probe.running) return
    probe.command = force ? [root.cli, "status", "--json", "--fetch"]
                          : [root.cli, "status", "--json"]
    probe.running = true
  }

  Component.onCompleted: root.refresh(true)

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  // when the panel opens, get a fresh answer
  onOpenedChanged: if (opened) root.refresh(true)

  Process {
    id: probe
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "{}")
          root.repoState = parsed
          // inject into panel if loaded
          if (panelLoader.item) { panelLoader.item.repoState = parsed; panelLoader.item.asked = true }
          root.asked = true
        } catch(e) {
          // try fallback cli once
          if (probe.command[0] === root.cli) {
            probe.command = [root.cliFallback].concat(probe.command.slice(1))
            probe.running = true
            return
          }
          root.repoState = ({ initialized: false })
          if (panelLoader.item) panelLoader.item.asked = true
          root.asked = true
        }
        probe.command = [root.cli, "status", "--json"]
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        if (probe.command[0] === root.cli) {
          probe.command = [root.cliFallback].concat(probe.command.slice(1))
          probe.running = true
          return
        }
        root.asked = true
        if (panelLoader.item) panelLoader.item.asked = true
      }
      probe.command = [root.cli, "status", "--json"]
    }
  }

  // Anchor for KeyboardPanel — right below the icon
  Item {
    id: panelAnchor
    x: button.x
    y: button.y + button.height + Style.space(6)
    width: 560
    height: 1
    opacity: 0
    visible: true
  }
  onBarChanged: {
    if (panelLoader.item) {
      panelLoader.item.bar = bar
      panelLoader.item.anchorItem = panelAnchor
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      item.bar = root.bar
      item.anchorItem = panelAnchor
      item.hostWidget = root
      item.repoState = root.repoState
      item.asked = root.asked
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
      if (btn === Qt.RightButton) root.refresh(true)
      else root.toggle()
    }
  }
}
