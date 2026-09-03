import QtQuick
import Quickshell
import Quickshell.Io

// keepLoaded service. Its only job is the IPC surface, so a script can ask the
// running shell what Replicant sees without shelling out to git itself:
//
//   omarchy ipc call omarchy-replicant status
//   omarchy ipc call omarchy-replicant refresh
//
// It deliberately does NOT poll on a timer. The bar widget already polls once a
// minute and is the thing that has to stay current; a second poller here meant
// two `status` runs per cycle for a value nothing was reading. The cached
// answer is refreshed on load and whenever someone asks for it.
Item {
  id: root
  visible: false

  property var replicantState: ({ initialized: false })
  property bool asked: false
  // The CLI that ships inside this plugin. Resolved relative to this file, so
  // it is correct no matter where the plugin was installed — including a
  // symlinked dev checkout. It is NOT looked up on PATH: `omarchy plugin add`
  // runs no install hook, so nothing puts omarchy-replicant on PATH, and a
  // fresh install pointing at ~/.local/bin would leave every button in this
  // panel silently doing nothing. `omarchy-replicant link` is the opt-in that
  // adds it to PATH for terminal use; the UI never depends on it.
  readonly property string cli: String(Qt.resolvedUrl("bin/omarchy-replicant")).replace(/^file:\/\//, "")

  function refresh() {
    if (probe.running) return
    probe.command = [root.cli, "status", "--json"]
    probe.running = true
  }

  Component.onCompleted: root.refresh()

  Process {
    id: probe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.replicantState = JSON.parse(text || "{}")
        } catch (e) {
          root.replicantState = ({ initialized: false, error: String(e) })
        }
        root.asked = true
      }
    }
    onExited: function(code) {
      if (code !== 0) root.asked = true
    }
  }

  IpcHandler {
    target: "omarchy-replicant"
    function status(): string { return JSON.stringify(root.replicantState) }
    function refresh(): void { root.refresh() }
  }
}
