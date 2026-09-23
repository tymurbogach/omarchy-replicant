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
  property string stage: "idle"
  readonly property bool cancelAllowed: process.running && currentMeta.cancelable === true
                                          && ["scanning", "encrypting"].indexOf(stage) >= 0
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
    controller.stage = controller.currentMeta.stage || (job === "save" ? "scanning" : "running")
    process.command = command
    process.running = true
  }

  function cancel() {
    if (!controller.cancelAllowed) return false
    controller.stage = "cancelled"
    process.running = false
    return true
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
      var combined = out + "\n" + err
      if (combined.indexOf("stage: committed") >= 0 || combined.indexOf("stage: publishing") >= 0)
        controller.stage = "committed"
      else if (combined.indexOf("stage: encrypting") >= 0) controller.stage = "encrypting"
      else if (combined.indexOf("stage: scanning") >= 0) controller.stage = "scanning"
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
