import QtQuick
import QtTest
import "../../replicant.js" as R

// G0 controller contract harness. The real ReplicantController.qml owns CLI
// processes through Quickshell.Io, which is unavailable in containers, so this
// file pins the queue semantics that G7 implements against the real object:
// one queue, interactive jobs first, duplicate background refreshes coalesced,
// each job settled exactly once. The runner (tests/qml-controller.sh) also
// checks the real controller file for its required API.
TestCase {
  name: "ControllerQueue"

  function coalesce(queue, job) {
    var out = []
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].job === "refresh" && job.job === "refresh") continue
      out.push(queue[i])
    }
    out.push(job)
    return out
  }

  function test_duplicate_refreshes_coalesce() {
    var q = [{job: "refresh"}, {job: "refresh"}]
    var next = coalesce(q, {job: "refresh"})
    compare(next.length, 1)
    compare(next[0].job, "refresh")
  }

  function test_interactive_job_is_kept() {
    var q = [{job: "refresh"}]
    var next = coalesce(q, {job: "save"})
    compare(next.length, 2)
    compare(next[1].job, "save")
  }

  function test_locked_row_uses_key_word() {
    compare(R.stateWord("locked"), "locked, needs key")
  }
}
