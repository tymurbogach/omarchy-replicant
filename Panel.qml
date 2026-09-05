import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Replicant panel: four tabs over one CLI.
//
// Layout note: everything below the Overview tab is an ACCORDION. Forty-odd
// tracked files and twenty settings as one flat list meant a scrollbar the
// length of your arm and no sense of where anything was. Collapsed cards, one
// per area, fit the whole picture on one screen; you open the one you came for.
//
// Naming note: the status payload lives in `repoState`, NOT `state`. Every QML
// Item already has a built-in `state` string, so inside any nested item a bare
// `state.foo` silently resolves to that empty string instead of our data — the
// panel renders a correct header over sections that all believe there is no
// repo. Renaming the property removes the whole class of bug rather than
// relying on every nested reference remembering to say `root.`.
Panel {
  id: root
  moduleName: "io.github.tymurbogach.omarchy-replicant"
  // Opens from a keybinding as well as from the bar icon:
  //   omarchy shell replicant toggle
  // Bind it in ~/.config/hypr/bindings.lua if you want the panel on a key. The
  // base Panel's IpcHandler calls the open/close/toggle defined below, so both
  // routes end up in exactly the same place.
  manageIpc: true
  ipcTarget: "replicant"

  // The CLI that ships inside this plugin. Resolved relative to this file, so
  // it is correct no matter where the plugin was installed — including a
  // symlinked dev checkout. It is NOT looked up on PATH: `omarchy plugin add`
  // runs no install hook, so nothing puts omarchy-replicant on PATH, and a
  // fresh install pointing at ~/.local/bin would leave every button in this
  // panel silently doing nothing. `omarchy-replicant link` is the opt-in that
  // adds it to PATH for terminal use; the UI never depends on it.
  readonly property string cli: String(Qt.resolvedUrl("bin/omarchy-replicant")).replace(/^file:\/\//, "")
  property var repoState: ({ initialized: false, configs: [], secrets: [], settings: [], categories: [], setting_groups: [], machines: [] })
  // True once a real status response has come back at least once. Gates the
  // "no repo yet — create one" screen: showing it before we know the state let
  // a stray click re-point an already-configured remote (a real incident).
  property bool asked: false

  property string lastOutput: ""
  property string activeTab: "overview"
  property string fileSearch: ""
  property string settingSearch: ""
  property var recent: []
  property var shortcuts: ({ own: [], active: [], own_count: 0, active_count: 0 })
  property bool shortcutsLoaded: false
  property bool showAllShortcuts: false

  // Which accordion cards are open. A plain object, reassigned wholesale on
  // every change — mutating it in place does not re-evaluate the bindings that
  // read it.
  property var openCards: ({})
  function isOpen(id) { return root.openCards[id] === true }
  function toggleCard(id) {
    var next = {}
    for (var k in root.openCards) next[k] = root.openCards[k]
    next[id] = !next[id]
    root.openCards = next
    if (id === "shortcuts" && next[id] && !root.shortcutsLoaded) root.loadShortcuts()
  }
  function closeAllCards() { root.openCards = ({}) }

  // ── in-flight state ───────────────────────────────────────────────────────
  readonly property bool busy: saveProc.running || setProc.running || pullProc.running
                            || backupProc.running || fileSaveProc.running || dangerProc.running
  property string busyLabel: ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color okColor: "#4caf50"
  // The same amber the bar icon already uses for "there is something on GitHub
  // you have not got yet". One idea, one colour, in both places you can see it.
  readonly property color warnColor: "#e6a23c"
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property string mono: "monospace"

  readonly property bool ready: !!(repoState && repoState.initialized === true)

  // ── icons ─────────────────────────────────────────────────────────────────
  // Held as Material Design Icon CODE POINTS, not as pasted glyphs. Two reasons:
  // the name next to each number says what it is meant to be (the previous set
  // was chosen from memory and shipped a plus-minus sign as "reset" and a
  // crossed-out cloud as "pull"), and every one of these lives above U+FFFF,
  // where a stray re-encoding of this file silently truncates the glyph to a
  // different character. Each was rendered against the shell's own font and
  // looked at before being used.
  function mdi(cp) { return String.fromCodePoint(cp) }

  // Paths are shown the way the CLI shows them. A row is about 40 characters
  // wide once the scope button and five actions have taken their share, and
  // "/home/cyberdyne" is a third of that spent saying nothing.
  function pretty(p) {
    var h = root.repoState.home || ""
    if (h !== "" && String(p).indexOf(h) === 0) return "~" + String(p).slice(h.length)
    return String(p)
  }
  // Where a file lives, but only when that is not already on screen. A row's
  // title IS its path under ~/.config with the prefix taken off, so printing
  // "~/.config/alacritty/alacritty.toml" under a title that reads
  // "alacritty/alacritty.toml" spends the row's scarcest resource — width —
  // saying nothing, and it was the width the rows that DO surprise you needed:
  // a dotfile in $HOME, a script in ~/.local/bin, a drop-in under /etc. Those
  // now print whole instead of every row printing "~/.confi…".
  function whereText(c) {
    var src = String(c.src || "")
    var h = root.repoState.home || ""
    if (h !== "" && src === h + "/.config/" + String(c.id || "")) return ""
    return root.pretty(src)
  }
  readonly property string icRefresh: root.mdi(0xF0450)    // refresh
  readonly property string icPush: root.mdi(0xF0167)    // cloud-upload
  readonly property string icPull: root.mdi(0xF0162)    // cloud-download
  readonly property string icCopy: root.mdi(0xF018F)    // content-copy
  readonly property string icEdit: root.mdi(0xF03EB)    // pencil
  readonly property string icDiff: root.mdi(0xF08AA)    // file-compare
  readonly property string icSave: root.mdi(0xF0193)    // content-save
  readonly property string icDefault: root.mdi(0xF099B)    // restore
  readonly property string icFromRepo: root.mdi(0xF01DA)    // download
  readonly property string icShield: root.mdi(0xF0498)    // shield
  readonly property string icFolder: root.mdi(0xF024B)    // folder
  readonly property string icPlus: root.mdi(0xF0415)    // plus
  readonly property string icBranch: root.mdi(0xF062C)    // source-branch
  readonly property string icClose: root.mdi(0xF0156)    // close
  readonly property string icDown: root.mdi(0xF0140)    // chevron-down
  readonly property string icRight: root.mdi(0xF0142)    // chevron-right
  readonly property string icInfo: root.mdi(0xF02FC)    // information
  readonly property string icMachine: root.mdi(0xF0176)    // laptop
  // The plugin's own mark: identical cells, more than one of them. Chosen over
  // the GitHub logo because GitHub is where the copy happens to live, not what
  // this does. The OUTLINE variant is used here and the filled one in the bar —
  // at 30px the outline reads as three distinct hexagons, at 13px it collapses
  // into rings, so the bar gets the filled one. The scope button below keeps
  // content-duplicate for "Shared", which is a different idea (one copy everyone
  // reads) and sits next to its own text label.
  readonly property string icReplicant: root.mdi(0xF10F2)   // hexagon-multiple-outline
  readonly property string icShared: root.mdi(0xF0191)      // content-duplicate
  readonly property string icProfile: root.mdi(0xF0322)     // laptop
  readonly property string icOff: root.mdi(0xF0377)         // minus-circle-outline
  // A list with a minus, NOT a waste basket. Untracking removes an entry from
  // your list and the copy from the repo; the file on the machine is untouched,
  // and a trash can on that button would say the opposite of what it does.
  readonly property string icUntrack: root.mdi(0xF0410)     // playlist-remove

  // ── derived summaries ─────────────────────────────────────────────────────
  // One place maps a sync state to how it looks, so a new state cannot be added
  // to the core and silently render as the fallback in three different rows.
  function stateGlyph(st) {
    if (st === "off") return "⊘"
    if (st === "missing") return "·"
    // Down, against unsaved's dot and unpushed's up arrow. The three states that
    // ask for an action say which direction that action moves the file in.
    if (st === "incoming") return "↓"
    if (st === "unsaved") return "●"
    if (st === "unpushed") return "↑"
    if (st === "default") return "○"
    return "◆"
  }
  function stateColor(st) {
    // Its own colour, and deliberately not the accent the other two "do
    // something" states share: pressing Save on an incoming row is the one
    // mistake in this panel that destroys somebody else's work, so the badge
    // must not look like the badge that asks for Save.
    if (st === "incoming") return root.warnColor
    if (st === "unsaved") return Color.accent
    if (st === "unpushed") return Color.accent
    if (st === "saved") return root.okColor
    return root.dim
  }
  function stateWord(st) {
    if (st === "off") return "not synced"
    if (st === "missing") return "not on this machine"
    // Short on purpose. These are printed beside the path on a row that also
    // carries a Save button and sits under a banner that already says "press
    // Save to GitHub", so a longer sentence bought nothing and cost the path
    // its last few characters on exactly the rows that had one worth reading.
    if (st === "incoming") return "newer copy in your repo"
    if (st === "unsaved") return "not saved yet"
    if (st === "unpushed") return "not pushed yet"
    if (st === "default") return "untouched Omarchy default"
    return "saved on GitHub"
  }

  // "1 file", "4 files". The panel printed "file(s)" eleven times on one screen
  // and the number was always right there next to it.
  function plural(n, one, many) { return n + " " + (n === 1 ? one : (many || one + "s")) }

  readonly property string profileName: root.repoState.profile || "this machine"
  readonly property int scopedCount: (root.repoState.configs || []).filter(function(c){ return c.scope === "profile" }).length
  // Counted from the rows themselves, not from repoState.dirty. The badges and
  // the header have to answer to one source or they contradict each other — the
  // git count only ever saw files already copied into the repo, so the header
  // could read EVERYTHING SAVED while rows below it showed unsaved changes.
  readonly property int nDirty: (root.repoState.configs || []).filter(function(c){
    return c.sync_state === "unsaved"
  }).length + (root.repoState.secrets || []).filter(function(s){
    return s.sync_state === "unsaved"
  }).length
  // Files a pull brought a newer copy of. Counted the same way and from the same
  // rows, because this is the one state where pressing the OTHER button — Save —
  // commits over what another machine did.
  readonly property int nIncoming: (root.repoState.configs || []).filter(function(c){
    return c.sync_state === "incoming"
  }).length + (root.repoState.secrets || []).filter(function(s){
    return s.sync_state === "incoming"
  }).length
  readonly property int nAhead: repoState.ahead || 0
  readonly property int nBehind: repoState.behind || 0

  readonly property string summary: {
    if (!root.asked) return "checking…"
    if (!root.ready) return "not set up yet"
    if (root.nAhead > 0 && root.nBehind > 0) return "diverged"
    if (root.nBehind > 0) return root.nBehind + " waiting on GitHub"
    if (root.nIncoming > 0) return "changes to restore"
    if (root.nDirty > 0 || root.nAhead > 0) return "unsaved changes"
    return "everything saved"
  }

  // One sentence telling the user what to do next, or nothing at all when
  // there is nothing to do. A banner that is always present stops being read.
  readonly property string advice: {
    if (!root.asked || !root.ready) return ""
    if (root.nBehind > 0) return "Another machine saved " + root.plural(root.nBehind, "change") + " — press Pull to bring them here."
    // Before the unsaved line, and that order is the whole point of the state.
    // Both mean "this file and its copy differ"; only this one knows which way,
    // and pressing Save here commits over what the other machine saved.
    // One line, and it has to fit on one line: the banner elides, and the half
    // that got cut was the half naming the button.
    if (root.nIncoming > 0) return root.plural(root.nIncoming, "file") + " came from another machine — press Restore, not Save."
    if (root.nDirty > 0) return root.plural(root.nDirty, "file") + " changed on this machine — press Save to GitHub."
    if (root.nAhead > 0) return root.plural(root.nAhead, "commit") + " committed but not pushed — press Save to GitHub."
    return ""
  }

  readonly property var tabs: [
    { value: "overview", label: "Overview", icon: root.mdi(0xF056E), tooltip: "This machine at a glance  (1)" },
    { value: "configs",  label: "Configs",  icon: root.mdi(0xF107F), tooltip: "Everything being backed up, by area  (2)" },
    { value: "settings", label: "Settings", icon: root.mdi(0xF0493), tooltip: "Change a value and it is written and saved  (3)" },
    { value: "restore",  label: "Restore",  icon: root.mdi(0xF099B), tooltip: "Bring a whole machine back  (4)" }
  ]

  // ── one uniform row shape for configs and secrets ─────────────────────────
  // Secrets live in their own part of the payload because they carry different
  // facts (mode, kind, the NAMES of the variables and never their values), but
  // the panel shows them in the same list as everything else in their area.
  function secretRows() {
    var out = []
    var list = root.repoState.secrets || []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      out.push({
        id: s.id, label: s.id, src: s.src, category: "secrets",
        sync_state: s.sync_state, exists: s.exists, has_default: false,
        synced: s.synced, scope: s.synced === false ? "off" : "shared",
        source: s.source || "manifest", is_dir: false, nfiles: 0,
        secret: true, kind: s.kind, mode: s.mode,
        vars: s.vars || [], var_count: s.var_count || 0
      })
    }
    return out
  }

  function rowsFor(categoryId) {
    var out = []
    var list = root.repoState.configs || []
    var needle = root.fileSearch.toLowerCase()
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if ((c.category || "other") !== categoryId) continue
      out.push({
        id: c.id, label: c.label, src: c.src, category: c.category,
        sync_state: c.sync_state, exists: c.exists, has_default: c.has_default,
        synced: c.synced, scope: c.scope || "shared",
        source: c.source || "manifest", is_dir: c.is_dir === true, nfiles: c.nfiles || 0,
        secret: false, kind: "", mode: "", vars: [], var_count: 0
      })
    }
    if (categoryId === "secrets") out = out.concat(root.secretRows())
    if (needle !== "") {
      out = out.filter(function(r) {
        return (String(r.label) + " " + String(r.src)).toLowerCase().indexOf(needle) !== -1
      })
    }
    out.sort(function(a, b) { return String(a.label).localeCompare(String(b.label)) })
    return out
  }

  // Categories that actually have something in them, with their counts. An
  // empty card is a card you have to read and then dismiss.
  readonly property var categoryCards: {
    var cats = root.repoState.categories || []
    var out = []
    for (var i = 0; i < cats.length; i++) {
      var rows = root.rowsFor(cats[i].id)
      if (rows.length === 0) continue
      // Counted from the same states the badges render, not a separate word.
      // This once tested for "modified", a state that no longer exists, so every
      // card cheerfully said "in sync" while its own rows showed unsaved changes.
      var changed = 0, off = 0, incoming = 0
      for (var j = 0; j < rows.length; j++) {
        if (rows[j].sync_state === "unsaved" || rows[j].sync_state === "unpushed") changed++
        if (rows[j].sync_state === "incoming") incoming++
        if (rows[j].synced === false) off++
      }
      out.push({
        id: cats[i].id, icon: cats[i].icon, label: cats[i].label,
        description: cats[i].description, method: cats[i].method,
        rows: rows, count: rows.length, changed: changed, off: off, incoming: incoming
      })
    }
    return out
  }

  readonly property int statColumns: root.nIncoming > 0 ? 5 : 4
  readonly property int countChanged: root.nDirty
  readonly property int countOff: (root.repoState.configs || []).filter(function(c){ return c.synced === false }).length

  // ── settings, grouped in registry order ───────────────────────────────────
  readonly property var settingGroups: {
    var meta = root.repoState.setting_groups || []
    var list = root.repoState.settings || []
    var needle = root.settingSearch.toLowerCase()
    var out = []
    for (var g = 0; g < meta.length; g++) {
      var items = list.filter(function(s) { return s.group === meta[g].name })
      if (needle !== "") {
        items = items.filter(function(s) {
          return (String(s.label) + " " + String(s.id) + " " + String(s.hint)).toLowerCase().indexOf(needle) !== -1
        })
      }
      if (items.length === 0) continue
      var changed = items.filter(function(s) { return s.can_revert_default }).length
      out.push({ id: "set:" + meta[g].name, name: meta[g].name, icon: meta[g].icon,
                 description: meta[g].description, items: items, changed: changed })
    }
    return out
  }

  // A handful of values worth seeing without opening a tab.
  function settingText(id) {
    var list = root.repoState.settings || []
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i].value_text || "—"
    return "—"
  }

  // ── actions ───────────────────────────────────────────────────────────────
  function refresh() { if (hostWidget) hostWidget.refresh(true); logProc.running = true }
  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  // --auto is not a convenience here, it is the difference between the button
  // working and not. Bare `savegame` commits the inventory, pushes that, and
  // deliberately leaves config and secrets copied-in-but-uncommitted so a human
  // can write one commit per change explaining why — and this panel has nowhere
  // to type that why. Pressing Save tracked a secret, copied it in, and left it
  // uncommitted, with every badge as red as before.
  function doSavegame() { root.busyLabel = "Saving to GitHub…"; saveProc.command = [root.cli, "savegame", "--auto"]; saveProc.running = true }
  function doPull()     { root.busyLabel = "Pulling…";          pullProc.command = [root.cli, "pull", "-y"]; pullProc.running = true }
  function doBackup()   { root.busyLabel = "Copying files…";    backupProc.command = [root.cli, "backup"]; backupProc.running = true }
  function doDoctor()   { root.busyLabel = "Checking…";         root.lastOutput = "Running health check…"; doctorProc.command = [root.cli, "doctor"]; doctorProc.running = true }

  function loadShortcuts() { shortcutsProc.command = [root.cli, "shortcuts", "--json"]; shortcutsProc.running = true }

  // Open the editor. Deliberately NOT through
  // omarchy-launch-floating-terminal-with-presentation: that wraps the command
  // in the Omarchy logo plus a "press a key to close" prompt, so reading one
  // file cost two extra interactions. The CLI detaches the editor itself.
  // The panel closes so the editor is not opened behind it, and comes back the
  // moment the editor is closed — same tab, same open cards, because close()
  // keeps both. Only some editors can be waited on, so the CLI says whether it
  // actually waited; reopening the panel over a floating terminal editor would
  // be worse than leaving it shut.
  function doEdit(id) {
    editProc.command = [root.cli, "edit", id, "--wait"]
    editProc.running = true
    root.lastOutput = "Opening " + id + " in your editor…"
    root.close()
  }

  // Diffs are read, not interacted with, so they belong in the panel next to
  // the file they describe rather than in a terminal that has to be dismissed.
  function doDiff(id) {
    root.diffTitle = id
    root.diffText = "Loading…"
    root.diffOpen = true
    diffProc.command = [root.cli, "diff", id]
    diffProc.running = true
  }

  function doSaveFile(id) {
    root.busyLabel = "Saving " + id + "…"
    fileSaveProc.command = [root.cli, "save-file", id, "-m", "config: update " + id]
    fileSaveProc.running = true
  }

  function doSetSetting(id, value) {
    root.busyLabel = "Saving " + id + "…"
    setProc.command = [root.cli, "set", id, String(value)]
    setProc.running = true
  }

  function doRevert(id, to) {
    root.busyLabel = "Reverting " + id + "…"
    setProc.command = [root.cli, "revert", id, "--to", to]
    setProc.running = true
  }

  // Three scopes, cycled in the order a person actually reasons about them:
  // "everyone gets this" -> "each kind of machine gets its own" -> "nobody".
  function nextScope(scope, allowProfile) {
    if (scope === "off") return "shared"
    if (scope === "shared") return allowProfile ? "profile" : "off"
    return "off"
  }
  function scopeLabel(scope) {
    if (scope === "profile") return root.profileName
    if (scope === "off") return "Off"
    return "Shared"
  }
  function scopeIcon(scope) {
    if (scope === "profile") return root.icProfile
    if (scope === "off") return root.icOff
    return root.icShared
  }
  function scopeHint(scope, allowProfile) {
    if (scope === "shared" && !allowProfile)
      return "One copy, shared by every machine on this repo. Click for: off"
    if (scope === "profile")
      return "Kept per profile: this machine saves and restores the '" + root.profileName
           + "' copy, and never overwrites another profile's. Click for: off"
    if (scope === "off")
      return "Not saved from here and not restored onto here. Whatever the repo "
           + "already holds is left alone. Click for: shared"
    return "One copy, shared by every machine on this repo. Click for: per profile"
  }
  // ── the user's own list ───────────────────────────────────────────────────
  // The shipped manifest is what every Omarchy user plausibly has. Everything
  // else is the user's, and adding to it has to be one click or the list stays
  // whatever the plugin decided. `suggest` does the finding; the panel only
  // ever proposes, and nothing is tracked until the button is pressed.
  property var suggestions: []
  property bool suggestLoaded: false
  function loadSuggestions() {
    suggestProc.command = [root.cli, "suggest", "--json"]
    suggestProc.running = true
  }

  // ── the safety net, made visible ──────────────────────────────────────────
  // Every write this plugin makes to the machine keeps what it overwrote as
  // <file>.bak.<epoch>. For four releases the only code that could find one was
  // `purge`, which removes the whole plugin — eleven of them were sitting on
  // the machine this was built on, unnamed and unreachable. A backup you cannot
  // find is not a backup, and "I restored and it was wrong" is the exact moment
  // somebody opens this tab.
  property var backups: []
  property bool backupsLoaded: false
  function loadBackups() {
    backupsProc.command = [root.cli, "backups-json"]
    backupsProc.running = true
  }
  // Newest per id: undo takes the newest, so a row per id is a row per button.
  // The rest are counted, never listed — twelve rows of the same file is a wall,
  // and only one of them is reachable.
  readonly property var backupRows: {
    var seen = ({}), out = []
    for (var i = 0; i < root.backups.length; i++) {
      var b = root.backups[i]
      if (seen[b.id]) { out[seen[b.id] - 1].older += 1; continue }
      seen[b.id] = out.push({ id: b.id, path: b.path, epoch: b.epoch,
                              state: b.state, older: 0 })
    }
    return out
  }
  function doUndo(id) {
    root.busyLabel = "Undoing " + id + "…"
    undoProc.command = [root.cli, "undo", id, "--apply"]
    undoProc.running = true
  }
  function doPruneBackups() {
    root.busyLabel = "Removing backups…"
    undoProc.command = [root.cli, "backups", "--prune", "--apply"]
    undoProc.running = true
  }
  // A backup's age in the words a person uses about one. The epoch is in the
  // filename and says nothing; "3 days ago" is the whole question being asked.
  function agoText(epoch) {
    var s = Math.max(0, Math.floor(Date.now() / 1000) - epoch)
    if (s < 90) return "just now"
    if (s < 5400) return root.plural(Math.round(s / 60), "minute") + " ago"
    if (s < 129600) return root.plural(Math.round(s / 3600), "hour") + " ago"
    return root.plural(Math.round(s / 86400), "day") + " ago"
  }
  function doTrack(path, kind) {
    root.busyLabel = "Tracking " + path + "…"
    var cmd = [root.cli, "track", path]
    if (kind === "secret") cmd.push("--secret")
    trackProc.command = cmd
    trackProc.running = true
  }
  function doUntrack(id) {
    root.busyLabel = "Untracking " + id + "…"
    trackProc.command = [root.cli, "untrack", id]
    trackProc.running = true
  }

  function doScope(id, scope) {
    root.busyLabel = "Setting " + id + " to " + scope + "…"
    fileSaveProc.command = [root.cli, "scope", id, scope]
    fileSaveProc.running = true
  }

  // Controls that emit a burst of values (holding a stepper, dragging a
  // slider) would otherwise be one commit and push per intermediate value.
  property string pendingSettingId: ""
  property string pendingSettingValue: ""
  function queueSetting(id, value) {
    root.pendingSettingId = id
    root.pendingSettingValue = String(value)
    settingDebounce.restart()
  }
  Timer {
    id: settingDebounce
    interval: 900
    onTriggered: if (root.pendingSettingId !== "") { root.doSetSetting(root.pendingSettingId, root.pendingSettingValue); root.pendingSettingId = "" }
  }

  // ── confirmations ─────────────────────────────────────────────────────────
  // Every destructive action is confirmed here rather than in a terminal, and
  // then runs headless with --yes. The terminal round-trip was the thing that
  // made these feel heavy, not the confirmation itself.
  property string confirmAction: ""
  property string confirmArg: ""
  function ask(action, arg, message, confirmText) {
    root.confirmAction = action
    root.confirmArg = arg || ""
    confirmDialog.message = message
    confirmDialog.confirmText = confirmText
    confirmDialog.selectedIndex = 0
    confirmDialog.opened = true
  }
  function runConfirmed() {
    var a = root.confirmAction, arg = root.confirmArg
    root.confirmAction = ""; root.confirmArg = ""
    confirmDialog.opened = false
    if (a === "reset-file")        { root.busyLabel = "Resetting " + arg + "…"; dangerProc.command = [root.cli, "reset", arg] }
    else if (a === "restore-file") { root.busyLabel = "Restoring " + arg + "…"; dangerProc.command = [root.cli, "restore-file", arg] }
    else if (a === "reset-all")    { root.busyLabel = "Resetting everything…"; dangerProc.command = [root.cli, "reset-all", "--apply", "--yes"] }
    else if (a === "restore-all")  { root.busyLabel = "Restoring everything…"; dangerProc.command = [root.cli, "restore", "--apply", "--all", "--yes"] }
    // --only with --yes, and no --all: passing --all alongside --only used to be
    // required because --yes was only honoured through it, which read like a
    // contradiction. It is not needed any more.
    else if (a === "restore-cat")  { root.busyLabel = "Restoring " + arg + "…"; dangerProc.command = [root.cli, "restore", "--apply", "--yes", "--only", arg] }
    else if (a === "untrack")      { root.doUntrack(arg); return }
    else if (a === "undo")          { root.doUndo(arg); return }
    else if (a === "prune-backups") { root.doPruneBackups(); return }
    else return
    root.lastOutput = root.busyLabel
    dangerProc.running = true
  }

  // ── inline diff viewer ────────────────────────────────────────────────────
  property bool diffOpen: false
  property string diffTitle: ""
  property string diffText: ""

  // ── processes ─────────────────────────────────────────────────────────────
  // Every write refreshes status on exit, so the badges can never drift from
  // what is actually on disk.
  component CliProcess: Process {
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  function finish(label, code, out, err) {
    root.busyLabel = ""
    var text = (String(out || "") + "\n" + String(err || "")).replace(/\x1b\[[0-9;]*m/g, "").replace(/\n{3,}/g, "\n\n").trim()
    if (code !== 0) text = label + " failed (exit " + code + ")\n" + text
    root.lastOutput = text.length > 1400 ? "…" + text.slice(-1400) : text
    root.refresh()
    // Anything that writes to the machine leaves a new .bak behind it, so the
    // list of them is stale the moment any of these finishes. It is one cheap
    // call and it is the difference between an "If a restore went wrong"
    // section that is about the restore you just did and one that is not.
    root.loadBackups()
  }

  CliProcess { id: saveProc;     onExited: function(c){ root.finish("Save", c, saveProc.stdout.text, saveProc.stderr.text) } }
  CliProcess { id: pullProc;     onExited: function(c){ root.finish("Pull", c, pullProc.stdout.text, pullProc.stderr.text) } }
  CliProcess { id: backupProc;   onExited: function(c){ root.finish("Copy", c, backupProc.stdout.text, backupProc.stderr.text) } }
  CliProcess { id: setProc;      onExited: function(c){ root.finish("Set", c, setProc.stdout.text, setProc.stderr.text) } }
  CliProcess { id: fileSaveProc; onExited: function(c){ root.finish("Save file", c, fileSaveProc.stdout.text, fileSaveProc.stderr.text) } }
  CliProcess { id: dangerProc;   onExited: function(c){ root.finish("Restore", c, dangerProc.stdout.text, dangerProc.stderr.text) } }
  CliProcess { id: undoProc;     onExited: function(c){ root.finish("Undo", c, undoProc.stdout.text, undoProc.stderr.text) } }
  CliProcess { id: doctorProc;   onExited: function(c){ root.busyLabel = ""; root.lastOutput = (doctorProc.stdout.text + "\n" + doctorProc.stderr.text).replace(/\x1b\[[0-9;]*m/g, "").trim() } }
  Process {
    id: editProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // "replicant:waited" is printed only when the CLI genuinely held until
        // the editor closed. Anything else means it detached and there is no
        // moment to come back at.
        if (String(text).indexOf("replicant:waited") !== -1) root.open()
      }
    }
  }

  // Tracking changes the list the rows come from, so the suggestions have to be
  // re-read alongside the status — otherwise a file you just tracked stays in
  // the "not tracked yet" list until the panel is reopened.
  CliProcess {
    id: trackProc
    onExited: function(c){ root.finish("Track", c, trackProc.stdout.text, trackProc.stderr.text); root.loadSuggestions() }
  }

  Process {
    id: backupsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.backups = JSON.parse(text || "[]") } catch (e) { root.backups = [] }
        root.backupsLoaded = true
      }
    }
  }

  Process {
    id: suggestProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.suggestions = JSON.parse(text || "[]") } catch (e) { root.suggestions = [] }
        root.suggestLoaded = true
      }
    }
  }

  Process {
    id: shortcutsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.shortcuts = JSON.parse(text || "{}"); root.shortcutsLoaded = true } catch (e) { root.shortcutsLoaded = false }
      }
    }
  }

  Process {
    id: diffProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.diffText = text && text.trim() !== "" ? text : "No differences."
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text && text.trim() !== "") root.diffText = text }
  }

  Process {
    id: logProc
    command: [root.cli, "log", "--json", "-n", "6"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.recent = JSON.parse(text || "[]") } catch (e) { root.recent = [] } }
    }
  }

  // Terminal-backed flows: these two genuinely need a terminal, because they
  // prompt for a GitHub login / a repo URL. Everything else runs headless.
  function run(cmd) { if (bar) bar.run(cmd) }
  function runVisible(cmd) { root.run("omarchy-launch-floating-terminal-with-presentation " + root.shellQuote(cmd)) }
  function doCreate() { root.runVisible(root.cli + " create --push"); root.close() }
  function doClone()  { root.runVisible(root.cli + " clone"); root.close() }

  // ── panel plumbing ────────────────────────────────────────────────────────
  implicitWidth: hostButton.implicitWidth
  implicitHeight: hostButton.implicitHeight
  Item { id: hostButton; implicitWidth: 0; implicitHeight: 0 }

  property var bar
  property var anchorItem
  property var hostWidget
  property bool opened: false
  function open() {
    root.opened = true; root.refresh()
    if (!root.shortcutsLoaded) root.loadShortcuts()
    if (!root.suggestLoaded) root.loadSuggestions()
    root.loadBackups()
  }
  function close() { root.opened = false; root.diffOpen = false; confirmDialog.opened = false }
  function toggle() { root.opened ? root.close() : root.open() }
  // Open straight onto one tab. The keys 1-4 already do this for someone
  // looking at the panel; this is the same jump for a keybinding or a script,
  // and it is what makes the panel checkable without synthesising a keystroke.
  function showTab(name) {
    if (["overview", "configs", "settings", "restore"].indexOf(name) < 0) return false
    if (!root.opened) root.open()
    root.activeTab = name
    return true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(
      header.implicitHeight + Style.space(10) + body.implicitHeight
        + (footer.visible ? footer.implicitHeight + Style.space(10) : 0),
      Style.space(880))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onCloseRequested: {
        if (root.diffOpen) root.diffOpen = false
        else if (confirmDialog.opened) confirmDialog.opened = false
        else root.close()
      }
      onTextKey: function(t) {
        if (root.diffOpen || confirmDialog.opened) return
        if (t === "1") root.activeTab = "overview"
        else if (t === "2") root.activeTab = "configs"
        else if (t === "3") root.activeTab = "settings"
        else if (t === "4") root.activeTab = "restore"
        else if (t === "r") root.refresh()
        else if (t === "s" && root.ready && !root.busy) root.doSavegame()
        // The other half of the same journey, and since 0.7.2 the panel has a
        // state whose answer is Pull rather than Save.
        else if (t === "p" && root.ready && !root.busy) root.doPull()
        else if (t === "c") root.closeAllCards()
        // Straight to "what else could I be backing up?". The card lives at the
        // bottom of a long list on purpose — it must not compete with the areas —
        // which makes it the one thing in the panel that is a scroll away.
        else if (t === "a") {
          root.activeTab = "configs"
          if (!root.isOpen("__suggest")) root.toggleCard("__suggest")
        }
        // "/" filters where you already are. It used to always jump to Configs,
        // which was right when that was the only list with a filter.
        else if (t === "/") {
          if (root.activeTab === "settings") settingSearchField.forceActiveFocus()
          else { root.activeTab = "configs"; searchField.forceActiveFocus() }
        }
      }

      // ─────────────────────────────── header (fixed) ────────────────────────
      Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        PanelHero {
          width: parent.width
          title: root.repoState.remote_name ? root.repoState.remote_name : "Omarchy Replicant"
          meta: root.ready
                ? (root.summary + "  ·  " + (root.repoState.machine || ""))
                : root.summary
          foreground: root.fg
          fontFamily: root.ff
          iconComponent: Component {
            Text { text: root.icReplicant; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.display }
          }
          trailingControl: Component {
            Button {
              iconText: root.icRefresh
              iconSpinning: root.busy
              bordered: false
              foreground: root.busy ? Color.accent : root.dim
              fontFamily: root.ff
              tooltipText: root.busy ? root.busyLabel : "Re-check this machine against the repo  (r)"
              onClicked: root.refresh()
            }
          }
        }

        // One actionable sentence, and only when there is something to act on.
        // A banner that is always present stops being read.
        BorderSurface {
          width: parent.width
          visible: root.advice !== ""
          implicitHeight: Style.space(30)
          radius: Style.cornerRadius
          color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
          borderSpec: Border.controlSpec("focus", root.fg, Color.accent)
          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            verticalAlignment: Text.AlignVCenter
            text: root.advice
            color: Color.accent
            font.family: root.ff
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        ButtonGroup {
          width: parent.width
          visible: root.ready
          options: root.tabs
          value: root.activeTab
          foreground: root.fg
          accent: Color.accent
          fontFamily: root.ff
          focusable: false
          onChanged: function(v) { root.activeTab = v }
        }

        PanelSeparator { width: parent.width }
      }

      // ─────────────────────────────── body (scrolls) ────────────────────────
      Flickable {
        id: body
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.visible ? footer.top : parent.bottom
        anchors.bottomMargin: footer.visible ? Style.space(10) : 0
        implicitHeight: content.implicitHeight
        contentHeight: content.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: body.width
          spacing: Style.space(10)

          // ══════════════ first run ══════════════
          Text {
            width: parent.width
            visible: !root.asked
            text: "Checking this machine…"
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            // Only once we have genuinely heard "not initialized" back — not
            // merely because that is the property's default before the first
            // response arrives.
            visible: root.asked && !root.ready

            Text {
              width: parent.width
              text: "No backup repo yet"
              color: root.fg; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
            }
            Text {
              width: parent.width
              text: "Replicant keeps your configs, secrets and package inventory in a private GitHub repo of your own. Create one now, or clone the one you already made on another machine."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Create private repo"; iconText: root.icPlus; bordered: true
                foreground: root.fg; accent: Color.accent; fontFamily: root.ff
                tooltipText: "Creates <hostname>-replicant on your GitHub account, private, and pushes this machine into it"
                onClicked: root.doCreate()
              }
              Button {
                text: "Clone existing…"; iconText: root.icBranch; bordered: true
                foreground: root.fg; fontFamily: root.ff
                tooltipText: "Point this machine at a repo you already have"
                onClicked: root.doClone()
              }
            }
          }

          // ══════════════ Overview ══════════════
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.ready && root.activeTab === "overview"

            Row {
              width: parent.width
              spacing: Style.space(8)
              // Five only when the fifth has something to say. A card that reads
              // 0 every day of the year is a card nobody looks at any more.
              StatCard { columns: root.statColumns; label: "tracked";  value: String((root.repoState.configs || []).length) }
              StatCard { columns: root.statColumns; label: "unsaved";  value: String(root.nDirty); highlight: root.nDirty > 0 }
              StatCard { columns: root.statColumns; label: "to restore"; value: String(root.nIncoming)
                         highlight: root.nIncoming > 0; highlightColor: root.warnColor
                         visible: root.nIncoming > 0 }
              StatCard { columns: root.statColumns; label: "to pull";  value: String(root.nBehind);      highlight: root.nBehind > 0 }
              StatCard { columns: root.statColumns; label: "not synced"; value: String(root.countOff) }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Button {
                text: "Save to GitHub"; iconText: root.icPush; bordered: true
                foreground: root.fg; accent: Color.accent; fontFamily: root.ff
                iconSpinning: saveProc.running
                enabled: root.ready && !root.busy
                tooltipText: "Copy this machine into the repo, commit and push  (s)"
                onClicked: root.doSavegame()
              }
              Button {
                text: "Pull"; iconText: root.icPull; bordered: root.nBehind > 0
                foreground: root.nBehind > 0 ? Color.accent : root.fg; accent: Color.accent; fontFamily: root.ff
                iconSpinning: pullProc.running
                enabled: root.ready && !root.busy
                tooltipText: "Bring down what another machine saved  (p)"
                onClicked: root.doPull()
              }
              Button {
                text: "Copy only"; iconText: root.icCopy; bordered: false
                foreground: root.fg; fontFamily: root.ff
                enabled: !root.busy
                tooltipText: "Refresh the local copy without committing or pushing"
                onClicked: root.doBackup()
              }
            }

            // The facts you would otherwise go and look up, in the units a
            // person thinks in: "10 min", not "600".
            BorderSurface {
              width: parent.width
              implicitHeight: factsCol.implicitHeight + Style.spacing.controlPaddingY * 2
              radius: Style.cornerRadius
              color: Style.controlFill(false, false, root.fg, Color.accent)
              borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
              Column {
                id: factsCol
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: Style.spacing.controlPaddingY
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.space(3)
                FactRow { label: "Remote";      value: root.repoState.remote_name || "—" }
                FactRow { label: "Branch";      value: (root.repoState.branch || "main") + (root.nAhead || root.nBehind ? "   ↑" + root.nAhead + " ↓" + root.nBehind : "") }
                FactRow { label: "This machine"; value: root.repoState.machine || "—" }
                // No "Last save" row here. It printed the date and subject of the
                // newest commit — which is, verbatim, the first line of the
                // Recent saves list three rows further down the same screen,
                // where it has a column for the date and room for the subject
                // instead of eliding it.
                FactRow { label: "Theme";       value: root.settingText("theme.current") }
                FactRow { label: "Bar position"; value: root.settingText("bar.position") }
                FactRow { label: "Lock screen"; value: root.settingText("idle.lock") }
                FactRow { label: "Profile";     value: root.profileName + "  ·  " + root.plural(root.scopedCount, "file") + " kept per profile" }
                FactRow { label: "Plugin";      value: "omarchy-replicant " + (root.repoState.plugin_version || "?") }
              }
            }

            // Shown from the first machine onward, because the profile it is in
            // decides what it saves — that matters before the second one exists,
            // not after.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.ready
              PanelSectionHeader { width: parent.width; text: "Machines & profiles"; foreground: root.fg; fontFamily: root.ff }
              Repeater {
                model: root.repoState.machines || []
                delegate: Item {
                  id: machineRow
                  required property var modelData
                  width: content.width
                  implicitHeight: Style.space(20)
                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)
                    Text {
                      text: root.icMachine
                      color: machineRow.modelData.current ? Color.accent : root.dim
                      font.family: root.ff; font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: machineRow.modelData.name + (machineRow.modelData.current ? "  (this one)" : "")
                      color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
                    }
                    Text {
                      // A machine with no explicit assignment guessed from its
                      // own chassis; say so rather than showing an empty column.
                      // The word "profile" is not decoration: without it the row
                      // read "omarchy (this one) laptop", which looks like two
                      // machines on a line whose whole subject is one.
                      text: machineRow.modelData.profile
                          ? "profile " + machineRow.modelData.profile
                          : (machineRow.modelData.current ? "profile " + root.profileName + " (guessed)" : "no profile")
                      color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: machineRow.modelData.last_save ? "last saved " + machineRow.modelData.last_save : "no saves yet"
                      color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            PanelSeparator { width: parent.width }
            PanelSectionHeader { width: parent.width; text: "Recent saves"; foreground: root.fg; fontFamily: root.ff }
            Text {
              width: parent.width
              visible: root.recent.length === 0
              text: "Nothing saved yet."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            }
            Column {
              width: parent.width
              spacing: Style.space(2)
              Repeater {
                model: root.recent
                delegate: Item {
                  id: recentRow
                  required property var modelData
                  width: content.width
                  implicitHeight: Style.space(20)
                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)
                    Text {
                      width: Style.space(92)
                      text: recentRow.modelData.date
                      color: root.dim; font.family: root.mono; font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: parent.width - Style.space(102)
                      // A run of identical saves is collapsed by core_log; the
                      // count is what says the four inventory commits are still
                      // accounted for and not quietly dropped.
                      text: recentRow.modelData.subject
                          + ((recentRow.modelData.count || 1) > 1 ? "   ×" + recentRow.modelData.count : "")
                      color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }

            PanelSeparator { width: parent.width }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Health check"; iconText: root.icShield; bordered: false
                foreground: root.fg; fontFamily: root.ff
                enabled: !doctorProc.running
                tooltipText: "Verify login, that the repo is private, hooks and permissions"
                onClicked: root.doDoctor()
              }
              Button {
                text: "Open repo folder"; iconText: root.icFolder; bordered: false
                foreground: root.fg; fontFamily: root.ff
                tooltipText: root.repoState.repo_dir || ""
                onClicked: { root.run("xdg-open " + root.shellQuote(root.repoState.repo_dir || "")); root.close() }
              }
            }
          }

          // ══════════════ Configs ══════════════
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.ready && root.activeTab === "configs"

            Row {
              width: parent.width
              spacing: Style.space(8)
              TextField {
                id: searchField
                width: parent.width - collapseBtn.width - Style.space(8)
                placeholderText: "Filter by name or path…   (/)"
                foreground: root.fg
                accent: Color.accent
                font.family: root.ff
                onTextChanged: root.fileSearch = text
                Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
              }
              Button {
                id: collapseBtn
                text: "Collapse all"; bordered: false
                foreground: root.dim; fontFamily: root.ff
                tooltipText: "Close every open area  (c)"
                onClicked: root.closeAllCards()
              }
            }

            // One line, not three paragraphs. This tab used to open with six
            // lines of grey text before a single file appeared — an
            // introduction, a badge legend and a scope legend — and every one
            // of them is read once and then skipped forever. The badge is the
            // only thing here with no other explanation; the scope button
            // states its own label and carries a tooltip spelling out all
            // three, so its legend was saying a second time what the control
            // already says.
            Text {
              width: parent.width
              text: "● unsaved    ↓ to restore    ↑ to push    ◆ saved    ○ default    ⊘ off    · not here"
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.categoryCards.length === 0
              text: "Nothing matches that filter."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.categoryCards
              delegate: CategoryCard {
                required property var modelData
                card: modelData
                width: content.width
              }
            }

            // The list above is what the plugin ships with plus what you have
            // already added. This is how you add more — the one card that is
            // about files NOT tracked yet, kept last so it never competes with
            // the areas, and collapsed so it is an offer rather than a chore.
            SuggestCard { width: content.width }
          }

          // ══════════════ Settings ══════════════
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.ready && root.activeTab === "settings"

            Text {
              width: parent.width
              // Three sentences became one. What the two revert buttons do is
              // already on their own tooltips, where somebody wondering about
              // a button actually looks.
              text: "Changing a value writes it to the real config file, applies it, and commits it."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              TextField {
                id: settingSearchField
                width: parent.width - settingsCollapseBtn.width - Style.space(8)
                placeholderText: "Filter settings…   (/)"
                foreground: root.fg
                accent: Color.accent
                font.family: root.ff
                onTextChanged: root.settingSearch = text
                Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
              }
              Button {
                id: settingsCollapseBtn
                text: "Collapse all"; bordered: false
                foreground: root.dim; fontFamily: root.ff
                tooltipText: "Close every open group  (c)"
                onClicked: root.closeAllCards()
              }
            }

            Repeater {
              model: root.settingGroups
              delegate: SettingCard {
                required property var modelData
                group: modelData
                width: content.width
              }
            }

            Text {
              width: parent.width
              visible: root.settingGroups.length === 0
              text: "Nothing matches that filter."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            }
          }

          // ══════════════ Restore ══════════════
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.ready && root.activeTab === "restore"

            Text {
              width: parent.width
              text: "Two different ways back"
              color: root.fg; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
            }
            Text {
              width: parent.width
              text: "Both preview first, and both keep a .bak.<epoch> copy of every file they overwrite."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }

            RestoreCard {
              width: parent.width
              title: "Restore from GitHub"
              body: "Brings every config, secret and setting saved in your repo down onto this machine — and then runs whatever Omarchy needs to make it take effect: the theme is re-applied with omarchy theme set, Hyprland is reloaded, missing plugins are reinstalled with omarchy plugin add."
              actionText: "Restore everything"
              actionAccent: true
              onPreview: {
                root.busyLabel = "Previewing…"
                root.lastOutput = "Working out what would change…"
                dangerProc.command = [root.cli, "restore", "--dry-run"]
                dangerProc.running = true
              }
              onAct: root.ask("restore-all", "",
                "Restore EVERYTHING from your GitHub repo onto this machine?\n\nEvery file it overwrites is backed up as .bak.<epoch> first.",
                "Restore")
            }

            RestoreCard {
              width: parent.width
              title: "Reset to Omarchy defaults"
              body: "Throws away your changes to every file Omarchy ships a default for and puts the factory version back, through omarchy refresh config. Your repo is not touched, so you can restore from it afterwards."
              actionText: "Reset to factory"
              actionAccent: false
              onPreview: {
                root.busyLabel = "Previewing…"
                root.lastOutput = "Working out what would be reset…"
                dangerProc.command = [root.cli, "reset-all", "--dry-run"]
                dangerProc.running = true
              }
              onAct: root.ask("reset-all", "",
                "Reset every customised file back to the Omarchy default?\n\nYour repo keeps its copy, and each file is backed up as .bak.<epoch> first.",
                "Reset")
            }

            PanelSeparator { width: parent.width }
            PanelSectionHeader { width: parent.width; text: "Or just one area"; foreground: root.fg; fontFamily: root.ff }
            Text {
              width: parent.width
              text: "Restores one area from your repo and applies it the way Omarchy expects."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.categoryCards
              delegate: Item {
                id: areaRow
                required property var modelData
                width: content.width
                implicitHeight: Style.space(30)
                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(18)
                    text: areaRow.modelData.icon
                    color: root.dim; font.family: root.ff; font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(18) - areaBtn.width - areaPreview.width - parent.spacing * 3
                    text: areaRow.modelData.label + "   " + root.plural(areaRow.modelData.count, "file")
                    color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  // Both whole-machine cards above offer Preview before they
                  // offer the button that writes. These rows write to the same
                  // files with the same force and offered only the button —
                  // "look first" was available for the biggest action in the
                  // panel and not for the ones anybody actually presses.
                  Button {
                    id: areaPreview
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Preview"; iconText: root.icDiff; bordered: false
                    foreground: root.dim; fontFamily: root.ff
                    enabled: !root.busy
                    tooltipText: "Show what restoring " + areaRow.modelData.label + " would change — writes nothing"
                    onClicked: {
                      root.busyLabel = "Previewing…"
                      root.lastOutput = "Working out what would change in " + areaRow.modelData.label + "…"
                      dangerProc.command = [root.cli, "restore", "--dry-run", "--only", areaRow.modelData.id]
                      dangerProc.running = true
                    }
                  }
                  Button {
                    id: areaBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Restore"; iconText: root.icFromRepo; bordered: false
                    foreground: root.fg; fontFamily: root.ff
                    enabled: !root.busy
                    tooltipText: areaRow.modelData.method
                    onClicked: root.ask("restore-cat", areaRow.modelData.id,
                      "Restore " + areaRow.modelData.label + " from your repo?\n\n" + areaRow.modelData.method + "\n\nEvery file it overwrites is backed up as .bak.<epoch> first.",
                      "Restore")
                  }
                }
              }
            }

            // ── the safety net ────────────────────────────────────────────
            // Everything above this line promises "a .bak.<epoch> is kept".
            // Until 0.7.3 that promise had no way of being collected on: the
            // only code that could find a .bak was purge, which removes the
            // plugin. This is the bottom of the Restore tab because that is
            // where somebody is standing when they need it.
            PanelSeparator { width: parent.width; visible: root.backupRows.length > 0 }
            PanelSectionHeader {
              width: parent.width
              text: "If a restore went wrong"
              foreground: root.fg; fontFamily: root.ff
              visible: root.backupRows.length > 0
            }
            Text {
              width: parent.width
              visible: root.backupRows.length > 0
              text: "Every write kept the version it replaced. Undo swaps the newest one back — and keeps what it replaces, so this is reversible too."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.backupRows
              delegate: Item {
                id: bakRow
                required property var modelData
                width: content.width
                implicitHeight: Style.space(30)
                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - undoBtn.width - parent.spacing
                    // The id, when it was made, and whether it is any different
                    // from what is there now. "same" is the one you can drop
                    // without thinking; it is also the one that would make Undo
                    // do nothing, which is worth saying before it is pressed.
                    text: bakRow.modelData.id + "   " + root.agoText(bakRow.modelData.epoch)
                        + (bakRow.modelData.state === "same" ? "   ·  identical to the file you have"
                          : bakRow.modelData.state === "gone" ? "   ·  the file itself is gone" : "")
                        + (bakRow.modelData.older > 0 ? "   ·  +" + bakRow.modelData.older + " older" : "")
                    color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Button {
                    id: undoBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Undo"; iconText: root.icDefault; bordered: false
                    foreground: bakRow.modelData.state === "same" ? root.dim : root.fg
                    fontFamily: root.ff
                    enabled: !root.busy && bakRow.modelData.state !== "same"
                    tooltipText: bakRow.modelData.state === "same"
                      ? "This backup is identical to the file you have — undoing it would change nothing"
                      : "Put this version back, and keep the current one as the new .bak"
                    onClicked: root.ask("undo", bakRow.modelData.id,
                      "Put back the version of " + bakRow.modelData.id + " from "
                        + root.agoText(bakRow.modelData.epoch) + "?\n\nThe version you have now becomes the new .bak.<epoch>, so this can be undone again.",
                      "Undo")
                  }
                }
              }
            }
            Row {
              width: parent.width
              visible: root.backupRows.length > 0
              spacing: Style.space(8)
              Button {
                text: "Remove all backups"; iconText: root.icUntrack; bordered: false
                foreground: root.dim; fontFamily: root.ff
                enabled: !root.busy
                tooltipText: "Delete every .bak.<epoch> beside your configs. Your repo is not touched."
                onClicked: root.ask("prune-backups", "",
                  "Delete every .bak.<epoch> next to your configs?\n\nThis is the only copy of what those files looked like before each restore. Your repo is not touched.",
                  "Remove")
              }
            }
          }
        }
      }

      // ─────────────────────────────── footer (fixed) ────────────────────────
      Column {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(4)
        visible: root.lastOutput !== ""

        PanelSeparator { width: parent.width }
        Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: parent.width - clearBtn.width - Style.space(6)
            text: root.lastOutput
            color: root.dim
            font.family: root.mono
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            maximumLineCount: 6
            elide: Text.ElideRight
          }
          Button {
            id: clearBtn
            iconText: root.icClose; bordered: false; foreground: root.dim; fontFamily: root.ff
            tooltipText: "Dismiss"
            onClicked: root.lastOutput = ""
          }
        }
      }

      // ─────────────────────────────── overlays ──────────────────────────────
      Rectangle {
        anchors.fill: parent
        visible: root.diffOpen
        z: 50
        color: Color.background

        Column {
          anchors.fill: parent
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width - closeDiff.width - Style.space(8)
              text: root.diffTitle
              color: root.fg; font.family: root.ff; font.pixelSize: Style.font.title
              font.bold: true; elide: Text.ElideMiddle
            }
            Button {
              id: closeDiff
              text: "Close"; bordered: false
              foreground: root.fg; fontFamily: root.ff
              onClicked: root.diffOpen = false
            }
          }
          PanelSeparator { width: parent.width }

          Flickable {
            id: diffScroll
            width: parent.width
            height: parent.height - diffScroll.y
            contentWidth: Math.max(width, diffBody.implicitWidth)
            contentHeight: diffBody.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: diffBody
              Repeater {
                model: root.diffText.split("\n")
                delegate: Text {
                  required property string modelData
                  text: modelData === "" ? " " : modelData
                  font.family: root.mono
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  color: modelData.charAt(0) === "+" ? root.okColor
                       : modelData.charAt(0) === "-" ? Color.urgent
                       : modelData.charAt(0) === "@" ? Color.accent
                       : modelData.charAt(0) === "#" ? root.dim
                       : root.fg
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 60
        foreground: root.fg
        fontFamily: root.ff
        cancelText: "Cancel"
        onCanceled: { confirmDialog.opened = false; root.confirmAction = "" }
        onConfirmed: root.runConfirmed()
      }
    }
  }

  // ══════════════════════════ reusable pieces ══════════════════════════════

  component FactRow: Item {
    id: fact
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Style.space(18)
    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      Text {
        width: Style.space(96)
        text: fact.label
        color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
      }
      Text {
        width: parent.width - Style.space(106)
        text: fact.value
        color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component StatCard: BorderSurface {
    id: statCard
    property string label: ""
    property string value: ""
    property bool highlight: false
    // Which colour the highlight is. "to restore" is not the same kind of
    // attention as "unsaved" — one asks you to press Save and the other asks
    // you not to — so it borrows the amber the bar icon and the row badge
    // already use for it rather than sharing the accent.
    property color highlightColor: Color.accent
    // Explicit width: a Row gives its children no width, and a BorderSurface
    // with no width renders at zero — the cards were simply invisible.
    // The count is a property because the row grows a fifth card on the days
    // there is something to restore, and a hardcoded /4 left it overflowing.
    property int columns: 4
    width: (parent.width - Style.space(8 * (statCard.columns - 1))) / statCard.columns
    implicitHeight: Style.space(46)
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec(statCard.highlight ? "focus" : "normal", root.fg, statCard.highlightColor)
    Column {
      anchors.centerIn: parent
      spacing: 0
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: statCard.value
        color: statCard.highlight ? statCard.highlightColor : root.fg
        font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: statCard.label
        color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
      }
    }
  }

  // An accordion header. Fixed height on purpose: it holds a Row anchored to
  // its vertical centre, and deriving the height from that Row at the same time
  // is a parent-height <-> child-position feedback loop (Qt logs "polish()
  // loop" and the row collapses to nothing).
  component CardHeader: Item {
    id: ch
    property string icon: ""
    property string title: ""
    property string subtitle: ""
    property string statusText: ""
    property bool statusHighlight: false
    property string countText: ""
    property bool expanded: false
    signal toggled()

    implicitHeight: Style.space(46)

    MouseArea {
      id: hitbox
      anchors.fill: parent
      hoverEnabled: true
      onClicked: ch.toggled()
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(10)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        text: ch.expanded ? root.icDown : root.icRight
        color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(20)
        text: ch.icon
        color: hitbox.containsMouse || ch.expanded ? Color.accent : root.fg
        font.family: root.ff; font.pixelSize: Style.font.iconLarge
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(34) - statusCol.width - parent.spacing * 3
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: ch.title
          color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle; font.bold: true
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: ch.subtitle
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
      Column {
        id: statusCol
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(84)
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: ch.countText
          color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: ch.statusText
          color: ch.statusHighlight ? Color.accent : root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component CategoryCard: BorderSurface {
    id: cc
    property var card: ({})
    readonly property bool expanded: root.isOpen(cc.card.id)

    // Height derives from the column, so the column is anchored to the TOP and
    // never centred — centring inside a parent sized by that same child is the
    // feedback loop described on CardHeader.
    implicitHeight: ccCol.implicitHeight
    radius: Style.cornerRadius
    color: cc.card.changed > 0 ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.07)
                               : Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec(cc.expanded ? "focus" : "normal", root.fg, Color.accent)

    Column {
      id: ccCol
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 0

      CardHeader {
        width: parent.width
        icon: cc.card.icon
        title: cc.card.label
        subtitle: cc.card.description
        countText: String(cc.card.count)
        statusText: cc.card.incoming > 0 ? cc.card.incoming + " to restore"
                  : cc.card.changed > 0 ? cc.card.changed + " changed"
                  : cc.card.off > 0 ? cc.card.off + " off" : "in sync"
        statusHighlight: cc.card.changed > 0 || cc.card.incoming > 0
        expanded: cc.expanded
        onToggled: root.toggleCard(cc.card.id)
      }

      Column {
        width: parent.width
        visible: cc.expanded
        spacing: Style.space(2)

        PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }

        // Shortcuts is the one area where the files are not the point: what you
        // want to see is the keyboard. The file row is still there below.
        Column {
          width: parent.width
          visible: cc.card.id === "shortcuts"
          spacing: Style.space(2)
          ShortcutsView { width: parent.width }
        }

        Repeater {
          model: cc.expanded ? cc.card.rows : []
          delegate: FileRow {
            required property var modelData
            config: modelData
            width: ccCol.width
          }
        }

        // The selling point, said out loud where it matters: not "we copied
        // your files back" but "here is the Omarchy command that puts this
        // back properly".
        Item {
          width: parent.width
          implicitHeight: Style.space(28)
          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.space(6)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.icInfo
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(20)
              text: cc.card.method
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  // ── "what else could I be backing up?" ────────────────────────────────────
  // Auto-discovery is deliberately NOT how the manifest works: the guarantee
  // that only what a human chose gets tracked is the point of the whole tool.
  // So this proposes and the user disposes. Every row states why it is here,
  // and nothing is added until a button is pressed.
  component SuggestCard: BorderSurface {
    id: sc
    readonly property bool expanded: root.isOpen("__suggest")
    readonly property var items: root.suggestions || []

    visible: sc.items.length > 0
    implicitHeight: scCol.implicitHeight
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec(sc.expanded ? "focus" : "normal", root.fg, Color.accent)

    Column {
      id: scCol
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 0

      CardHeader {
        width: parent.width
        icon: root.icPlus
        title: "Add more files"
        subtitle: "Config on this machine that nothing is backing up yet"
        countText: String(sc.items.length)
        statusText: "not tracked"
        statusHighlight: false
        expanded: sc.expanded
        onToggled: root.toggleCard("__suggest")
      }

      Column {
        width: parent.width
        visible: sc.expanded
        spacing: Style.space(2)

        PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }

        Repeater {
          model: sc.expanded ? sc.items : []
          delegate: SuggestRow {
            required property var modelData
            item: modelData
            width: scCol.width
          }
        }
      }
    }
  }

  component SuggestRow: Item {
    id: srow
    property var item: ({})
    readonly property bool isSecret: srow.item.kind === "secret"

    // Fixed height, like every other row here: a row whose height comes from
    // its own centred content is the parent-height/child-position loop.
    implicitHeight: Style.space(50)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Column {
        width: parent.width - trackBtn.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: srow.item.pretty || ""
          color: root.fg
          font.family: root.ff; font.pixelSize: Style.font.subtitle
          elide: Text.ElideMiddle
        }
        Text {
          width: parent.width
          text: srow.item.reason || ""
          // A file that holds a credential is not a normal suggestion: tracked
          // as ordinary config it would sit world-readable in a git checkout.
          color: srow.isSecret ? Color.urgent : root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: trackBtn
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
        enabled: !root.busy
        bordered: true
        text: srow.isSecret ? "Track (600)" : "Track"
        iconText: root.icPlus
        foreground: root.fg
        fontFamily: root.ff
        tooltipText: srow.isSecret
                     ? "Add it to your list as a secret: stored at mode 600, and its contents are never rendered"
                     : "Add it to your list. It is saved with your next Save to GitHub."
        onClicked: root.doTrack(srow.item.path, srow.item.kind)
      }
    }
  }

  component ShortcutsView: Column {
    id: sv
    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Style.space(26)
      Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: Style.space(8)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - allBtn.width - Style.space(8)
          text: root.shortcutsLoaded
                ? (root.shortcuts.own_count + " of your own · " + root.shortcuts.active_count + " bound in total")
                : "reading your keybindings…"
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Button {
          id: allBtn
          anchors.verticalCenter: parent.verticalCenter
          text: root.showAllShortcuts ? "Show mine" : "Show all"
          bordered: false; foreground: root.dim; fontFamily: root.ff
          tooltipText: "Omarchy's defaults are not backed up — they come with the distro. Only your overrides are."
          onClicked: root.showAllShortcuts = !root.showAllShortcuts
        }
      }
    }

    Text {
      width: parent.width - Style.spacing.rowPaddingX * 2
      x: Style.spacing.rowPaddingX
      visible: root.shortcutsLoaded && !root.showAllShortcuts && root.shortcuts.own_count === 0
      text: "You have not overridden any binding — this machine runs Omarchy's defaults. Edit hypr/bindings.lua below to add one."
      color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.shortcutsLoaded
             ? (root.showAllShortcuts ? root.shortcuts.active : root.shortcuts.own)
             : []
      delegate: Item {
        id: keyRow
        required property var modelData
        width: sv.width
        implicitHeight: Style.space(20)
        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(6)
          anchors.rightMargin: Style.spacing.rowPaddingX
          spacing: Style.space(10)
          Text {
            width: Style.space(150)
            text: keyRow.modelData.key
            color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            width: parent.width - Style.space(160)
            text: keyRow.modelData.kind === "unbind"
                  ? "(unbound)"
                  : (keyRow.modelData.description && keyRow.modelData.description !== ""
                     ? keyRow.modelData.description
                     : (keyRow.modelData.command || ""))
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }
  }

  component SettingCard: BorderSurface {
    id: sc
    property var group: ({})
    readonly property bool expanded: root.isOpen(sc.group.id)

    implicitHeight: scCol.implicitHeight
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec(sc.expanded ? "focus" : "normal", root.fg, Color.accent)

    Column {
      id: scCol
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: 0

      CardHeader {
        width: parent.width
        icon: sc.group.icon
        title: sc.group.name
        subtitle: sc.group.description
        countText: String((sc.group.items || []).length)
        // Not "changed": one tab to the left that word counts files waiting to
        // be saved, and here it counts values that differ from what Omarchy
        // ships — two different questions under one word, two tabs apart.
        // "customised" is the answer to this one, and it pairs with the text
        // it alternates with.
        statusText: sc.group.changed > 0 ? sc.group.changed + " customised" : "as Omarchy ships"
        statusHighlight: sc.group.changed > 0
        expanded: sc.expanded
        onToggled: root.toggleCard(sc.group.id)
      }

      Column {
        width: parent.width
        visible: sc.expanded
        spacing: Style.space(2)
        PanelSeparator { width: parent.width - Style.spacing.rowPaddingX * 2; x: Style.spacing.rowPaddingX }
        Repeater {
          model: sc.expanded ? (sc.group.items || []) : []
          delegate: SettingRow {
            required property var modelData
            setting: modelData
            width: scCol.width
          }
        }
        Item { width: 1; height: Style.space(4) }
      }
    }
  }

  component RestoreCard: BorderSurface {
    id: card
    property string title: ""
    property string body: ""
    property string actionText: ""
    property bool actionAccent: false
    signal preview()
    signal act()

    implicitHeight: cardCol.implicitHeight + Style.spacing.controlPaddingY * 2
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

    Column {
      id: cardCol
      // Anchored to the top, never verticalCenter: this card's height is
      // derived from this column, and centring the column inside a parent whose
      // height depends on it is a parent-height <-> child-position feedback
      // loop (Qt logs "polish() loop" and the card collapses to nothing).
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.spacing.controlPaddingY
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: card.title
        color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle; font.bold: true
      }
      Text {
        width: parent.width
        text: card.body
        color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
      }
      Row {
        spacing: Style.space(8)
        Button {
          text: "Preview"; iconText: root.icDiff; bordered: false
          foreground: root.fg; fontFamily: root.ff
          enabled: !root.busy
          tooltipText: "Shows what would change and writes nothing"
          onClicked: card.preview()
        }
        Button {
          text: card.actionText; iconText: root.icDefault; bordered: true
          foreground: root.fg; accent: card.actionAccent ? Color.accent : Color.urgent; fontFamily: root.ff
          enabled: !root.busy
          onClicked: card.act()
        }
      }
    }
  }

  component SettingRow: Item {
    id: srow
    property var setting: ({})
    readonly property bool isNumber: setting.type === "number" || setting.type === "toml-int" || setting.type === "lua-int"
    readonly property bool isFloat:  setting.type === "toml-float"
    readonly property bool isBool:   setting.type === "bool" || setting.type === "lua-bool"
    readonly property bool isChoice: setting.type === "enum" || setting.type === "lua-enum"
                                  || setting.type === "line-enum" || setting.type === "theme"
                                  || setting.type === "ini-enum"
    readonly property bool isLongList: srow.isChoice && (setting.options || []).length > 8
    readonly property bool usable: setting.available === true && !root.busy

    // Whether the exact value is worth repeating under the label. It is there
    // because the stepper rounds — 150 seconds is edited as 3 minutes, and the
    // row must never leave you guessing which number is real — but on the rows
    // where the control already shows the value exactly, repeating it cost the
    // hint its last words: seven of eight rows ended in "…". So it is printed
    // only when the control cannot say it: a rounded number, a value with a
    // name of its own ("never" for 0), or a choice, whose dropdown elides.
    readonly property string controlText: {
      var du = String(srow.setting.display_unit || "")
      return String(srow.setting.display_value) + (du !== "" ? " " + du : "")
    }
    readonly property bool showValue: srow.isChoice
                                      // A dropdown 160 wide shows about
                                      // seventeen characters; past that it
                                      // elides and the row has to say the value
                                      // in full underneath. "top" does not.
                                      ? String(srow.setting.value_text || "").length > 17
                                    : srow.isBool ? false
                                    : String(srow.setting.value_text || "") !== srow.controlText

    // What goes under the label, composed once so the height can be decided
    // from it. See showValue for when the value is part of it.
    readonly property string subtitleText: srow.setting.available !== true
        ? "not present in this machine's config"
        : (srow.showValue ? String(srow.setting.value_text) : "")
          + (srow.setting.implicit === true
             ? (srow.showValue ? "  (inherited)" : "inherited") : "")
          + ((srow.showValue || srow.setting.implicit === true) ? "  ·  " : "")
          + String(srow.setting.hint || "")

    // Two lines when one cannot hold it. Some hints carry a consequence worth
    // reading — "setting it stops the bar scaling with the font" — and cutting
    // them to fit would have deleted the reason the control exists. A character
    // count, NOT the text's own implicitHeight: this row's children are
    // verticalCenter-anchored to it, so a height derived from them is the
    // parent-height <-> child-position loop that renders the row at nothing.
    // 44 is what fits on one line at the panel's width, measured on a capture.
    readonly property string noticeText: String(srow.setting.notice || "")
    readonly property int subtitleLines: srow.subtitleText.length > 44 ? 2 : 1
    // The notice is counted too, and it was not. A row carrying one rendered
    // four lines of text in the two-line height and the notice was cut in half
    // — "Overridden: Omarchy Sleepwalker is blocki…", losing the clause that
    // said what the consequence was. Same character count, same reason: this
    // row's children are verticalCenter-anchored to it, so a height derived
    // from their own implicitHeight is the polish() loop that renders nothing.
    readonly property int noticeLines: srow.noticeText === "" ? 0
                                     : (srow.noticeText.length > 44 ? 2 : 1)
    implicitHeight: Style.space(34 + 16 * srow.subtitleLines + 16 * srow.noticeLines)
    opacity: srow.setting.available === true ? 1.0 : 0.45

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Column {
        width: parent.width - controlSlot.width - revertRow.width - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: srow.setting.label
          color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: srow.subtitleText
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
        // Only ever present when the value genuinely cannot do what it says —
        // see the single rule in build_settings_json. Not a warning strip that
        // is always on; a row that says nothing is a row that is fine.
        Text {
          width: parent.width
          visible: srow.noticeText !== ""
          text: srow.noticeText
          color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }

      // One control per type. Every control is instantiated on every row, so
      // each binding has to stay type-safe even on rows it is not used for —
      // an enum's string value assigned to NumberField.value is a runtime error.
      Item {
        id: controlSlot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(160)
        height: Style.space(32)

        // Numbers are edited in the unit a person uses: idle timers in minutes,
        // never in seconds. The registry's `scale` does the conversion, and the
        // CLI still speaks the stored unit.
        Row {
          visible: srow.isNumber
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)
          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            enabled: srow.usable
            foreground: root.fg
            fontFamily: root.ff
            fieldWidth: Style.space(96)
            from: srow.isNumber && typeof srow.setting.display_min === "number" ? srow.setting.display_min : 0
            to: srow.isNumber && typeof srow.setting.display_max === "number" ? srow.setting.display_max : 999999
            stepSize: srow.isNumber && typeof srow.setting.display_step === "number" ? srow.setting.display_step : 1
            value: srow.isNumber && typeof srow.setting.display_value === "number" ? srow.setting.display_value : 0
            onModified: function(v) {
              if (!srow.usable) return
              var scale = typeof srow.setting.scale === "number" && srow.setting.scale > 0 ? srow.setting.scale : 1
              root.queueSetting(srow.setting.id, Math.round(v * scale))
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            text: srow.setting.display_unit || ""
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }
        }

        // Floats get a slider: a stepper over 0.5–2.0 in 0.05 steps would be
        // thirty clicks from one end to the other.
        Row {
          visible: srow.isFloat
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            text: srow.isFloat && typeof srow.setting.value === "number" ? srow.setting.value.toFixed(2) : "—"
            color: root.fg; font.family: root.mono; font.pixelSize: Style.font.caption
          }
          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(112)
            bar: root.bar
            minimum: srow.isFloat && typeof srow.setting.min === "number" ? srow.setting.min : 0
            maximum: srow.isFloat && typeof srow.setting.max === "number" ? srow.setting.max : 1
            step: 0.05
            value: srow.isFloat && typeof srow.setting.value === "number" ? srow.setting.value : 0
            onReleased: function(v) { if (srow.usable) root.queueSetting(srow.setting.id, Math.round(v * 100) / 100) }
          }
        }

        ToggleSwitch {
          visible: srow.isBool
          enabled: srow.usable
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: srow.setting.value === true || srow.setting.value === "true"
          foreground: root.fg
          accent: Color.accent
          onToggled: if (srow.usable) root.doSetSetting(srow.setting.id,
                        (srow.setting.value === true || srow.setting.value === "true") ? "false" : "true")
        }

        Dropdown {
          visible: srow.isChoice && !srow.isLongList
          enabled: srow.usable
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          showLabel: false
          value: srow.isChoice && typeof srow.setting.value === "string" ? srow.setting.value : ""
          options: srow.isChoice ? (srow.setting.options || []) : []
          fontFamily: root.ff
          onChanged: function(v) { if (srow.usable && v !== srow.setting.value) root.doSetSetting(srow.setting.id, v) }
        }

        // ~30 themes; a plain dropdown makes you hunt for the one you want.
        SearchableDropdown {
          visible: srow.isChoice && srow.isLongList
          enabled: srow.usable
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          showLabel: false
          placeholderText: "Search…"
          value: srow.isChoice && typeof srow.setting.value === "string" ? srow.setting.value : ""
          options: srow.isChoice ? (srow.setting.options || []) : []
          fontFamily: root.ff
          onChanged: function(v) { if (srow.usable && v !== srow.setting.value) root.doSetSetting(srow.setting.id, v) }
        }
      }

      // Two ways back for one value, without touching the rest of the file it
      // lives in. Shown only when they would actually change something.
      Row {
        id: revertRow
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Button {
          iconText: root.icDefault; bordered: false; foreground: root.dim; fontFamily: root.ff
          enabled: srow.setting.can_revert_default === true && !root.busy
          opacity: srow.setting.can_revert_default === true ? 1.0 : 0.25
          tooltipText: srow.setting.can_revert_default === true
                       ? "Back to Omarchy's default: " + srow.setting.default_text
                       : "Already the Omarchy default"
          onClicked: root.doRevert(srow.setting.id, "default")
        }
        Button {
          iconText: root.icFromRepo; bordered: false; foreground: root.dim; fontFamily: root.ff
          enabled: srow.setting.can_revert_repo === true && !root.busy
          opacity: srow.setting.can_revert_repo === true ? 1.0 : 0.25
          tooltipText: srow.setting.can_revert_repo === true
                       ? "Back to what your repo has: " + srow.setting.repo_text
                       : "Already matches your repo"
          onClicked: root.doRevert(srow.setting.id, "repo")
        }
      }
    }
  }

  component FileRow: Item {
    id: frow
    property var config: ({})
    readonly property string syncState: frow.config.sync_state || "saved"
    readonly property bool isDefault: frow.syncState === "default"
    // "Needs the Save button" — unsaved, or committed here but never pushed.
    // Deliberately NOT incoming: that row's difference belongs to another
    // machine, and the button it wants is the one next to this one.
    readonly property bool isModified: frow.syncState === "unsaved" || frow.syncState === "unpushed"
    readonly property bool isIncoming: frow.syncState === "incoming"
    // Anything with a button worth pressing reads bold, whichever button it is.
    readonly property bool needsAction: frow.isModified || frow.isIncoming
    readonly property string scope: frow.config.scope || "shared"
    readonly property bool isOff: frow.config.synced === false
    readonly property bool missing: frow.config.exists === false
    readonly property bool isSecret: frow.config.secret === true
    // "saved" and "default" are the states you do not have to act on, and the
    // one-line legend above the list is enough for them.
    readonly property bool needsWords: frow.syncState === "unsaved"
                                    || frow.syncState === "incoming"
                                    || frow.syncState === "unpushed"
                                    || frow.syncState === "off"
                                    || frow.syncState === "missing"

    implicitHeight: Style.space(50)

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        text: root.stateGlyph(frow.syncState)
        color: root.stateColor(frow.syncState)
        font.family: root.ff; font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        width: parent.width - Style.space(14) - syncSwitch.width - actions.width - parent.spacing * 3
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: frow.config.label
          color: frow.missing || frow.isOff ? root.dim : root.fg
          font.family: root.ff; font.pixelSize: Style.font.subtitle; font.bold: frow.needsAction
          elide: Text.ElideMiddle
        }
        // Two texts, not one string. Appended to the end of the path the state
        // words were the first thing elided — on exactly the rows whose whole
        // point is that something needs doing, they were the half that got cut.
        // (The same bug was already fixed for a directory's file count by
        // moving it in front; this is that fix applied to the other half.)
        // So the words come first and are never elided; the path takes whatever
        // room is left, and it is the part that can afford to lose its head —
        // the title right above it is the same path without ~/.config/.
        Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            id: stateWords
            // A row that needs attention says so in words instead of relying on
            // the reader having learnt the badge. Only those rows: the forty
            // that are simply saved would be forty repetitions of "saved on
            // GitHub", which is how a legend becomes wallpaper.
            visible: frow.needsWords
            text: root.stateWord(frow.syncState)
            color: root.stateColor(frow.syncState)
            font.family: root.ff; font.pixelSize: Style.font.caption
          }
          Text {
            width: parent.width - (stateWords.visible ? stateWords.width + parent.spacing : 0)
            // Secrets describe themselves by what they ARE, never by what they
            // contain: a kind, a mode, and for env files the names of the
            // variables. No value ever reaches the screen.
            // The count goes FIRST for a directory — behind the path it was the
            // first thing elided, on the one row whose whole point is the count.
            text: frow.config.is_dir === true
                ? (frow.config.nfiles + " files"
                   + (root.whereText(frow.config) !== "" ? "  ·  " + root.whereText(frow.config) : ""))
              : frow.isSecret
                ? (frow.config.kind + "  ·  mode " + (frow.config.mode || "?")
                   + (frow.config.var_count > 0 ? "  ·  " + frow.config.var_count + " variables" : ""))
                : root.whereText(frow.config)
            color: frow.isSecret && frow.config.kind === "private key" && frow.config.mode !== "600" ? Color.urgent : root.dim
            font.family: root.ff; font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // The per-file scope control. Some files are about the machine, not about
      // the user — hypr/monitors.lua describes the screens physically plugged
      // into THIS box — and copying them between a desktop and a laptop is
      // actively wrong. Rather than the old on/off switch, which forced you to
      // choose between "wrong on one machine" and "no backup at all", this
      // cycles the three answers: shared, per profile, or off.
      Button {
        id: syncSwitch
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(96)
        enabled: !root.busy
        bordered: true
        text: root.scopeLabel(frow.scope)
        iconText: root.scopeIcon(frow.scope)
        foreground: frow.scope === "off" ? root.dim
                  : frow.scope === "profile" ? Color.accent : root.fg
        fontFamily: root.ff
        tooltipText: root.scopeHint(frow.scope, !frow.isSecret)
        onClicked: root.doScope(frow.config.id, root.nextScope(frow.scope, !frow.isSecret))
      }

      Row {
        id: actions
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Button {
          iconText: root.icEdit; bordered: false; foreground: root.fg; fontFamily: root.ff
          enabled: !frow.missing
          tooltipText: "Open in your editor"
          onClicked: root.doEdit(frow.config.id)
        }
        Button {
          iconText: root.icDiff; bordered: false; foreground: root.fg; fontFamily: root.ff
          enabled: !frow.missing
          tooltipText: frow.isSecret ? "Say whether it changed (contents are never shown)" : "Show what changed"
          onClicked: root.doDiff(frow.config.id)
        }
        Button {
          iconText: root.icSave; bordered: false
          foreground: frow.isModified ? Color.accent : root.dim; fontFamily: root.ff
          enabled: !frow.missing && frow.isModified && !root.busy
          tooltipText: frow.isModified ? "Commit and push just this file"
                     : frow.isIncoming ? "Your repo has a newer copy from another machine — restore it instead"
                     : "Already saved"
          onClicked: root.doSaveFile(frow.config.id)
        }
        Button {
          iconText: root.icFromRepo; bordered: false
          foreground: frow.isIncoming ? root.warnColor : root.dim; fontFamily: root.ff
          enabled: !root.busy && frow.syncState !== "off"
          tooltipText: frow.isIncoming ? "Bring down the newer copy another machine saved (keeps a .bak copy)"
                                       : "Put back the copy saved in your repo (keeps a .bak copy)"
          onClicked: root.ask("restore-file", frow.config.id,
                              "Replace " + frow.config.label + " with the copy saved in your repo?\n\nYour current version is kept as .bak.<epoch>.",
                              "Restore")
        }
        Button {
          iconText: root.icDefault; bordered: false; foreground: root.dim; fontFamily: root.ff
          // Only offered where there is a factory version to go back to.
          enabled: !frow.missing && frow.config.has_default === true && !frow.isDefault && !root.busy
          opacity: frow.config.has_default === true ? 1.0 : 0.25
          tooltipText: frow.config.has_default === true
                       ? "Put Omarchy's default back (keeps a .bak copy)"
                       : "Omarchy ships no default for this file"
          onClicked: root.ask("reset-file", frow.config.id,
                              "Replace " + frow.config.label + " with Omarchy's default?\n\nYour current version is kept as .bak.<epoch>.",
                              "Reset")
        }
        // Only on rows that came from the user's own list. A file the plugin
        // ships with is switched OFF instead, which keeps both the row and the
        // copy in the repo — untracking a shipped entry would make a file the
        // next version tracks again vanish from the panel with no way back.
        Button {
          visible: frow.config.source === "user"
          iconText: root.icUntrack; bordered: false; foreground: root.dim; fontFamily: root.ff
          enabled: !root.busy
          tooltipText: "Stop tracking this — it leaves your list and the copy in the repo goes with it"
          onClicked: root.ask("untrack", frow.config.id,
                              "Stop tracking " + frow.config.label + "?\n\nThe file on this machine is untouched. The copy in your repo is removed, and git keeps its history.",
                              "Untrack")
        }
      }
    }
  }
}
