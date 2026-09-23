import QtQuick
import Quickshell.Io

// Owns one CLI process and turns its result into a stable job signal. The
// panel keeps presentation state; this object keeps process state.
Item {
  id: controller

  property string cli: ""
  property string currentJob: ""
  property var currentMeta: ({})
  property var queue: []
  readonly property bool running: process.running
  readonly property bool busy: process.running && currentMeta.busy !== false

  signal completed(string job, int code, string stdoutText, string stderrText, var meta)

  function run(job, command, meta) {
    var details = meta || ({})
    if (process.running) {
      if (details.busy !== false) return false
      var pending = controller.queue.slice()
      pending.push({ job: job, command: command, meta: details })
      controller.queue = pending
      return true
    }
    controller.start(job, command, details)
    return true
  }

  function start(job, command, meta) {
    controller.currentJob = job
    controller.currentMeta = meta || ({})
    process.command = command
    process.running = true
  }

  function isRunning(job) { return process.running && controller.currentJob === job }

  Process {
    id: process
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var job = controller.currentJob
      var meta = controller.currentMeta
      var out = String(process.stdout.text || "")
      var err = String(process.stderr.text || "")
      controller.currentJob = ""
      controller.currentMeta = ({})
      controller.completed(job, code, out, err, meta)
      if (controller.queue.length > 0) {
        var next = controller.queue[0]
        controller.queue = controller.queue.slice(1)
        controller.start(next.job, next.command, next.meta)
      }
    }
  }
}
