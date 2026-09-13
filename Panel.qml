import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"
import "replicant.js" as R

// The Replicant panel: four tabs over one CLI. Its parts are in components/,
// one file each, and each one reaches the panel through its `panel` property.
// The pure logic is in replicant.js, where tests/qml tests it.
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
  // The IPC target that opens this panel from a key (`omarchy shell replicant
  // toggle`) is in BarWidget.qml, which loads the panel. The base Panel can
  // make a target of its own, and two targets that opened the same panel were
  // two names for one thing.
  manageIpc: false

  // The CLI inside this plugin, resolved relative to this file and never looked
  // up on PATH. Service.qml says why.
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
                            || checkProc.running
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
  // looked at before being used. R.mdi (replicant.js) builds the string.

  // Paths are shown the way the CLI shows them. A row is about 40 characters
  // wide once the scope button and five actions have taken their share, and
  // "/home/<user>" is a third of that spent saying nothing.
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
  readonly property string icRefresh: R.mdi(0xF0450)    // refresh
  readonly property string icPush: R.mdi(0xF0167)    // cloud-upload
  readonly property string icPull: R.mdi(0xF0162)    // cloud-download
  readonly property string icCopy: R.mdi(0xF018F)    // content-copy
  readonly property string icEdit: R.mdi(0xF03EB)    // pencil
  readonly property string icDiff: R.mdi(0xF08AA)    // file-compare
  readonly property string icSave: R.mdi(0xF0193)    // content-save
  readonly property string icDefault: R.mdi(0xF099B)    // restore
  readonly property string icFromRepo: R.mdi(0xF01DA)    // download
  readonly property string icShield: R.mdi(0xF0498)    // shield
  readonly property string icFolder: R.mdi(0xF024B)    // folder
  readonly property string icPlus: R.mdi(0xF0415)    // plus
  readonly property string icBranch: R.mdi(0xF062C)    // source-branch
  readonly property string icClose: R.mdi(0xF0156)    // close
  readonly property string icDown: R.mdi(0xF0140)    // chevron-down
  readonly property string icRight: R.mdi(0xF0142)    // chevron-right
  readonly property string icInfo: R.mdi(0xF02FC)    // information
  readonly property string icMachine: R.mdi(0xF0176)    // laptop
  // The plugin's own mark: identical cells, more than one of them. Chosen over
  // the GitHub logo because GitHub is where the copy happens to live, not what
  // this does. The OUTLINE variant is used here and the filled one in the bar —
  // at 30px the outline reads as three distinct hexagons, at 13px it collapses
  // into rings, so the bar gets the filled one. The scope button below keeps
  // content-duplicate for "Shared", which is a different idea (one copy everyone
  // reads) and sits next to its own text label.
  readonly property string icReplicant: R.mdi(0xF10F2)   // hexagon-multiple-outline
  readonly property string icShared: R.mdi(0xF0191)      // content-duplicate
  readonly property string icProfile: R.mdi(0xF0322)     // laptop
  readonly property string icOff: R.mdi(0xF0377)         // minus-circle-outline
  // A list with a minus, NOT a waste basket. Untracking removes an entry from
  // your list and the copy from the repo; the file on the machine is untouched,
  // and a trash can on that button would say the opposite of what it does.
  readonly property string icUntrack: R.mdi(0xF0410)     // playlist-remove

  // ── derived summaries ─────────────────────────────────────────────────────
  // The glyph, the word and the colour role of each sync state are in
  // replicant.js, where tests/qml tests them. The colours are the panel's own.
  function stateColor(st) {
    var role = R.stateRole(st)
    if (role === "warn") return root.warnColor
    if (role === "accent") return Color.accent
    if (role === "ok") return root.okColor
    return root.dim
  }

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

  // What the header and the banner say. The order of the rules is in
  // replicant.js (summary, advice), where it is tested.
  readonly property var facts: ({ asked: root.asked, ready: root.ready, ahead: root.nAhead,
                                  behind: root.nBehind, incoming: root.nIncoming, dirty: root.nDirty })
  readonly property string summary: R.summary(root.facts)
  readonly property string advice: R.advice(root.facts)

  readonly property var tabs: [
    { value: "overview", label: "Overview", icon: R.mdi(0xF056E), tooltip: "This machine at a glance  (1)" },
    { value: "configs",  label: "Configs",  icon: R.mdi(0xF107F), tooltip: "Everything being backed up, by area  (2)" },
    { value: "settings", label: "Settings", icon: R.mdi(0xF0493), tooltip: "Change a value and it is written and saved  (3)" },
    { value: "restore",  label: "Restore",  icon: R.mdi(0xF099B), tooltip: "Bring a whole machine back  (4)" }
  ]

  // ── one uniform row shape for configs and secrets ─────────────────────────
  // The rows of one area, secrets included, filtered by the search and sorted
  // (replicant.js, rowsFor).
  function rowsFor(categoryId) { return R.rowsFor(root.repoState, categoryId, root.fileSearch) }

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

  // Third-party themes/plugins the inventory knows about but this machine
  // does not have. `restore` reports these, it never installs them — see
  // restore_themes/restore_plugins in the CLI. One row, one Install button,
  // so fetching someone else's current code is always a decision made here,
  // not a side effect of restoring your own settings.
  readonly property var pendingReinstalls: root.repoState.pending_reinstalls || []

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
  function doPull()     { root.busyLabel = "Pulling…";          pullProc.command = [root.cli, "pull"]; pullProc.running = true }
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
  // Newest per id (replicant.js, backupRows): undo takes the newest, so a row
  // per id is a row per button.
  readonly property var backupRows: R.backupRows(root.backups)
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
    else if (a === "install-theme")  { root.busyLabel = "Installing " + arg + "…"; dangerProc.command = [root.cli, "install-theme", arg] }
    else if (a === "install-plugin") { root.busyLabel = "Installing " + arg + "…"; dangerProc.command = [root.cli, "install-plugin", arg] }
    else if (a === "untrack")      { root.doUntrack(arg); return }
    else if (a === "undo")          { root.doUndo(arg); return }
    else if (a === "prune-backups") { root.doPruneBackups(); return }
    else return
    root.lastOutput = root.busyLabel
    dangerProc.running = true
  }

  // ── install, with the marketplace's facts in front of the consent ─────────
  // `install-plugin <id> --check` prints what the Omarchy marketplace says about
  // a plugin: its verification status, the commit that it checked, and whether
  // the origin has moved since. The confirmation shows that text, because
  // consent given without it is consent to an unknown commit. A theme has no
  // catalog entry, so it is asked about straight away.
  property var pendingInstall: null
  function askInstall(kind, id, origin) {
    var msg = "Install the " + kind + " \"" + id + "\" from " + origin + "?\n\nThis fetches whatever is at that address right now — not necessarily what you reviewed when you first installed it."
    if (kind === "theme") {
      root.ask("install-theme", id, msg + "\n\nInstalling a theme also makes it the active theme: your desktop changes to it right away.", "Install")
      return
    }
    root.pendingInstall = { id: id, message: msg }
    root.busyLabel = "Checking " + id + " in the marketplace…"
    checkProc.command = [root.cli, "install-plugin", id, "--check"]
    checkProc.running = true
  }
  CliProcess {
    id: checkProc
    onExited: function(c) {
      root.busyLabel = ""
      var p = root.pendingInstall
      root.pendingInstall = null
      if (!p) return
      var facts = (checkProc.stdout.text + "\n" + checkProc.stderr.text).replace(/\x1b\[[0-9;]*m/g, "").trim()
      if (facts === "") facts = "The marketplace check printed nothing."
      root.ask("install-plugin", p.id, p.message + "\n\n" + facts, "Install")
    }
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
              // Secrets included: the Configs tab lists them as tracked files
              // like any other, and the count left them out.
              StatCard { panel: root; columns: root.statColumns; label: "tracked"
                         value: String((root.repoState.configs || []).length + (root.repoState.secrets || []).length) }
              StatCard { panel: root; columns: root.statColumns; label: "unsaved";  value: String(root.nDirty); highlight: root.nDirty > 0 }
              StatCard { panel: root; columns: root.statColumns; label: "to restore"; value: String(root.nIncoming)
                         highlight: root.nIncoming > 0; highlightColor: root.warnColor
                         visible: root.nIncoming > 0 }
              StatCard { panel: root; columns: root.statColumns; label: "to pull";  value: String(root.nBehind);      highlight: root.nBehind > 0 }
              StatCard { panel: root; columns: root.statColumns; label: "switched off"; value: String(root.countOff) }
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
              // Two verbs here, the two a person comes for. The copy-only action
              // sat beside them as a third choice of equal weight; it is a tool,
              // and it now lives with the other tools at the foot of this tab.
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
                FactRow { panel: root; label: "Remote";      value: root.repoState.remote_name || "—" }
                FactRow { panel: root; label: "Branch";      value: (root.repoState.branch || "main") + (root.nAhead || root.nBehind ? "   ↑" + root.nAhead + " ↓" + root.nBehind : "") }
                FactRow { panel: root; label: "This machine"; value: root.repoState.machine || "—" }
                // No "Last save" row here. It printed the date and subject of the
                // newest commit — which is, verbatim, the first line of the
                // Recent saves list three rows further down the same screen,
                // where it has a column for the date and room for the subject
                // instead of eliding it.
                FactRow { panel: root; label: "Theme";       value: root.settingText("theme.current") }
                FactRow { panel: root; label: "Bar position"; value: root.settingText("bar.position") }
                FactRow { panel: root; label: "Lock screen"; value: root.settingText("idle.lock") }
                FactRow { panel: root; label: "Profile";     value: root.profileName + "  ·  " + R.plural(root.scopedCount, "file") + " kept per profile" }
                FactRow { panel: root; label: "Plugin";      value: "omarchy-replicant " + (root.repoState.plugin_version || "?") }
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
              Button {
                text: "Copy without saving"; iconText: root.icCopy; bordered: false
                foreground: root.fg; fontFamily: root.ff
                enabled: !root.busy
                tooltipText: "Copy this machine into the local repo; nothing is committed or pushed"
                onClicked: root.doBackup()
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
              delegate: CategoryCard { panel: root;
                required property var modelData
                card: modelData
                width: content.width
              }
            }

            // The list above is what the plugin ships with plus what you have
            // already added. This is how you add more — the one card that is
            // about files NOT tracked yet, kept last so it never competes with
            // the areas, and collapsed so it is an offer rather than a chore.
            SuggestCard { panel: root; width: content.width }
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
              delegate: SettingCard { panel: root;
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

            RestoreCard { panel: root;
              width: parent.width
              title: "Restore from GitHub"
              body: "Brings every config, secret and setting saved in your repo down onto this machine — and then runs whatever Omarchy needs to make it take effect: the theme is re-applied with omarchy theme set, Hyprland is reloaded. Third-party plugins and themes are never reinstalled automatically — pending ones are listed below, one Install button each."
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

            RestoreCard { panel: root;
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
                    text: areaRow.modelData.label + "   " + R.plural(areaRow.modelData.count, "file")
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

            PanelSeparator { width: parent.width; visible: root.pendingReinstalls.length > 0 }
            PanelSectionHeader {
              width: parent.width
              text: "Third-party plugins & themes"
              foreground: root.fg; fontFamily: root.ff
              visible: root.pendingReinstalls.length > 0
            }
            Text {
              width: parent.width
              visible: root.pendingReinstalls.length > 0
              text: "Recorded in your inventory but not installed here. These come from someone else's repo, so restoring never fetches them on its own — Install brings in whatever is at that address right now."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.pendingReinstalls
              delegate: Item {
                id: reinstallRow
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
                    text: root.icFolder
                    color: root.dim; font.family: root.ff; font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(18) - reinstallBtn.width - parent.spacing * 2
                    text: reinstallRow.modelData.id + "   " + reinstallRow.modelData.origin
                    color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Button {
                    id: reinstallBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Install"; iconText: root.icFromRepo; bordered: false
                    foreground: root.fg; fontFamily: root.ff
                    enabled: !root.busy
                    tooltipText: "Fetch " + reinstallRow.modelData.origin + " and install it now"
                    onClicked: root.askInstall(reinstallRow.modelData.kind,
                                               reinstallRow.modelData.id,
                                               reinstallRow.modelData.origin)
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
                    text: bakRow.modelData.id + "   " + R.agoText(bakRow.modelData.epoch)
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
                        + R.agoText(bakRow.modelData.epoch) + "?\n\nThe version you have now becomes the new .bak.<epoch>, so this can be undone again.",
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

}
