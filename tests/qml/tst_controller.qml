import QtQuick
import QtTest
import "../../" as Plugin
import "../../replicant.js" as R

TestCase {
  name: "ControllerQueue"
  property var controller: null
  property var completedJobs: []
  property bool metadataClearedBeforeCompletion: true

  Component {
    id: controllerFactory
    Plugin.ReplicantController { cli: "fake-cli" }
  }

  function init() {
    completedJobs = []
    metadataClearedBeforeCompletion = true
    controller = controllerFactory.createObject(this)
    controller.completed.connect(function(job, code, out, err, meta) {
      completedJobs.push(job)
      if (controller.currentJob !== "" || Object.keys(controller.currentMeta).length !== 0)
        metadataClearedBeforeCompletion = false
    })
  }

  function cleanup() {
    if (controller) controller.destroy()
    controller = null
  }

  function test_interactive_jobs_precede_queued_refreshes() {
    var background = { job: "status", command: ["cli", "status"], meta: { busy: false, background: true } }
    var interactive = { job: "save", command: ["cli", "save"], meta: {} }
    var result = R.queueEnqueue([background], interactive)
    compare(result.result, "queued")
    compare(result.queue[0].job, "save")
    compare(result.queue[1].job, "status")
  }

  function test_duplicate_background_jobs_coalesce() {
    var refresh = { job: "status", command: ["cli", "status", "--json"], meta: { busy: false, background: true } }
    var result = R.queueEnqueue([refresh], refresh)
    compare(result.result, "coalesced")
    compare(result.queue.length, 1)
  }

  function test_accepted_user_actions_are_not_coalesced() {
    var first = { job: "scope", command: ["cli", "scope", "entry", "shared"],
                  meta: { jobId: "entry" } }
    var next = { job: "scope", command: ["cli", "scope", "entry", "profile"],
                 meta: { jobId: "entry" } }
    var result = R.queueEnqueue([first], next)
    compare(result.result, "queued")
    compare(result.queue.length, 2)
    compare(result.queue[0].command[3], "shared")
    compare(result.queue[1].command[3], "profile")
  }

  function test_progress_parser_handles_partial_and_combined_lines() {
    var stage = '{"protocol":1,"type":"stage","stage":"scan","cancellable":true,"message":"Scanning"}'
    var result = '{"protocol":1,"type":"result","outcome":"success","message":"Saved","recoveryCommand":null}'
    var state = { buffer: "" }
    var first = R.progressParserFeed(state, stage.slice(0, 27), false)
    compare(first.events.length, 0)
    compare(first.text, "")
    var second = R.progressParserFeed(state, stage.slice(27) + "\n" + result + "\nnot-json\n", false)
    compare(second.events.length, 2)
    compare(second.events[0].stage, "scan")
    compare(second.events[1].outcome, "success")
    compare(second.text, "not-json\n")
  }

  function test_progress_parser_preserves_malformed_and_combined_json() {
    var state = { buffer: "" }
    var text = '{"protocol":1,"type":"stage","stage":"scan"}{"protocol":1,"type":"stage","stage":"commit"}\n'
    var result = R.progressParserFeed(state, text, false)
    compare(result.events.length, 0)
    compare(result.text, text)
  }

  function test_progress_parser_flushes_final_line() {
    var state = { buffer: "" }
    var line = '{"protocol":1,"type":"result","outcome":"cancelled","message":"Cancelled","recoveryCommand":null}'
    var partial = R.progressParserFeed(state, line, false)
    compare(partial.events.length, 0)
    var final = R.progressParserFeed(state, "", true)
    compare(final.events.length, 1)
    compare(final.events[0].outcome, "cancelled")
    compare(state.buffer, "")
  }

  function test_progress_parser_accepts_a_generic_run_stage() {
    var event = R.parseProgressLine('{"protocol":1,"type":"stage","stage":"run","cancellable":false,"message":"Running"}')
    compare(event.type, "stage")
    compare(R.progressStageWord(event.stage), "running")
    compare(event.cancellable, false)
  }

  function test_real_controller_queues_user_action_during_status_once() {
    var background = ["fake-process", "55"]
    compare(controller.run("status", background, { busy: false, background: true }), "started")
    compare(controller.run("status", background, { busy: false, background: true }), "coalesced")
    compare(controller.run("save", ["fake-process", "10"], {}), "queued")
    compare(controller.queue.length, 1)
    wait(150)
    compare(completedJobs.join(","), "status,save")
    compare(metadataClearedBeforeCompletion, true)
  }

  function test_real_controller_cancels_before_commit_and_settles_once() {
    compare(controller.run("save", ["fake-process", "120", "scan"], { cancelable: true }), "started")
    wait(20)
    compare(controller.stage, "scanning")
    compare(controller.cancelAllowed, true)
    compare(controller.cancel(), true)
    wait(20)
    compare(completedJobs.join(","), "save")
    compare(controller.lastOutcome, "cancelled")
  }

  function test_real_controller_rejects_cancel_after_commit_boundary() {
    compare(controller.run("save", ["fake-process", "45", "commit"], { cancelable: true }), "started")
    wait(20)
    compare(controller.stage, "committing")
    compare(controller.cancelAllowed, false)
    compare(controller.cancel(), false)
    wait(50)
    compare(completedJobs.join(","), "save")
    compare(controller.lastOutcome, "success")
  }

  function test_locked_row_uses_key_word() {
    compare(R.stateWord("locked"), "locked, needs key")
  }
}
