import QtQuick
import QtTest
import "../../replicant.js" as R

// The panel's pure logic, tested without a running shell. run-all.sh runs it:
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
//
// /usr/bin/qmltestrunner is the Qt 5 one, and it cannot load this file.
TestCase {
  name: "ReplicantLogic"

  // Every state the core emits. Guard 7 in run-all.sh keeps the QML and the
  // core in agreement about the names; this keeps each one distinct on screen.
  readonly property var states: ["off", "missing", "incoming", "unsaved", "default", "unpushed", "saved"]

  function facts(o) {
    var f = { asked: true, ready: true, ahead: 0, behind: 0, incoming: 0, dirty: 0 }
    for (var k in o) f[k] = o[k]
    return f
  }

  function test_plural() {
    compare(R.plural(1, "file"), "1 file")
    compare(R.plural(0, "file"), "0 files")
    compare(R.plural(2, "entry", "entries"), "2 entries")
  }

  function test_mdi_builds_one_character_above_ffff() {
    var s = R.mdi(0xF06E1)
    compare(s.codePointAt(0), 0xF06E1)
    compare(s.length, 2)
  }

  function test_every_state_has_its_own_glyph_and_word() {
    var glyphs = {}, words = {}
    for (var i = 0; i < states.length; i++) {
      glyphs[R.stateGlyph(states[i])] = true
      words[R.stateWord(states[i])] = true
    }
    compare(Object.keys(glyphs).length, states.length)
    compare(Object.keys(words).length, states.length)
  }

  function test_incoming_does_not_look_like_save() {
    verify(R.stateRole("incoming") !== R.stateRole("unsaved"))
    compare(R.stateRole("unsaved"), "accent")
    compare(R.stateRole("unpushed"), "accent")
    compare(R.stateRole("saved"), "ok")
    compare(R.stateRole("default"), "dim")
  }

  function test_summary_in_order_of_precedence() {
    compare(R.summary(facts({ asked: false })), "checking…")
    compare(R.summary(facts({ ready: false })), "not set up yet")
    compare(R.summary(facts({ ahead: 1, behind: 1 })), "diverged")
    compare(R.summary(facts({ behind: 2, incoming: 1 })), "2 waiting on GitHub")
    compare(R.summary(facts({ incoming: 1, dirty: 3 })), "changes to restore")
    compare(R.summary(facts({ dirty: 1 })), "unsaved changes")
    compare(R.summary(facts({ ahead: 1 })), "unsaved changes")
    compare(R.summary(facts({})), "everything saved")
  }

  function test_advice_names_restore_before_save() {
    var a = R.advice(facts({ incoming: 1, dirty: 2 }))
    verify(a.indexOf("press Restore, not Save") !== -1, a)
    verify(R.advice(facts({ dirty: 2 })).indexOf("2 files changed") === 0)
    compare(R.advice(facts({})), "")
    compare(R.advice(facts({ ready: false, dirty: 1 })), "")
  }

  function test_rowsFor_filters_sorts_and_adds_secrets() {
    var st = {
      configs: [
        { id: "b", label: "b.conf", src: "/h/b.conf", category: "shell" },
        { id: "a", label: "a.conf", src: "/h/a.conf", category: "shell", scope: "profile" },
        { id: "x", label: "x.conf", src: "/h/x.conf", category: "other" }
      ],
      secrets: [ { id: "env/s", src: "/h/s", sync_state: "saved", synced: false, kind: "env" } ]
    }
    var rows = R.rowsFor(st, "shell", "")
    compare(rows.length, 2)
    compare(rows[0].id, "a")
    compare(rows[0].scope, "profile")
    compare(rows[1].scope, "shared")
    compare(R.rowsFor(st, "shell", "B.C").length, 1)
    var sec = R.rowsFor(st, "secrets", "")
    compare(sec.length, 1)
    verify(sec[0].secret)
    compare(sec[0].scope, "off")
  }

  function test_nextScope_cycles() {
    compare(R.nextScope("shared", true), "profile")
    compare(R.nextScope("profile", true), "off")
    compare(R.nextScope("off", true), "shared")
    compare(R.nextScope("shared", false), "off")
  }

  function test_backupRows_keeps_the_newest_per_id() {
    var rows = R.backupRows([
      { id: "a", path: "a.2", epoch: 2, state: "differs" },
      { id: "a", path: "a.1", epoch: 1, state: "same" },
      { id: "b", path: "b.1", epoch: 1, state: "same" }
    ])
    compare(rows.length, 2)
    compare(rows[0].path, "a.2")
    compare(rows[0].older, 1)
    compare(rows[1].older, 0)
  }

  function test_agoText() {
    compare(R.agoText(1000, 1030), "just now")
    compare(R.agoText(0, 600), "10 minutes ago")
    compare(R.agoText(0, 7200), "2 hours ago")
    compare(R.agoText(0, 86400 * 3), "3 days ago")
    compare(R.agoText(2000, 1000), "just now")
  }
}
