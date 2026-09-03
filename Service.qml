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
  property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-replicant"
  // fallback to the plugin's own bin when ~/.local/bin/omarchy-replicant is missing
  property string cliFallback: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant"

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
          // One retry through the fallback path before giving up. This used to
          // read `root.command`, which does not exist on an Item — so the retry
          // threw instead of retrying and the service reported "not
          // initialized" for the rest of the session.
          if (probe.command[0] === root.cli) {
            probe.command = [root.cliFallback].concat(probe.command.slice(1))
            probe.running = true
            return
          }
          root.replicantState = ({ initialized: false, error: String(e) })
        }
        root.asked = true
      }
    }
    onExited: function(code) {
      if (code === 0) return
      if (probe.command[0] === root.cli) {
        probe.command = [root.cliFallback].concat(probe.command.slice(1))
        probe.running = true
        return
      }
      root.replicantState = ({ initialized: false })
      root.asked = true
    }
  }

  IpcHandler {
    target: "omarchy-replicant"
    function status(): string { return JSON.stringify(root.replicantState) }
    function refresh(): void { root.refresh() }
  }
}
