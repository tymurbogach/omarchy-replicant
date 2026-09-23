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
  readonly property var states: ["off", "missing", "incoming", "unsaved", "default", "unpushed", "saved", "locked"]

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

  function test_remote_states_have_clear_words_and_roles() {
    compare(R.remoteStateWord("local-only"), "No remote")
    compare(R.remoteStateWord("offline"), "Remote offline")
    compare(R.remoteStateWord("ahead"), "Local commits not pushed")
    compare(R.remoteStateWord("behind"), "Remote commits pending")
    compare(R.remoteStateWord("diverged"), "Branches diverged")
    compare(R.remoteStateWord("synced"), "Remote synced")
    compare(R.remoteStateRole("ahead"), "accent")
    compare(R.remoteStateRole("behind"), "warn")
    compare(R.remoteStateRole("synced"), "ok")
  }

  function test_locked_needs_a_key_not_a_button() {
    compare(R.stateRole("locked"), "warn")
    verify(R.rowMatchesFilter({ sync_state: "locked" }, "changed"))
    verify(!R.wouldRestore({ synced: true, saved: true, sync_state: "locked" }))
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

  function test_rowsFor_puts_actionable_rows_first() {
    var st = { configs: [
      { id: "saved", label: "a", category: "shell", sync_state: "saved" },
      { id: "changed", label: "z", category: "shell", sync_state: "unsaved" },
      { id: "incoming", label: "b", category: "shell", sync_state: "incoming" }
    ] }
    var rows = R.rowsFor(st, "shell", "", "all")
    compare(rows.map(function(r) { return r.id }).join(","), "incoming,changed,saved")
  }

  function test_entries_are_the_primary_status_shape() {
    var st = { entries: [
      { id: "z.conf", label: "z.conf", src: "/z", kind: "config", source: "override",
        category: "shell", scope: "shared", exists: true, saved: true, sync_state: "saved" },
      { id: "env/key", label: "env/key", kind: "secret", source: "user", category: "secrets",
        scope: "shared", exists: true, saved: true, locked: true, sync_state: "locked" }
    ], configs: [{ id: "old", category: "shell" }], secrets: [{ id: "old-secret" }] }
    var configs = R.rowsFor(st, "shell", "", "all")
    compare(configs.length, 1)
    compare(configs[0].id, "z.conf")
    var secrets = R.rowsFor(st, "secrets", "", "changed")
    compare(secrets.length, 1)
    verify(secrets[0].secret)
    compare(secrets[0].sync_state, "locked")
    compare(R.allRows(st).length, 2)
  }

  function test_lineRole_for_a_diff() {
    compare(R.lineRole("+added", "diff"), "add")
    compare(R.lineRole("-removed", "diff"), "del")
    compare(R.lineRole("--- repo", "diff"), "dim")
    compare(R.lineRole("@@ -1 +1 @@", "diff"), "hunk")
    compare(R.lineRole(" context", "diff"), "fg")
  }

  function test_lineRole_for_command_output() {
    compare(R.lineRole("  ✓ hypr/input.lua (already matches)", "output"), "ok")
    compare(R.lineRole("  ✗ remote is PUBLIC", "output"), "bad")
    compare(R.lineRole("Save failed (exit 1)", "output"), "bad")
    compare(R.lineRole("  · dry-run: 2 files untouched", "output"), "dim")
    compare(R.lineRole("  » mv a b", "output"), "accent")
    compare(R.lineRole("== hyprland · Hyprland", "output"), "head")
    compare(R.lineRole("GitHub", "output"), "head")
    compare(R.lineRole("      +new line", "output"), "add")
    compare(R.lineRole("      -old line", "output"), "del")
    compare(R.lineRole("Everything saved and pushed.", "output"), "fg")
  }

  function test_resultLine() {
    compare(R.resultLine("→ savegame\n  ✓ done\nEverything saved and pushed.", true), "Everything saved and pushed.")
    compare(R.resultLine("Save failed (exit 1)\nsome detail\nRun pull, then save again.", false),
            "Save failed (exit 1): Run pull, then save again.")
    compare(R.resultLine("  ✓ reset hypr/input.lua\n", true), "reset hypr/input.lua")
    compare(R.resultLine("", true), "")
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

  function test_headline_follows_the_order_of_summary() {
    compare(R.headline(facts({ asked: false })).tone, "dim")
    compare(R.headline(facts({ ahead: 1, behind: 1 })).tone, "warn")
    compare(R.headline(facts({ behind: 2, incoming: 1 })).title, "2 changes waiting on GitHub")
    var inc = R.headline(facts({ incoming: 1, dirty: 3 }))
    compare(inc.title, "1 file came from another machine")
    verify(inc.detail.indexOf("Save would overwrite") !== -1, inc.detail)
    compare(inc.detail.indexOf("Restore puts it here"), 0)
    compare(R.headline(facts({ incoming: 2 })).detail.indexOf("Restore puts them here"), 0)
    compare(R.headline(facts({ dirty: 3 })).tone, "accent")
    compare(R.headline(facts({ ahead: 2 })).title, "2 commits not pushed yet")
    var ok = R.headline(facts({ tracked: 68, lastSave: "2 hours ago" }))
    compare(ok.tone, "ok")
    compare(ok.detail, "68 files backed up · last save 2 hours ago")
  }

  function test_nameList_caps_the_names() {
    compare(R.nameList(["a", "b"], 8), "  a\n  b")
    compare(R.nameList(["a", "b", "c"], 2), "  a\n  b\n  +1 more")
  }

  function test_repoPathLabel() {
    compare(R.repoPathLabel("config/hypr/input.lua").label, "hypr/input.lua")
    compare(R.repoPathLabel("config/hypr/input.lua").note, "")
    var p = R.repoPathLabel("profiles/laptop/config/hypr/monitors.lua")
    compare(p.label, "hypr/monitors.lua")
    compare(p.note, "laptop profile")
    compare(R.repoPathLabel("secrets/ssh/id_ed25519").note, "secret")
    compare(R.repoPathLabel("state/omarchy/pacman.txt").label, "state/omarchy/pacman.txt")
  }

  function test_repoCopyText_follows_the_scope() {
    compare(R.repoCopyText({ id: "a.conf", secret: false }, "shared", "laptop"), "config/a.conf")
    compare(R.repoCopyText({ id: "a.conf", secret: false }, "profile", "laptop"), "profiles/laptop/config/a.conf")
    compare(R.repoCopyText({ id: "env/x", secret: true }, "shared", "laptop"), "secrets/env/x")
  }

  function test_sizeText_and_prettyPath() {
    compare(R.sizeText(512), "512 B")
    compare(R.sizeText(2048), "2.0 KB")
    compare(R.sizeText(20480), "20 KB")
    compare(R.sizeText(3 * 1048576), "3.0 MB")
    compare(R.prettyPath("/home/u/.config", "/home/u"), "~/.config")
    compare(R.prettyPath("/home/u", "/home/u"), "~")
    compare(R.prettyPath("/home/user2/x", "/home/u"), "/home/user2/x")
  }

  function test_webUrl_only_for_github() {
    compare(R.webUrl("https://github.com/me/my-replicant.git"), "https://github.com/me/my-replicant")
    compare(R.webUrl("git@github.com:me/my-replicant.git"), "https://github.com/me/my-replicant")
    compare(R.webUrl("/srv/git/repo.git"), "")
  }

  function test_filters_keep_the_rows_they_name() {
    verify(R.rowMatchesFilter({ sync_state: "missing" }, "changed"))
    verify(R.rowMatchesFilter({ sync_state: "incoming" }, "changed"))
    verify(!R.rowMatchesFilter({ sync_state: "saved" }, "changed"))
    verify(R.rowMatchesFilter({ sync_state: "off" }, "off"))
    verify(R.rowMatchesFilter({ sync_state: "saved" }, "all"))
    var st = { configs: [
      { id: "a", label: "a", src: "/a", category: "c", sync_state: "unsaved" },
      { id: "b", label: "b", src: "/b", category: "c", sync_state: "saved" } ] }
    compare(R.rowsFor(st, "c", "", "changed").length, 1)
    compare(R.rowsFor(st, "c", "", "all").length, 2)
  }

  function test_specific_filters_keep_only_their_state_or_size() {
    verify(R.rowMatchesFilter({ sync_state: "incoming" }, "incoming"))
    verify(!R.rowMatchesFilter({ sync_state: "unsaved" }, "incoming"))
    verify(R.rowMatchesFilter({ sync_state: "missing" }, "missing"))
    verify(R.rowMatchesFilter({ sync_state: "locked", locked: true }, "locked"))
    verify(R.rowMatchesFilter({ sync_state: "saved", size: 1024 * 1024 }, "large"))
    verify(!R.rowMatchesFilter({ sync_state: "saved", size: 1024 * 1024 - 1 }, "large"))
  }

  function test_wouldRestore_needs_a_differing_copy() {
    verify(R.wouldRestore({ synced: true, saved: true, sync_state: "unsaved" }))
    verify(R.wouldRestore({ synced: true, saved: true, sync_state: "missing" }))
    verify(!R.wouldRestore({ synced: true, saved: false, sync_state: "unsaved" }))
    verify(!R.wouldRestore({ synced: false, saved: true, sync_state: "off" }))
    verify(!R.wouldRestore({ synced: true, saved: true, sync_state: "saved" }))
  }

  function test_a_scope_change_shows_before_the_status_confirms_it() {
    var row = { id: "a", scope: "shared", sync_state: "saved" }
    compare(R.effectiveScope(row, {}), "shared")
    compare(R.effectiveScope(row, { a: "off" }), "off")
    compare(R.displayState(row, { a: "off" }), "off")
    compare(R.displayState(row, { a: "profile" }), "saved")
    compare(R.displayState({ id: "a", scope: "off", sync_state: "off" }, { a: "shared" }), "pending")
    compare(R.displayState(row, { a: "shared" }), "saved")
    verify(R.stateGlyph("pending") !== R.stateGlyph("saved"))
  }

  function test_originLabel() {
    compare(R.originLabel("https://github.com/me/plug.git"), "github.com/me/plug")
    compare(R.originLabel("git@github.com:me/plug.git"), "github.com/me/plug")
    compare(R.originLabel("https://example.com/x/"), "example.com/x")
    compare(R.originLabel(""), "")
  }

  function test_pluginRows_say_where_the_settings_live() {
    var st = { configs: [ { id: "plugins/hw.json" } ], plugins: [
      { id: "io.x.hw", name: "HW", version: "2", installed: true, origin: "https://h/hw.git", method: "add", recorded: true, in_bar: true },
      { id: "io.x.bar", name: "Bar", version: "1", installed: true, origin: "https://h/bar", method: "add", recorded: true, in_bar: true },
      { id: "io.x.none", name: "None", version: "1", installed: true, origin: "", method: "", recorded: false, in_bar: false },
      { id: "io.x.away", name: "io.x.away", version: "3", installed: false, origin: "https://h/away", method: "add", recorded: false, in_bar: false } ] }
    var rows = R.pluginRows(st)
    compare(rows.length, 4)
    // A file row wins over the bar entry: the file is what the card lists.
    compare(rows[0].settings, "file")
    compare(rows[0].settingsId, "plugins/hw.json")
    compare(rows[1].settings, "bar")
    compare(rows[2].settings, "none")
    compare(R.pluginWhere(rows[0]), "own settings file")
    compare(R.pluginWhere(rows[1]), "settings in shell.json")
    compare(R.pluginWhere(rows[2]), "no settings")
    compare(R.pluginWhere(rows[3]), "not installed here")
    compare(R.pluginDetail(rows[1]), "v1  ·  h/bar")
    // Installed after the last save: the repo does not know it yet.
    compare(R.pluginDetail(rows[2]), "v1  ·  not in your repo yet: the next save records it")
    compare(R.pluginDetail({ version: "", installed: true, recorded: true, origin: "omarchy.indicators", method: "clone" }),
            "a copy of omarchy.indicators, edited here")
    compare(R.pluginDetail({ version: "1", installed: true, recorded: true, origin: "", method: "" }),
            "v1  ·  no origin: nothing can install it again")
  }

  function test_agoText() {
    compare(R.agoText(1000, 1030), "just now")
    compare(R.agoText(0, 600), "10 minutes ago")
    compare(R.agoText(0, 7200), "2 hours ago")
    compare(R.agoText(0, 86400 * 3), "3 days ago")
    compare(R.agoText(2000, 1000), "just now")
  }

  function test_manage_visible_order_and_range() {
    var cards = [
      { rows: [{ id: "a", label: "a", sync_state: "saved" }, { id: "b", label: "b", sync_state: "saved" }] },
      { rows: [{ id: "c", label: "c", sync_state: "saved" }] }
    ]
    var rows = R.visibleRows({}, cards, [{ id: "suggested", path: "/tmp/x", kind: "config" }], "", "all")
    compare(rows.map(function(r) { return r.id }).join(","), "a,b,c,suggested")
    compare(R.rangeIds(rows, "c", "a").join(","), "a,b,c")
  }

  function test_manage_actions_hide_mixed_operations() {
    compare(R.validBulkActions([{ id: "a", source: "user", secret: false }]).join(","),
            "save,convert-secret,untrack,scope-shared,scope-profile,scope-off")
    compare(R.validBulkActions([{ id: "a", secret: false }, { id: "s", secret: true }]).join(","),
            "save")
    compare(R.validBulkActions([{ id: "s", secret: true, locked: true }]).length, 0)
  }

  function test_manage_selection_summary_hides_secret_size() {
    var summary = R.selectionSummary([
      { id: "a", secret: false, is_dir: false, size: 12 },
      { id: "s", secret: true, size: 999999 }
    ])
    compare(summary.selected, 2)
    compare(summary.files, 1)
    compare(summary.bytes, 12)
  }

  function test_navigation_snapshot_copies_session_state() {
    var snapshot = R.navigationSnapshot({
      activeTab: "configs",
      scrollY: { overview: 12, configs: 240, settings: 4 },
      openCards: { shell: true, hidden: false },
      openRow: "hypr/input.lua",
      openCommits: { abc: true },
      fileSearch: "input", stateFilter: "changed",
      settingSearch: "font", settingFilter: "customised",
      manageMode: true, selectedIds: ["a", "b"], selectionAnchor: "b",
      anchor: { kind: "row", id: "hypr/input.lua", offset: 18 }
    })
    compare(snapshot.activeTab, "configs")
    compare(snapshot.scrollY.configs, 240)
    compare(snapshot.openCards.shell, true)
    compare(snapshot.openRow, "hypr/input.lua")
    compare(snapshot.selectedIds.join(","), "a,b")
    compare(snapshot.anchor.kind, "row")
    compare(snapshot.anchor.offset, 18)
  }

  function test_navigation_snapshot_does_not_share_mutable_values() {
    var source = { openCards: { shell: true }, selectedIds: ["a"], scrollY: { configs: 10 } }
    var snapshot = R.navigationSnapshot(source)
    source.openCards.shell = false
    source.selectedIds.push("b")
    source.scrollY.configs = 99
    compare(snapshot.openCards.shell, true)
    compare(snapshot.selectedIds.join(","), "a")
    compare(snapshot.scrollY.configs, 10)
  }

  function test_navigation_scroll_is_clamped() {
    var snapshot = R.navigationSnapshot({ scrollY: { configs: 250 } })
    compare(R.navigationScroll(snapshot, "configs", 100), 100)
    compare(R.navigationScroll(snapshot, "settings", 100), 0)
    compare(R.navigationScroll(snapshot, "configs", -1), 0)
  }
}
