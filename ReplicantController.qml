import QtQuick
import Quickshell.Io
import "replicant.js" as R

// Owns one CLI process and turns its result into a stable job signal. The
// panel keeps presentation state; this object keeps process state. One queue
// holds every process: interactive jobs run before queued background
// refreshes, duplicate background jobs coalesce, and an accepted user action
// is never discarded. Progress streams while the command runs through a
// SplitParser on stderr; cancellation is allowed only before the commit
// boundary the CLI reports.
Item {
  id: controller

  property string cli: ""
  property string currentJob: ""
  property var currentCommand: []
  property var currentMeta: ({})
  property var queue: []
  property string stage: "idle"
  property bool progressCancellable: false
  property var lastResult: null
  property string stderrBuffer: ""
  property var progressParser: ({ buffer: "" })
  property bool settling: false
  property bool cancelRequested: false
  property string lastOutcome: ""
  readonly property bool cancelAllowed: process.running && currentMeta.cancelable === true
                                          && controller.progressCancellable === true
  readonly property bool running: process.running
  readonly property bool busy: process.running && currentMeta.busy !== false

  signal completed(string job, int code, string stdoutText, string stderrText, var meta)
  signal progressed(string job, string stage, bool cancellable, string message)
  signal started(string job, var meta)

  // Queue or start one job. Returns "started", "queued" or "coalesced".
  // Interactive jobs are always accepted; background duplicates coalesce.
  function run(job, command, meta) {
    var details = meta || ({})
    if (!job || !command || command.length === 0) return ""
    var next = { job: job, command: command.slice(), meta: details }
    if (!controller.settling && process.running && controller.currentJob === job
        && R.queueIsBackground(next)
        && R.queueSameCommand({ command: controller.currentCommand }, next)) return "coalesced"
    if (process.running || controller.settling) {
      var applied = R.queueEnqueue(controller.queue, next)
      controller.queue = applied.queue
      return applied.result === "coalesced" ? "coalesced" : "queued"
    }
    controller.start(job, command, details)
    return "started"
  }

  function start(job, command, meta) {
    controller.currentJob = job
    controller.currentCommand = command.slice()
    controller.currentMeta = meta || ({})
    controller.stderrBuffer = ""
    controller.progressParser = ({ buffer: "" })
    controller.lastResult = null
    controller.lastOutcome = ""
    controller.progressCancellable = false
    controller.cancelRequested = false
    controller.stage = "scanning"
    if (controller.currentMeta.stage) controller.stage = controller.currentMeta.stage
    else if (job === "save" || job === "bulk" || job === "danger") controller.stage = "scanning"
    else controller.stage = "running"
    var cmd = command.slice()
    if (controller.currentMeta.progress !== false && String(cmd[0]) === controller.cli
        && cmd.length > 1 && String(cmd[1]).indexOf("--progress-json") < 0) {
      cmd.splice(1, 0, "--progress-json")
    }
    var isCli = String(command[0]) === controller.cli
    if (isCli) {
      // Quickshell signals one PID. The wrapper forwards that signal to the
      // complete CLI process group, including git and age children.
      var runner = String(controller.cli).replace(/\/[^/]+$/, "/replicant-process.sh")
      cmd.unshift(runner)
    }
    process.environment = ({ REPLICANT_PROCESS_GROUP: null })
    process.command = cmd
    process.running = true
    controller.started(job, controller.currentMeta)
  }

  function cancel() {
    if (!controller.cancelAllowed) return false
    controller.cancelRequested = true
    controller.stage = "cancelled"
    controller.progressCancellable = false
    process.running = false
    return true
  }

  function isRunning(job) { return process.running && controller.currentJob === job }

  function applyProgressEvent(event) {
    if (event.type === "stage") {
      controller.stage = R.progressStageWord(event.stage)
      controller.progressCancellable = event.cancellable
      controller.progressed(controller.currentJob, controller.stage, event.cancellable, event.message)
    } else if (event.type === "result") {
      controller.lastResult = event
      controller.progressCancellable = false
      if (event.outcome === "cancelled") controller.stage = "cancelled"
    }
  }

  function handleStderrChunk(data) {
    var parsed = R.progressParserFeed(controller.progressParser, String(data || ""), false)
    controller.stderrBuffer += parsed.text
    for (var i = 0; i < parsed.events.length; i++) controller.applyProgressEvent(parsed.events[i])
  }

  function settleCurrent(code) {
    if (controller.settling || controller.currentJob === "") return false
    controller.settling = true
    var job = controller.currentJob
    var meta = controller.currentMeta
    var out = String(process.stdout.text || "")
    var finalChunk = R.progressParserFeed(controller.progressParser, "", true)
    controller.stderrBuffer += finalChunk.text
    for (var i = 0; i < finalChunk.events.length; i++) controller.applyProgressEvent(finalChunk.events[i])
    var err = controller.stderrBuffer
    var outcome = controller.lastResult ? controller.lastResult.outcome : ""
    if (outcome === "") {
      if (controller.cancelRequested || controller.stage === "cancelled") outcome = "cancelled"
      else outcome = code === 0 ? "success" : "failed"
    }
    controller.lastOutcome = outcome
    var completionMeta = ({})
    for (var key in meta) completionMeta[key] = meta[key]
    completionMeta.progressResult = controller.lastResult
    completionMeta.outcome = outcome
    if (controller.lastResult && controller.lastResult.recoveryCommand !== null)
      completionMeta.recoveryCommand = controller.lastResult.recoveryCommand
    // Clear process metadata before the next job starts, so a queued job
    // never reads the job that just finished. settling prevents completion
    // callbacks from starting outside this queue.
    controller.currentJob = ""
    controller.currentCommand = []
    controller.currentMeta = ({})
    controller.progressCancellable = false
    controller.cancelRequested = false
    controller.completed(job, code, out, err, completionMeta)
    controller.settling = false
    controller.dispatchNext()
    return true
  }

  function dispatchNext() {
    if (process.running || controller.settling) return false
    if (controller.queue.length === 0) {
      controller.stage = "idle"
      return false
    }
    var next = controller.queue[0]
    controller.queue = controller.queue.slice(1)
    controller.start(next.job, next.command, next.meta)
    return true
  }

  Process {
    id: process
    stdout: StdioCollector { waitForEnd: true }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { controller.handleStderrChunk(data) }
    }
    onExited: function(code) { controller.settleCurrent(code) }
  }
}
