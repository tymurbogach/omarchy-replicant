import QtQuick
import Quickshell
import Quickshell.Io

// keepLoaded service — polls `omarchy-replicant status --json` every 30s
// so bar widget can read it without spawning its own process.
Singleton {
  id: root

  property var replicantState: ({ initialized: false })
  property bool asked: false
  property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-replicant"
  // fallback to plugin bin if symlink missing
  property string cliFallback: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant"

  function refresh() {
    if (!status.running) status.running = true
  }

  Component.onCompleted: refresh()

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: status
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "{}")
          root.replicantState = parsed
        } catch (e) {
          // try fallback cli path
          if (root.command[0] === root.cli) {
            status.command = [root.cliFallback, "status", "--json"]
            status.running = true
            return
          }
          root.replicantState = ({ initialized: false, error: String(e) })
        }
        root.asked = true
        // restore primary cli for next poll
        status.command = [root.cli, "status", "--json"]
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        // fallback once
        if (status.command[0] === root.cli) {
          status.command = [root.cliFallback, "status", "--json"]
          status.running = true
          return
        }
        root.replicantState = ({ initialized: false })
        root.asked = true
        status.command = [root.cli, "status", "--json"]
      }
    }
  }

  IpcHandler {
    target: "omarchy-replicant"
    function status(): string { return JSON.stringify(root.replicantState) }
    function refresh(): void { root.refresh() }
  }
}
