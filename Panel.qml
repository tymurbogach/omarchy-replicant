import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"
import "replicant.js" as R

// The Replicant panel: four tabs over one CLI. This file holds presentation,
// navigation and action state. ReplicantController owns CLI processes. What is
// drawn is in components/, one part each,
// and each part reaches the panel through its `panel` property. The pure logic
// is in replicant.js, where tests/qml tests it.
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
  readonly property string remoteState: String(root.repoState.remote_state || (root.repoState.remote ? "synced" : "local-only"))
  readonly property string remoteStateText: R.remoteStateWord(root.remoteState)
  readonly property bool controllerCancelAllowed: controller.cancelAllowed
  // True once a real status response has come back at least once. Gates the
  // "no repo yet — create one" screen: showing it before we know the state let
  // a stray click re-point an already-configured remote (a real incident).
  property bool asked: false

  property string lastOutput: ""
  property bool lastOk: true
  property string lastTitle: "Output"
  property string activeTab: "overview"
  property string fileSearch: ""
  property string stateFilter: "all"
  property string settingSearch: ""
  property string settingFilter: "all"
  property var scrollPositions: ({ overview: 0, configs: 0, settings: 0, restore: 0 })
  property string lastScrollTab: "overview"
  property var navigationSnapshot: null
  property bool restoringNavigation: false
  property bool navigationRestorePending: false
  property bool manageMode: false
  property bool keyboardHelpOpen: false
  property var selectedIds: []
  property string selectionAnchor: ""
  readonly property var visibleConfigRows: R.visibleRows(root.repoState, root.categoryCards, root.suggestions,
                                                        root.fileSearch, root.stateFilter)
  readonly property var selectedRows: root.everyRow.concat((root.suggestions || []).map(function(s) {
    return { id: s.id, path: s.path, kind: s.kind, size: s.size || 0, nfiles: s.nfiles || 1,
             suggestion: true, secret: s.kind === "secret" }
  })).filter(function(r) { return root.selectedIds.indexOf(r.id) !== -1 })
  readonly property var bulkActions: R.validBulkActions(root.selectedRows)
  readonly property var selectionSummary: R.selectionSummary(root.selectedRows)
  property int manageCursor: 0
  function toggleManage() {
    if (!root.manageMode) root.captureNavigation()
    root.manageMode = !root.manageMode
    if (!root.manageMode) root.selectedIds = []
    else if (root.suggestions.length > 0 && !root.isOpen("__suggest")) root.toggleCard("__suggest")
  }
  function clearSelection() { root.selectedIds = []; root.selectionAnchor = "" }
  function invertSelection() {
    var next = root.visibleConfigRows.filter(function(r) { return root.selectedIds.indexOf(r.id) === -1 }).map(function(r) { return r.id })
    root.selectedIds = next
  }
  function selectVisible() { root.selectedIds = root.visibleConfigRows.map(function(r) { return r.id }) }
  function moveManageCursor(delta) {
    if (!root.manageMode || root.activeTab !== "configs" || root.visibleConfigRows.length === 0) return
    root.manageCursor = Math.max(0, Math.min(root.visibleConfigRows.length - 1, root.manageCursor + delta))
  }
  function toggleSelected(id, extend) {
    var next = root.selectedIds.slice()
    var ids = extend && root.selectionAnchor !== ""
        ? R.rangeIds(root.visibleConfigRows, root.selectionAnchor, id) : [id]
    if (extend) {
      for (var i = 0; i < ids.length; i++) if (next.indexOf(ids[i]) < 0) next.push(ids[i])
    } else {
      var p = next.indexOf(id); if (p < 0) next.push(id); else next.splice(p, 1)
    }
    root.selectedIds = next; root.selectionAnchor = id
  }
  property var recent: []
  property int logCount: 6
  property var shortcuts: ({ own: [], active: [], own_count: 0, active_count: 0 })
  property bool shortcutsLoaded: false
  property bool showAllShortcuts: false

  // ── what is open ──────────────────────────────────────────────────────────
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
    if (id === "__suggest" && next[id] && root.addMode === "browse" && !root.browseData.dir) root.browseTo(root.repoState.home || "~")
  }
  function closeAllCards() { root.openCards = ({}); root.openRow = ""; root.openCommits = ({}) }

  // One file row is open at a time. Two open rows are two sets of buttons
  // that look alike, one above the other.
  property string openRow: ""
  function isRowOpen(id) { return root.openRow === id }
  function toggleRow(id) { root.openRow = root.openRow === id ? "" : id }

  property var openCommits: ({})
  function isCommitOpen(sha) { return root.openCommits[sha] === true }
  function toggleCommit(sha) {
    var next = {}
    for (var k in root.openCommits) next[k] = root.openCommits[k]
    next[sha] = !next[sha]
    root.openCommits = next
  }

  function setFileSearch(value) {
    root.fileSearch = value
    if (!root.restoringNavigation) root.resetCurrentTabScroll()
  }
  function setStateFilter(value) {
    root.stateFilter = value
    if (!root.restoringNavigation) root.resetCurrentTabScroll()
  }
  function setSettingSearch(value) {
    root.settingSearch = value
    if (!root.restoringNavigation) root.resetCurrentTabScroll()
  }
  function setSettingFilter(value) {
    root.settingFilter = value
    if (!root.restoringNavigation) root.resetCurrentTabScroll()
  }

  function navigationAnchorItem() {
    if (root.activeTab === "overview") return overviewTab.navigationItem(root.openCommits)
    if (root.activeTab === "configs") return configsTab.navigationItem(root.openRow, root.openCards)
    if (root.activeTab === "settings") return settingsTab.navigationItem(root.openCards)
    return restoreTab.navigationItem()
  }

  function navigationAnchor() {
    var item = root.navigationAnchorItem()
    if (!item || !body) return null
    var point = item.mapToItem(body, 0, 0)
    return { kind: root.activeTab === "configs" && root.openRow !== "" ? "row" : "card",
             id: item.navigationId || "", offset: point.y - body.contentY }
  }

  function rememberCurrentScroll() {
    if (!body || !root.lastScrollTab) return
    var next = {}
    for (var k in root.scrollPositions) next[k] = root.scrollPositions[k]
    next[root.lastScrollTab] = body.contentY
    root.scrollPositions = next
  }

  function captureNavigation() {
    if (!root.opened || !body) return
    root.rememberCurrentScroll()
    root.navigationSnapshot = R.navigationSnapshot({
      activeTab: root.activeTab,
      scrollY: root.scrollPositions,
      openCards: root.openCards,
      openRow: root.openRow,
      openCommits: root.openCommits,
      fileSearch: root.fileSearch,
      stateFilter: root.stateFilter,
      settingSearch: root.settingSearch,
      settingFilter: root.settingFilter,
      manageMode: root.manageMode,
      selectedIds: root.selectedIds,
      selectionAnchor: root.selectionAnchor,
      anchor: root.navigationAnchor()
    })
  }

  function resetCurrentTabScroll() {
    var next = {}
    for (var k in root.scrollPositions) next[k] = root.scrollPositions[k]
    next[root.activeTab] = 0
    root.scrollPositions = next
    if (body) body.contentY = 0
  }

  function applyNavigationSnapshot(snapshot) {
    if (!snapshot) return
    root.restoringNavigation = true
    root.activeTab = snapshot.activeTab
    root.openCards = snapshot.openCards
    root.openRow = snapshot.openRow
    root.openCommits = snapshot.openCommits
    root.fileSearch = snapshot.fileSearch
    root.stateFilter = snapshot.stateFilter
    root.settingSearch = snapshot.settingSearch
    root.settingFilter = snapshot.settingFilter
    root.manageMode = snapshot.manageMode
    root.selectedIds = snapshot.selectedIds
    root.selectionAnchor = snapshot.selectionAnchor
    root.scrollPositions = snapshot.scrollY
    root.lastScrollTab = snapshot.activeTab
    root.restoringNavigation = false
  }

  function restoreNavigation() {
    if (!root.navigationSnapshot || !body) return
    var snapshot = root.navigationSnapshot
    root.applyNavigationSnapshot(snapshot)
    root.navigationRestorePending = true
    Qt.callLater(function() {
      if (!root.navigationRestorePending || !body) return
      var item = root.navigationAnchorItem()
      var target = R.navigationScroll(snapshot, root.activeTab, body.contentHeight - body.height)
      if (item && snapshot.anchor) {
        var point = item.mapToItem(body, 0, 0)
        target = Math.max(0, Math.min(point.y - snapshot.anchor.offset, body.contentHeight - body.height))
      }
      body.contentY = target
      var next = {}
      for (var k in root.scrollPositions) next[k] = root.scrollPositions[k]
      next[root.activeTab] = target
      root.scrollPositions = next
      root.navigationRestorePending = false
    })
  }
  function showOlder() { root.logCount = Math.min(40, root.logCount + 8); root.loadLog() }

  // The key catcher takes every key before the item that has focus, so while
  // a text field has focus it must stand aside, or typing an "s" saves.
  property Item focusedField: null
  function noteFocus(field, focused) {
    if (focused) root.focusedField = field
    else if (root.focusedField === field) root.focusedField = null
  }
  function releaseFocus() { root.focusedField = null; keyCatcher.forceActiveFocus() }

  // ── in-flight state ───────────────────────────────────────────────────────
  // A scope change is not here on purpose: it shows at once and runs in its
  // own queue (setScope), so it never greys out the rest of the panel.
  readonly property bool busy: controller.busy
  readonly property bool saving: controller.isRunning("save")
  readonly property bool pulling: controller.isRunning("pull")
  readonly property bool checking: controller.isRunning("doctor")
  readonly property bool updateChecking: controller.isRunning("update-check")
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
  ReplicantController { id: controller; cli: root.cli }

  // ── icons ─────────────────────────────────────────────────────────────────
  // Held as Material Design Icon CODE POINTS, not as pasted glyphs. Two reasons:
  // the name next to each number says what it is meant to be (the previous set
  // was chosen from memory and shipped a plus-minus sign as "reset" and a
  // crossed-out cloud as "pull"), and every one of these lives above U+FFFF,
  // where a stray re-encoding of this file silently truncates the glyph to a
  // different character. Each was rendered against the shell's own font and
  // looked at before being used. R.mdi (replicant.js) builds the string.
  readonly property string icRefresh: R.mdi(0xF0450)    // refresh
  readonly property string icPush: R.mdi(0xF0167)       // cloud-upload
  readonly property string icPull: R.mdi(0xF0162)       // cloud-download
  readonly property string icCopy: R.mdi(0xF018F)       // content-copy
  readonly property string icEdit: R.mdi(0xF03EB)       // pencil
  readonly property string icDiff: R.mdi(0xF08AA)       // file-compare
  readonly property string icSave: R.mdi(0xF0193)       // content-save
  readonly property string icDefault: R.mdi(0xF099B)    // restore
  readonly property string icFromRepo: R.mdi(0xF01DA)   // download
  readonly property string icShield: R.mdi(0xF0498)     // shield
  readonly property string icFolder: R.mdi(0xF024B)     // folder
  readonly property string icFolderOpen: R.mdi(0xF0770) // folder-open
  readonly property string icFile: R.mdi(0xF0224)       // file
  readonly property string icPlus: R.mdi(0xF0415)       // plus
  readonly property string icBranch: R.mdi(0xF062C)     // source-branch
  readonly property string icClose: R.mdi(0xF0156)      // close
  readonly property string icDown: R.mdi(0xF0140)       // chevron-down
  readonly property string icRight: R.mdi(0xF0142)      // chevron-right
  readonly property string icUp: R.mdi(0xF005D)         // arrow-up
  readonly property string icInfo: R.mdi(0xF02FC)       // information
  readonly property string icMachine: R.mdi(0xF0176)    // laptop
  readonly property string icUpdate: R.mdi(0xF06B0)     // update
  readonly property string icCheck: R.mdi(0xF05E0)      // check-circle
  readonly property string icAlert: R.mdi(0xF0028)      // alert-circle
  readonly property string icGithub: R.mdi(0xF02A4)     // github
  readonly property string icRecover: R.mdi(0xF0819)    // delete-restore
  readonly property string icHistory: R.mdi(0xF02DA)    // history
  readonly property string icEye: R.mdi(0xF0208)        // eye
  readonly property string icKey: R.mdi(0xF0306)        // key
  readonly property string icLink: R.mdi(0xF0339)       // link-variant
  readonly property string icTheme: R.mdi(0xF03D8)      // palette
  readonly property string icPlugin: R.mdi(0xF0431)     // puzzle
  // The plugin's own mark: identical cells, more than one of them. The OUTLINE
  // variant is used here and the filled one in the bar: at 30px the outline
  // reads as three distinct hexagons, at 13px it collapses into rings.
  readonly property string icReplicant: R.mdi(0xF10F2)  // hexagon-multiple-outline
  readonly property string icShared: R.mdi(0xF0191)     // content-duplicate
  readonly property string icProfile: R.mdi(0xF0322)   // laptop
  readonly property string icOff: R.mdi(0xF0377)       // minus-circle-outline
  // A list with a minus, NOT a waste basket. Untracking removes an entry from
  // your list and the copy from the repo; the file on the machine is untouched,
  // and a trash can on that button would say the opposite of what it does.
  readonly property string icUntrack: R.mdi(0xF0410)    // playlist-remove

  // Paths are shown the way the CLI shows them. "/home/<user>" is a third of a
  // row spent saying nothing.
  function pretty(p) { return R.prettyPath(p, root.repoState.home || "") }
  // Where a file lives, but only when that is not already on screen. A row's
  // title IS its path under ~/.config, so printing it again under the title
  // spent the row's width saying nothing. The rows that do surprise you (a
  // dotfile in $HOME, a script in ~/.local/bin, a drop-in under /etc) print
  // whole.
  function whereText(c) {
    var src = String(c.src || "")
    var h = root.repoState.home || ""
    if (h !== "" && src === h + "/.config/" + String(c.id || "")) return ""
    return root.pretty(src)
  }
  // The glyph, the word and the colour role of each sync state are in
  // replicant.js, where tests/qml tests them. The colours are the panel's own.
  function stateColor(st) {
    var role = R.stateRole(st)
    if (role === "warn") return root.warnColor
    if (role === "accent") return Color.accent
    if (role === "ok") return root.okColor
    return root.dim
  }

  // ── derived summaries ─────────────────────────────────────────────────────
  readonly property string profileName: root.repoState.profile || "this machine"
  // Every row, secrets included, in the one shape the Configs tab draws.
  readonly property var everyRow: R.allRows(root.repoState)
  readonly property var configRows: root.everyRow.filter(function(r) { return r.secret !== true })
  function idsWhere(pred) { return root.everyRow.filter(pred).map(function(r) { return r.id }) }
  readonly property int nTracked: root.everyRow.length
  // Counted from the rows themselves, not from repoState.dirty. The badges and
  // the header have to answer to one source or they contradict each other.
  readonly property int nDirty: root.everyRow.filter(function(r) { return r.sync_state === "unsaved" }).length
  // Files a pull brought a newer copy of: the one state where pressing the
  // OTHER button, Save, commits over what another machine did.
  readonly property int nIncoming: root.everyRow.filter(function(r) { return r.sync_state === "incoming" }).length
  readonly property int nOff: root.everyRow.filter(function(r) { return r.sync_state === "off" }).length
  readonly property int nMissing: root.everyRow.filter(function(r) { return r.sync_state === "missing" }).length
  readonly property int nLocked: root.everyRow.filter(function(r) { return r.sync_state === "locked" || r.locked === true }).length
  readonly property int nLarge: root.everyRow.filter(function(r) { return Number(r.size || 0) >= 1024 * 1024 }).length
  readonly property int nChanged: root.everyRow.filter(function(r) { return R.needsAttention(r.sync_state) }).length
  readonly property int nAhead: repoState.ahead || 0
  readonly property int nBehind: repoState.behind || 0

  // What the header, the banner and the status card say. The order of the
  // rules is in replicant.js (summary, advice, headline), where it is tested.
  readonly property var facts: ({ asked: root.asked, ready: root.ready, ahead: root.nAhead,
                                  behind: root.nBehind, incoming: root.nIncoming, dirty: root.nDirty,
                                  tracked: root.nTracked,
                                  lastSave: root.recent.length > 0 && root.recent[0].epoch ? R.agoText(root.recent[0].epoch) : "" })
  readonly property string summary: R.summary(root.facts)
  readonly property string advice: R.advice(root.facts)
  readonly property var head: R.headline(root.facts)

  readonly property string versionText: {
    var v = root.repoState.plugin_version || root.updateInfo.current || ""
    return v !== "" ? "v" + v : ""
  }
  readonly property string metaText: root.ready
      ? root.summary + "  ·  " + (root.repoState.machine || "") + "  ·  " + root.profileName + " profile"
      : root.summary

  // The counts under the status card. Only the ones with something to say,
  // each with the names behind it, and each one a click away from them.
  readonly property var chips: {
    var out = []
    var nConfigs = root.configRows.length
    out.push({ id: "tracked", text: root.nTracked + " tracked", tone: "normal",
               tooltip: "Everything Replicant backs up: " + R.plural(nConfigs, "config") + " and "
                        + R.plural(root.nTracked - nConfigs, "secret") + ".\nClick to see them." })
    if (root.nDirty > 0)
      out.push({ id: "unsaved", text: "● " + root.nDirty + " unsaved", tone: "accent",
                 tooltip: "Changed on this machine and not in your repo yet:\n"
                          + R.nameList(root.idsWhere(function(r) { return r.sync_state === "unsaved" }))
                          + "\nClick to see them." })
    if (root.nIncoming > 0)
      out.push({ id: "incoming", text: "↓ " + root.nIncoming + " to restore", tone: "warn",
                 tooltip: "Another machine saved a newer copy of:\n"
                          + R.nameList(root.idsWhere(function(r) { return r.sync_state === "incoming" }))
                          + "\nRestore puts it here. Click to see them." })
    if (root.nBehind > 0)
      out.push({ id: "pull", text: "↓ " + root.nBehind + " on GitHub", tone: "warn",
                 tooltip: R.plural(root.nBehind, "commit") + " that another machine pushed and this one does not have.\nClick to pull them." })
    if (root.nAhead > 0)
      out.push({ id: "push", text: "↑ " + root.nAhead + " to push", tone: "accent",
                 tooltip: R.plural(root.nAhead, "commit") + " made here and not pushed yet.\nClick to push them." })
    if (root.nMissing > 0)
      out.push({ id: "missing", text: "· " + root.nMissing + " gone", tone: "dim",
                 tooltip: "Tracked, and gone from this machine:\n"
                          + R.nameList(root.idsWhere(function(r) { return r.sync_state === "missing" }))
                          + "\nClick to restore or forget them." })
    if (root.nOff > 0)
      out.push({ id: "off", text: "⊘ " + root.nOff + " off", tone: "dim",
                 tooltip: "Switched off: never saved from here, never restored onto here:\n"
                          + R.nameList(root.idsWhere(function(r) { return r.sync_state === "off" }))
                          + "\nClick to see them." })
    if (root.suggestions.length > 0)
      out.push({ id: "add", text: "+ " + root.suggestions.length + " to add", tone: "normal",
                 tooltip: "Config on this machine that nothing backs up yet.\nClick to see it." })
    return out
  }
  function chipClicked(id) {
    if (id === "pull") { root.doPull(); return }
    if (id === "push") { root.doSavegame(); return }
    root.activeTab = "configs"
    if (id === "add") {
      root.stateFilter = "all"
      root.addMode = "suggest"
      if (!root.isOpen("__suggest")) root.toggleCard("__suggest")
      return
    }
    root.stateFilter = id === "off" ? "off" : id === "tracked" ? "all" : "changed"
  }

  readonly property var tabs: [
    { value: "overview", label: "Overview", icon: R.mdi(0xF056E), tooltip: "This machine at a glance  (1)" },
    { value: "configs",  label: "Configs",  icon: R.mdi(0xF107F), tooltip: "Everything being backed up, by area  (2)" },
    { value: "settings", label: "Settings", icon: R.mdi(0xF0493), tooltip: "Change a value and it is written and saved  (3)" },
    { value: "restore",  label: "Restore",  icon: R.mdi(0xF099B), tooltip: "Bring a whole machine back  (4)" }
  ]

  // ── the Configs tab ───────────────────────────────────────────────────────
  // The rows of one area, secrets included, filtered by the search and the
  // state filter and sorted (replicant.js, rowsFor).
  function rowsFor(categoryId) { return R.rowsFor(root.repoState, categoryId, root.fileSearch, root.stateFilter) }
  readonly property bool filtering: root.fileSearch !== "" || root.stateFilter !== "all"
  readonly property var filterOptions: [
    { value: "all", label: "All", tooltip: "Every tracked file" },
    { value: "changed", label: "Changed",
      tooltip: "Unsaved, to restore, to push, or gone from this machine: the rows with a button to press" },
    { value: "incoming", label: "Incoming", tooltip: "Rows saved by another machine and waiting to be restored" },
    { value: "missing", label: "Missing", tooltip: "Tracked rows that are not on this machine" },
    { value: "locked", label: "Locked", tooltip: "Secrets that need the encryption key" },
    { value: "large", label: "Large", tooltip: "Files and trees of at least 1 MB" },
    { value: "off", label: "Off", tooltip: "Switched off: never saved from here, never restored onto here" }
  ]

  // Categories that actually have something in them, with their counts. An
  // empty card is a card you have to read and then dismiss.
  readonly property var categoryCards: {
    var cats = root.repoState.categories || []
    var out = []
    for (var i = 0; i < cats.length; i++) {
      var rows = root.rowsFor(cats[i].id)
      var total = R.rowsFor(root.repoState, cats[i].id, "", "all").length
      if (rows.length === 0) continue
      // Counted from the same states the badges render, not a separate word.
      var changed = 0, off = 0, incoming = 0
      for (var j = 0; j < rows.length; j++) {
        if (rows[j].sync_state === "unsaved" || rows[j].sync_state === "unpushed") changed++
        if (rows[j].sync_state === "incoming") incoming++
        if (rows[j].synced === false) off++
      }
      out.push({
        id: cats[i].id, icon: cats[i].icon, label: cats[i].label,
        description: cats[i].description, method: cats[i].method,
        rows: rows, count: rows.length, total: total, changed: changed, off: off, incoming: incoming
      })
    }
    return out
  }

  // ── the Restore tab ───────────────────────────────────────────────────────
  // Every area with what a restore of it would write, unfiltered: the search
  // on the Configs tab must not change what "restore this area" means.
  readonly property var areaSummaries: {
    var cats = root.repoState.categories || []
    var out = []
    for (var i = 0; i < cats.length; i++) {
      var rows = R.rowsFor(root.repoState, cats[i].id, "", "all")
      if (rows.length === 0) continue
      out.push({ id: cats[i].id, icon: cats[i].icon, label: cats[i].label, method: cats[i].method,
                 count: rows.length, differ: rows.filter(R.wouldRestore).length })
    }
    return out
  }
  readonly property int restoreDiffers: root.areaSummaries.reduce(function(n, a) { return n + a.differ }, 0)
  // What reset-all would touch: a file Omarchy ships a default for, here, not
  // at that default, and where `omarchy refresh config` can reach it.
  readonly property int resetDiffers: (root.repoState.configs || []).filter(function(c) {
    return c.has_default === true && c.exists === true && c.is_default !== true
           && c.is_dir !== true && String(c.config_rel || "") !== ""
  }).length
  // Third-party themes/plugins the inventory knows about but this machine
  // does not have. `restore` reports these, it never installs them: one row,
  // one Install button, so fetching someone else's current code is always a
  // decision made here, not a side effect of restoring your own settings.
  readonly property var pendingReinstalls: root.repoState.pending_reinstalls || []

  // ── settings, grouped in registry order ───────────────────────────────────
  readonly property int nCustomised: (root.repoState.settings || []).filter(function(s) { return s.can_revert_default === true }).length
  readonly property bool settingFiltering: root.settingSearch !== "" || root.settingFilter !== "all"
  readonly property var settingFilterOptions: [
    { value: "all", label: "All  " + (root.repoState.settings || []).length, tooltip: "Every setting" },
    { value: "customised", label: "Customised  " + root.nCustomised, tooltip: "The values that differ from what Omarchy ships" }
  ]
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
      if (root.settingFilter === "customised") items = items.filter(function(s) { return s.can_revert_default === true })
      if (items.length === 0) continue
      var changed = items.filter(function(s) { return s.can_revert_default }).length
      out.push({ id: "set:" + meta[g].name, name: meta[g].name, icon: meta[g].icon,
                 description: meta[g].description, items: items, changed: changed })
    }
    return out
  }

  // ── actions ───────────────────────────────────────────────────────────────
  function refresh() { root.captureNavigation(); if (hostWidget) hostWidget.refresh(true); root.loadLog() }
  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
  function clean(s) { return String(s || "").replace(/\x1b\[[0-9;]*m/g, "").replace(/\n{3,}/g, "\n\n").trim() }

  // --auto is not a convenience here, it is the difference between the button
  // working and not. Bare `savegame` commits the inventory, pushes that, and
  // deliberately leaves config and secrets copied-in-but-uncommitted so a human
  // can write one commit per change explaining why — and this panel has nowhere
  // to type that why.
  function doSavegame() { root.busyLabel = "Saving to GitHub…"; controller.run("save", [root.cli, "savegame", "--auto"], { label: "Save", cancelable: true }) }
  function cancelSave() { if (controller.cancel()) root.busyLabel = "Cancelling save…" }
  function doRetryPush() { root.busyLabel = "Publishing local commits…"; controller.run("push", [root.cli, "push"], { label: "Retry push" }) }
  function doPull()     { root.busyLabel = "Pulling from GitHub…"; controller.run("pull", [root.cli, "pull"], { label: "Pull" }) }
  function doBackup()   { root.busyLabel = "Copying files into the repo…"; controller.run("backup", [root.cli, "backup"], { label: "Copy" }) }
  function doDoctor()   { root.busyLabel = "Running the health check…"; controller.run("doctor", [root.cli, "doctor"], { label: "Health check" }) }

  function loadShortcuts() { controller.run("shortcuts", [root.cli, "shortcuts", "--json"], { busy: false }) }
  function loadLog() {
    if (controller.running) return
    controller.run("log", [root.cli, "log", "--json", "-n", String(root.logCount)], { busy: false })
  }

  // Open the editor. Deliberately NOT through
  // omarchy-launch-floating-terminal-with-presentation: that wraps the command
  // in the Omarchy logo plus a "press a key to close" prompt. The panel closes
  // so the editor is not opened behind it, and comes back the moment the
  // editor is closed, same tab and same open cards. Only some editors can be
  // waited on, so the CLI says whether it actually waited.
  function doEdit(id) {
    root.captureNavigation()
    controller.run("edit", [root.cli, "edit", id, "--wait"], { busy: false })
    root.lastOk = true
    root.lastOutput = "Opening " + id + " in your editor…"
    root.close()
  }

  // Diffs are read, not interacted with, so they belong in the panel next to
  // the file they describe rather than in a terminal that has to be dismissed.
  function doDiff(id) {
    root.captureNavigation()
    root.viewerRowId = id
    root.openViewer(id, "Loading…", "diff")
    controller.run("diff", [root.cli, "diff", id], { busy: false })
  }

  function moveDiff(delta) {
    if (!root.viewerOpen || root.viewerKind !== "diff" || root.diffRows.length === 0) return
    var index = -1
    for (var i = 0; i < root.diffRows.length; i++) {
      if (root.diffRows[i].id === root.viewerRowId) { index = i; break }
    }
    if (index < 0) index = 0
    index = (index + delta + root.diffRows.length) % root.diffRows.length
    root.doDiff(root.diffRows[index].id)
  }

  function doSaveFile(id) {
    root.busyLabel = "Saving " + id + "…"
    controller.run("save-file", [root.cli, "save-file", id, "-m", "config: update " + id], { label: "Save file" })
  }
  function copyPath(path, secret) {
    if (secret === true || String(path || "") === "") return
    root.busyLabel = "Copying path…"
    controller.run("copy-path", ["sh", "-c", "printf '%s' \"$1\" | wl-copy", "replicant-copy", String(path)], { label: "Copy path" })
  }
  function executeBulk(action) {
    if (root.selectedIds.length === 0 || root.bulkActions.indexOf(action) < 0) return
    var cmd = [root.cli, "bulk", action]
    var targets = root.selectedRows.map(function(r) { return r.suggestion ? r.path : r.id })
    if (action === "scope-shared" || action === "scope-profile" || action === "scope-off") {
      var scope = action.slice(6)
      cmd = [root.cli, "bulk", "scope", "--scope", scope]
      if (scope === "off") cmd.push("--yes")
    } else if (action === "track-secret" || action === "track-config") {
      var trackKind = action === "track-secret" ? "secret" : "config"
      cmd = [root.cli, "bulk", "track", "--kind", trackKind, "--yes"]
    } else if (action === "convert-secret" || action === "untrack") {
      cmd.push("--yes")
    }
    cmd.push("--"); for (var i = 0; i < targets.length; i++) cmd.push(targets[i])
    root.busyLabel = "Applying bulk change…"
    controller.run("bulk", cmd, { label: "Bulk change", bulkAction: action })
    if (action.indexOf("scope-") === 0) {
      var next = {}; for (var k in root.scopeOverrides) next[k] = root.scopeOverrides[k]
      var optimistic = action.slice(6)
      for (var j = 0; j < root.selectedIds.length; j++) next[root.selectedIds[j]] = optimistic
      root.scopeOverrides = next
    }
  }
  function doBulk(action) {
    if (["scope-off", "convert-secret", "untrack"].indexOf(action) >= 0) {
      var names = root.selectedIds.slice(0, 12).join("\n  ")
      var more = root.selectedIds.length > 12 ? "\n  +" + (root.selectedIds.length - 12) + " more" : ""
      root.ask("bulk:" + action, "", "Apply '" + action + "' to " + root.selectedIds.length
               + " entries?\n\n  " + names + more + "\n\n"
               + root.selectionSummary.files + " files · " + R.sizeText(root.selectionSummary.bytes), "Apply")
      return
    }
    root.executeBulk(action)
  }

  function doSetSetting(id, value) {
    root.busyLabel = "Saving " + id + "…"
    controller.run("setting", [root.cli, "set", id, String(value)], { label: "Setting" })
  }

  function doRevert(id, to) {
    root.busyLabel = "Reverting " + id + "…"
    controller.run("setting", [root.cli, "revert", id, "--to", to], { label: "Setting" })
  }

  function askRestoreFile(row) {
    root.ask("restore-file", row.id,
             (row.exists === false ? "Put " + row.label + " back on this machine from your repo?"
                                   : "Replace " + row.label + " with the copy saved in your repo?")
             + "\n\nWhatever is there now is kept as .bak.<epoch>.",
             "Restore")
  }

  // ── scopes ────────────────────────────────────────────────────────────────
  function scopeHint(scope) {
    if (scope === "profile")
      return "Kept per profile: this machine saves and restores the '" + root.profileName
           + "' copy, and never overwrites another profile's."
    if (scope === "off")
      return "Switched off: not saved from here and not restored onto here. The repo keeps what it already has."
    return "Shared: one copy in your repo, saved and restored by every machine."
  }

  // A scope change shows at once. It used to disable the whole panel while
  // the command committed and pushed, and then wait for a full status with a
  // fetch: six seconds between the click and the button saying what was
  // clicked. Now the row shows the new scope straight away, the changes run
  // one after another in their own queue, and the status that follows does
  // not force a fetch. The CLI's lock keeps them in order with everything else.
  property var scopeOverrides: ({})
  property var scopeQueue: []
  property bool scopeAwaitingStatus: false
  function setScope(id, scope) {
    var next = {}
    for (var k in root.scopeOverrides) next[k] = root.scopeOverrides[k]
    next[id] = scope
    root.scopeOverrides = next
    var q = root.scopeQueue.filter(function(j) { return j.id !== id })
    q.push({ id: id, scope: scope })
    root.scopeQueue = q
    if (!controller.running) root.runNextScope()
  }
  function runNextScope() {
    if (root.scopeQueue.length === 0) {
      root.scopeAwaitingStatus = true
      if (hostWidget) hostWidget.refresh(false)
      return
    }
    var job = root.scopeQueue[0]
    root.scopeQueue = root.scopeQueue.slice(1)
    controller.run("scope", [root.cli, "scope", job.id, job.scope], { jobId: job.id, label: "Sync" })
  }
  function dropScopeOverride(id) {
    var next = {}
    for (var k in root.scopeOverrides) if (k !== id) next[k] = root.scopeOverrides[k]
    root.scopeOverrides = next
  }
  // A full status built after the last change finished is the truth. A brief
  // one carries no rows, so it cannot confirm anything.
  onRepoStateChanged: {
    if (root.navigationSnapshot) root.restoreNavigation()
    if (root.scopeAwaitingStatus && !controller.running && root.scopeQueue.length === 0
        && root.repoState && root.repoState.brief !== true) {
      root.scopeOverrides = ({})
      root.scopeAwaitingStatus = false
    }
  }

  // ── adding files ──────────────────────────────────────────────────────────
  // The shipped manifest is what every Omarchy user plausibly has. Everything
  // else is the user's. `suggest` proposes and the picker lets a person choose
  // anything, and nothing is tracked until a Track button is pressed.
  property var suggestions: []
  property bool suggestLoaded: false
  function loadSuggestions() {
    controller.run("suggest", [root.cli, "suggest", "--json"], { busy: false })
  }
  property string addMode: "suggest"
  function setAddMode(m) {
    root.addMode = m
    if (m === "browse" && !root.browseData.dir) root.browseTo(root.repoState.home || "~")
  }
  property var browseData: ({})
  property bool browseLoading: controller.isRunning("browse")
  property string browsePending: ""
  function browseTo(dir) {
    if (controller.running) { root.browsePending = dir; return }
    controller.run("browse", [root.cli, "browse-json", dir], { busy: false })
  }
  function browseUp() { if (root.browseData.parent) root.browseTo(root.browseData.parent) }
  // A path typed in. One that is not absolute starts at the folder shown.
  function trackTyped(text, secret) {
    var t = String(text || "").trim()
    if (t === "") return false
    if (t.charAt(0) !== "/" && t.charAt(0) !== "~") t = (root.browseData.dir || root.repoState.home || "") + "/" + t
    root.doTrack(t, secret ? "secret" : "config")
    return true
  }
  function doTrack(path, kind) {
    root.busyLabel = "Tracking " + root.pretty(path) + "…"
    var cmd = [root.cli, "track", path]
    if (kind === "secret") cmd.push("--secret")
    controller.run("track", cmd, { label: "Track" })
  }
  function doUntrack(id) {
    root.busyLabel = "Untracking " + id + "…"
    controller.run("track", [root.cli, "untrack", id], { label: "Track" })
  }

  // ── the safety net, made visible ──────────────────────────────────────────
  // Every write this plugin makes to the machine keeps what it overwrote as
  // <file>.bak.<epoch>. A backup you cannot find is not a backup, and "I
  // restored and it was wrong" is the exact moment somebody opens this tab.
  property var backups: []
  property bool backupsLoaded: false
  function loadBackups() {
    controller.run("backups", [root.cli, "backups-json"], { busy: false })
  }
  // Newest per id (replicant.js, backupRows): undo takes the newest, so a row
  // per id is a row per button.
  readonly property var backupRows: R.backupRows(root.backups)
  function doUndo(id) {
    root.busyLabel = "Undoing " + id + "…"
    controller.run("undo", [root.cli, "undo", id, "--apply"], { label: "Undo" })
  }
  function doPruneBackups() {
    root.busyLabel = "Removing backups…"
    controller.run("undo", [root.cli, "backups", "--prune", "--apply"], { label: "Undo" })
  }

  // Copies that left the repo, by the commit that removed them. Git history
  // kept them, and one button undoes one commit's deletions.
  property var deletedList: []
  function loadDeleted() {
    if (controller.running) return
    controller.run("deleted", [root.cli, "deleted", "--json"], { busy: false })
  }
  function askRecover(item) {
    var names = (item.files || []).map(function(f) { return R.repoPathLabel(f).label })
    root.ask("recover", item.sha,
             "Bring back what " + item.short + " deleted?\n\n" + R.nameList(names, 10)
             + "\n\nThe copies return to your repo, an entry that was untracked is tracked again, and each file is put back on this machine. Whatever is there now is kept as .bak.<epoch>.",
             "Bring back")
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

  // ── the plugin's own updates ──────────────────────────────────────────────
  // The check asks the plugin's origin at most every six hours on its own, and
  // always when the version in the header is clicked. An update goes through
  // `omarchy plugin update`, which validates the new version and rolls back one
  // that fails, and then the shell restarts to load it.
  property var updateInfo: ({})
  property bool updateCheckForced: false
  property bool updateCheckedOnce: false
  readonly property bool updateAvailable: root.updateInfo.available === true && root.updateInfo.installed === true
  readonly property string updateTooltip: {
    var u = root.updateInfo
    if (u.available !== true) return "Ask GitHub whether a newer Replicant exists"
    var lines = (u.commits || []).slice(0, 8).map(function(c) { return "  " + c.sha + "  " + c.subject })
    return "Replicant " + u.latest + " is available. This machine has " + u.current + ".\n"
         + lines.join("\n") + ((u.commits || []).length > 8 ? "\n  +" + (u.commits.length - 8) + " more" : "")
         + (u.installed === true ? "" : "\nThis copy is a development checkout: update it with git pull.")
  }
  function checkUpdates(force) {
    if (controller.isRunning("update-check")) return
    root.updateCheckForced = force === true
    root.updateCheckedOnce = true
    controller.run("update-check", force === true ? [root.cli, "update-check", "--json", "--fetch"]
                                                   : [root.cli, "update-check", "--json"], { busy: false })
  }
  function askUpdate() {
    var u = root.updateInfo
    var lines = (u.commits || []).slice(0, 10).map(function(c) { return "  " + c.sha + "  " + c.subject })
    root.ask("update", "",
             "Update Replicant from " + u.current + " to " + u.latest + "?\n\n" + lines.join("\n")
             + ((u.commits || []).length > 10 ? "\n  +" + (u.commits.length - 10) + " more" : "")
             + "\n\nOmarchy's plugin update installs and checks it, and the shell restarts to load it. Your data repo is not touched.",
             "Update")
  }
  function askMigrationCleanup() {
    root.ask("migration-confirm", "",
             "Confirm that you rotated relevant credentials, deleted or secured the legacy remote, and removed or secured the legacy local copy.",
             "Confirm cleanup")
  }

  // ── confirmations ─────────────────────────────────────────────────────────
  // Every destructive action is confirmed here rather than in a terminal, and
  // then runs headless with --yes. The terminal round-trip was the thing that
  // made these feel heavy, not the confirmation itself.
  property string confirmAction: ""
  property string confirmArg: ""
  function ask(action, arg, message, confirmText) {
    root.captureNavigation()
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
    var command = null, label = "Restore"
    if (a === "reset-file")        { root.busyLabel = "Resetting " + arg + "…"; command = [root.cli, "reset", arg]; label = "Reset" }
    else if (a === "restore-file") { root.busyLabel = "Restoring " + arg + "…"; command = [root.cli, "restore-file", arg] }
    else if (a === "reset-all")    { root.busyLabel = "Resetting everything…"; command = [root.cli, "reset-all", "--apply", "--yes"]; label = "Reset" }
    else if (a === "restore-all")  { root.busyLabel = "Restoring everything…"; command = [root.cli, "restore", "--apply", "--all", "--yes"] }
    else if (a === "restore-cat")  { root.busyLabel = "Restoring " + arg + "…"; command = [root.cli, "restore", "--apply", "--yes", "--only", arg] }
    else if (a === "recover")      { root.busyLabel = "Bringing back " + arg.slice(0, 7) + "…"; command = [root.cli, "recover", arg, "--apply"]; label = "Bring back" }
    else if (a === "install-theme")  { root.busyLabel = "Installing " + arg + "…"; command = [root.cli, "install-theme", arg]; label = "Install" }
    else if (a === "install-plugin") { root.busyLabel = "Installing " + arg + "…"; command = [root.cli, "install-plugin", arg]; label = "Install" }
    else if (a === "untrack")      { root.doUntrack(arg); return }
    else if (a === "forget")       { root.busyLabel = "Forgetting " + arg + "…"; controller.run("track", [root.cli, "forget", arg], { label: "Track" }); return }
    else if (a === "undo")          { root.doUndo(arg); return }
    else if (a === "prune-backups") { root.doPruneBackups(); return }
    else if (a === "update")        { root.busyLabel = "Updating Replicant…"; controller.run("update", [root.cli, "update", "--yes", "--restart"], { label: "Update" }); return }
    else if (a === "migration-confirm") { root.busyLabel = "Recording migration confirmation…"; command = [root.cli, "migration-confirm"]; label = "Migration" }
    else if (a.indexOf("bulk:") === 0) { root.executeBulk(a.slice(5)); return }
    else return
    if (command) controller.run("danger", command, { label: label })
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
    controller.run("market-check", [root.cli, "install-plugin", id, "--check"], { busy: false })
  }

  // ── the reader ────────────────────────────────────────────────────────────
  property bool viewerOpen: false
  property string viewerTitle: ""
  property string viewerText: ""
  property string viewerKind: "output"
  property string viewerRowId: ""
  readonly property var diffRows: root.visibleConfigRows.filter(function(r) { return r.suggestion !== true })
  function openViewer(title, text, kind) {
    root.viewerTitle = title
    root.viewerText = text
    root.viewerKind = kind || "output"
    root.viewerOpen = true
  }
  function closeViewer() { root.viewerOpen = false; root.viewerRowId = "" }
  // A dry run, read in full in the reader. It writes nothing.
  function runPreview(title, args) {
    if (controller.isRunning("preview")) return
    root.openViewer(title, "Working out what would change…", "output")
    controller.run("preview", [root.cli].concat(args), { busy: false })
  }

  // Every write refreshes status on exit, so the badges never drift from disk.
  Connections {
    target: controller
    function onCompleted(job, code, stdoutText, stderrText, meta) {
      var text = root.clean(stderrText + "\n" + stdoutText)
      if (job === "log") {
        try { root.recent = JSON.parse(stdoutText || "[]") } catch (e) { root.recent = [] }
      } else if (job === "shortcuts") {
        try { root.shortcuts = JSON.parse(stdoutText || "{}"); root.shortcutsLoaded = true } catch (e) { root.shortcutsLoaded = false }
      } else if (job === "suggest") {
        try { root.suggestions = JSON.parse(stdoutText || "[]") } catch (e) { root.suggestions = [] }
        root.suggestLoaded = true
      } else if (job === "browse") {
        try { root.browseData = JSON.parse(stdoutText || "{}") } catch (e) { root.browseData = ({ error: "could not be read", entries: [] }) }
        if (root.browsePending !== "") { var d = root.browsePending; root.browsePending = ""; root.browseTo(d) }
      } else if (job === "backups") {
        try { root.backups = JSON.parse(stdoutText || "[]") } catch (e) { root.backups = [] }
        root.backupsLoaded = true
      } else if (job === "deleted") {
        try { root.deletedList = JSON.parse(stdoutText || "[]") } catch (e) { root.deletedList = [] }
      } else if (job === "diff" || job === "preview") {
        root.viewerText = text !== "" ? text : (job === "diff" ? "No differences." : "Nothing would change.")
      } else if (job === "market-check") {
        root.busyLabel = ""
        var install = root.pendingInstall
        root.pendingInstall = null
        if (install) root.ask("install-plugin", install.id, install.message + "\n\n" + (text || "The marketplace check printed nothing."), "Install")
      } else if (job === "update-check") {
        try { root.updateInfo = JSON.parse(stdoutText || "{}") } catch (e) { root.updateInfo = ({}) }
        if (root.updateCheckForced) {
          var u = root.updateInfo
          root.lastTitle = "Check for updates"
          root.lastOk = u.fetch_failed !== true
          root.lastOutput = u.fetch_failed === true ? "Could not reach " + (u.origin || "GitHub") + ". Try again later."
                          : u.checkout !== true ? "This copy of Replicant is not a git checkout, so it cannot update itself."
                          : u.available === true ? "Replicant " + u.latest + " is available. Press Update in the header."
                          : "Replicant " + u.current + " is up to date."
        }
      } else if (job === "edit") {
        if (stdoutText.indexOf("replicant:waited") !== -1) root.open()
      } else if (job === "scope") {
        if (code !== 0) {
          root.lastOk = false; root.lastTitle = "Sync"
          root.lastOutput = root.clean("Sync of " + (meta.jobId || "entry") + " failed (exit " + code + ")\n" + stdoutText + "\n" + stderrText)
          root.dropScopeOverride(meta.jobId || "")
        }
        root.runNextScope()
      } else if (job === "bulk") {
        root.finish(meta.label || "Bulk change", code, stdoutText, stderrText)
        if (code === 0) { root.scopeOverrides = ({}); root.clearSelection() }
        else if (String(meta.bulkAction || "").indexOf("scope-") === 0) root.scopeOverrides = ({})
      } else if (job === "doctor") {
        root.busyLabel = ""; root.lastTitle = "Health check"; root.lastOk = text.indexOf("No problems found.") !== -1
        root.lastOutput = text; root.openViewer("Health check", text, "output")
      } else if (job === "copy-path") {
        root.busyLabel = ""
        root.lastTitle = "Copy path"
        root.lastOk = code === 0
        root.lastOutput = code === 0 ? "Copied the path to the clipboard." : "Could not copy the path. Is wl-copy available?"
      } else if (job !== "") {
        root.finish(meta.label || job, code, stdoutText, stderrText)
        if (job === "track") { root.loadSuggestions(); if (root.browseData.dir) root.browseTo(root.browseData.dir) }
      }
    }
  }

  // Terminal-backed flows: these two genuinely need a terminal, because they
  // prompt for a GitHub login / a repo URL. Everything else runs headless.
  function run(cmd) { if (bar) bar.run(cmd) }
  function runVisible(cmd) { root.run("omarchy-launch-floating-terminal-with-presentation " + root.shellQuote(cmd)) }
  function doCreate() { root.runVisible(root.cli + " create --push"); root.close() }
  function doClone()  { root.runVisible(root.cli + " clone"); root.close() }
  function openUrl(url) { root.run("xdg-open " + root.shellQuote(url)); root.close() }
  function openRepoFolder() { root.openUrl(root.repoState.repo_dir || "") }

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
    root.loadDeleted()
    if (!root.updateCheckedOnce) root.checkUpdates(false)
  }
  function close() { root.opened = false; root.viewerOpen = false; root.keyboardHelpOpen = false; confirmDialog.opened = false; root.focusedField = null }
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
  onActiveTabChanged: {
    root.rememberCurrentScroll()
    root.lastScrollTab = root.activeTab
    var y = root.scrollPositions[root.activeTab] || 0
    if (body) body.contentY = Math.max(0, Math.min(y, body.contentHeight - body.height))
    if (!root.restoringNavigation) Qt.callLater(root.restoreNavigation)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(580))
    contentHeight: panel.fittedContentHeight(
      header.implicitHeight + Style.space(10) + body.implicitHeight
        + (footer.visible ? footer.implicitHeight + Style.space(6) : 0)
        + (bulkFooter.visible ? bulkFooter.implicitHeight + Style.space(6) : 0),
      Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.focusedField !== null
      Keys.onPressed: function(event) {
        if (!root.focusedField && root.manageMode && root.activeTab === "configs"
            && event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
          root.selectVisible(); event.accepted = true
        }
        if (!root.focusedField && root.manageMode && root.activeTab === "configs"
            && event.key === Qt.Key_Space && (event.modifiers & Qt.ShiftModifier)
            && root.visibleConfigRows.length > 0) {
          root.toggleSelected(root.visibleConfigRows[root.manageCursor].id, true); event.accepted = true
        }
      }
      onCloseRequested: {
        if (root.keyboardHelpOpen) root.keyboardHelpOpen = false
        else if (root.viewerOpen) root.closeViewer()
        else if (confirmDialog.opened) confirmDialog.opened = false
        else root.close()
      }
      onTextKey: function(t) {
        if (t === "?" && !root.viewerOpen && !confirmDialog.opened) {
          root.keyboardHelpOpen = !root.keyboardHelpOpen; return
        }
        if (root.keyboardHelpOpen) return
        if (root.viewerOpen || confirmDialog.opened) return
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
        // bottom of a long list on purpose, which makes it the one thing in the
        // panel that is a scroll away.
        else if (t === "a") {
          root.activeTab = "configs"
          if (!root.isOpen("__suggest")) root.toggleCard("__suggest")
        }
        else if (t === "m" && root.activeTab === "configs") root.toggleManage()
        else if (t === "j" && root.manageMode) root.moveManageCursor(1)
        else if (t === "k" && root.manageMode) root.moveManageCursor(-1)
        // "/" filters where you already are.
        else if (t === "/") {
          if (root.activeTab === "settings") settingsTab.focusSearch()
          else { root.activeTab = "configs"; configsTab.focusSearch() }
        }
      }
      onMoveRequested: function(dx, dy) {
        root.moveManageCursor(dy)
      }
      onActivateRequested: {
        if (root.manageMode && root.activeTab === "configs" && root.visibleConfigRows.length > 0)
          root.toggleSelected(root.visibleConfigRows[root.manageCursor].id, false)
      }

      // ─────────────────────────────── header (fixed) ────────────────────────
      Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        PanelHeader { panel: root; width: parent.width }

        // One actionable sentence, and only when there is something to act on
        // and the Overview's status card is not already saying it.
        BorderSurface {
          width: parent.width
          visible: root.advice !== "" && root.activeTab !== "overview"
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
        anchors.bottom: bulkFooter.visible ? bulkFooter.top : (footer.visible ? footer.top : parent.bottom)
        anchors.bottomMargin: bulkFooter.visible || footer.visible ? Style.space(6) : 0
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

          OverviewTab { id: overviewTab; panel: root; width: content.width; visible: root.ready && root.activeTab === "overview" }
          ConfigsTab { id: configsTab; panel: root; width: content.width; visible: root.ready && root.activeTab === "configs" }
          SettingsTab { id: settingsTab; panel: root; width: content.width; visible: root.ready && root.activeTab === "settings" }
          RestoreTab { id: restoreTab; panel: root; width: content.width; visible: root.ready && root.activeTab === "restore" }
        }
      }

      // ─────────────────────────────── footer (fixed) ────────────────────────
      ResultBar {
        id: footer
        panel: root
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
      }
      BulkFooter {
        id: bulkFooter
        panel: root
        visible: root.manageMode && root.activeTab === "configs"
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottomMargin: Style.space(6)
      }

      // ─────────────────────────────── overlays ──────────────────────────────
      TextViewer { panel: root; anchors.fill: parent; z: 50 }

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

      BorderSurface {
        id: keyboardHelp
        visible: root.keyboardHelpOpen
        anchors.centerIn: parent
        width: Math.min(parent.width, Style.space(500))
        implicitHeight: helpColumn.implicitHeight + Style.space(24)
        z: 70
        color: Color.popups.background
        borderSpec: Border.controlSpec("focus", root.fg, Color.accent)
        radius: Style.cornerRadius
        Column {
          id: helpColumn
          anchors.fill: parent
          anchors.margins: Style.space(12)
          spacing: Style.space(8)
          Text {
            text: "Keyboard help"
            color: root.fg; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
          }
          Text {
            text: "1-4 tabs   (j) next   (k) previous   arrows move   Enter opens\n"
                  + "m manages   / filters   r refreshes   Esc closes   (?) help"
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
