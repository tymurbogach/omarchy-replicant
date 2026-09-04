import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.tymurbogach.omarchy-replicant"

  // The CLI that ships inside this plugin. Resolved relative to this file, so
  // it is correct no matter where the plugin was installed — including a
  // symlinked dev checkout. It is NOT looked up on PATH: `omarchy plugin add`
  // runs no install hook, so nothing puts omarchy-replicant on PATH, and a
  // fresh install pointing at ~/.local/bin would leave every button in this
  // panel silently doing nothing. `omarchy-replicant link` is the opt-in that
  // adds it to PATH for terminal use; the UI never depends on it.
  readonly property string cli: String(Qt.resolvedUrl("bin/omarchy-replicant")).replace(/^file:\/\//, "")

  property var repoState: ({ initialized: false })
  property bool asked: false
  property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  // Symbol by state. Material Design Icon code points, not pasted glyphs — see
  // the note in Panel.qml: these all live above U+FFFF, where a re-encoding of
  // the file silently truncates the character into a different symbol.
  //
  // At rest the widget shows the plugin's own mark — hexagon-multiple: identical
  // cells, more than one of them. It used to show the GitHub logo; GitHub is
  // only where the copy happens to be kept, and the icon should say what the
  // thing does, not who stores it.
  //
  // The FILLED variant is here and the outline one is in Panel.qml, and that is
  // not arbitrary. Every candidate was rendered at the real bar size before
  // choosing: at 13px the outline hexagons lose their interior and read as three
  // rings, while the filled ones keep their shape. Outline detail needs the
  // panel header's 30px to survive.
  function mdi(cp) { return String.fromCodePoint(cp) }
  readonly property string glyph: {
    if (!asked) return root.mdi(0xF0450)                                         // refresh
    if (!repoState.initialized) return root.mdi(0xF0415)                         // plus
    if ((repoState.ahead || 0) > 0 && (repoState.behind || 0) > 0) return root.mdi(0xF002A)  // alert
    if ((repoState.ahead || 0) > 0) return root.mdi(0xF0167)                     // cloud-upload
    if ((repoState.behind || 0) > 0) return root.mdi(0xF0162)                    // cloud-download
    if ((repoState.dirty || 0) > 0) return root.mdi(0xF0193)                     // content-save
    return root.mdi(0xF06E1)                                                     // hexagon-multiple
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
  //
  // The tick also asks for --brief. This icon reads six numbers; the full
  // payload builds fifty file rows, twenty-four settings and every category,
  // which took 1.4 s of CPU once a minute to answer them. Brief takes 0.04 s.
  // Whenever the panel is open — or a write just finished — the full payload is
  // built, because that is when anybody is actually looking at the rows.
  // A request that arrives while a probe is in flight used to be dropped. Open
  // the panel during the once-a-minute tick and it rendered whatever that tick
  // returned — since 0.7.0 a *brief* payload, with no rows in it — and nothing
  // asked again until the next tick a minute later. Remember it instead.
  property bool refreshPending: false
  property bool refreshPendingForce: false
  function refresh(force) {
    if (probe.running) {
      root.refreshPending = true
      root.refreshPendingForce = root.refreshPendingForce || force === true
      return
    }
    var full = force || root.opened
    var cmd = [root.cli, "status", "--json"]
    if (force) cmd.push("--fetch")
    if (!full) cmd.push("--brief")
    probe.command = cmd
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
          // A brief answer carries the counters and nothing else. Assigning it
          // whole would empty the rows the panel is drawing from, so its fields
          // are merged over what is already known instead.
          if (parsed.brief === true && root.repoState && root.repoState.initialized) {
            var merged = {}
            for (var k in root.repoState) merged[k] = root.repoState[k]
            for (var j in parsed) merged[j] = parsed[j]
            parsed = merged
          }
          root.repoState = parsed
          if (panelLoader.item) { panelLoader.item.repoState = parsed; panelLoader.item.asked = true }
        } catch (e) {
          root.repoState = ({ initialized: false })
        }
        root.asked = true
        if (panelLoader.item) panelLoader.item.asked = true
      }
    }
    onExited: function(code) {
      // A non-zero exit still answers the question "what is the state?" — the
      // status JSON on stdout is authoritative, and stdout has already been
      // collected by the time this fires (waitForEnd).
      if (code !== 0) {
        root.asked = true
        if (panelLoader.item) panelLoader.item.asked = true
      }
      if (root.refreshPending) {
        var f = root.refreshPendingForce
        root.refreshPending = false; root.refreshPendingForce = false
        root.refresh(f)
      }
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
