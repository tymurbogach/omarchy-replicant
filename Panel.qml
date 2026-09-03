import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Replicant panel: four tabs over one CLI.
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
  manageIpc: false

  property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-replicant"
  property string cliFallback: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant"
  property var repoState: ({ initialized: false, configs: [], secrets: [], settings: [] })
  // True once a real status response has come back at least once. Gates the
  // "no repo yet — create one" screen: showing it before we know the state let
  // a stray click re-point an already-configured remote (a real incident).
  property bool asked: false

  property string lastOutput: ""
  property string activeTab: "overview"
  property string fileFilter: "all"
  property string fileSearch: ""
  property var recent: []

  // ── in-flight state ───────────────────────────────────────────────────────
  readonly property bool busy: saveProc.running || setProc.running || pullProc.running
                            || backupProc.running || fileSaveProc.running || dangerProc.running
  property string busyLabel: ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color okColor: "#4caf50"
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property string mono: "monospace"

  readonly property bool ready: !!(repoState && repoState.initialized === true)

  // ── derived summaries ─────────────────────────────────────────────────────
  readonly property int nDirty: repoState.dirty || 0
  readonly property int nAhead: repoState.ahead || 0
  readonly property int nBehind: repoState.behind || 0

  readonly property string summary: {
    if (!root.asked) return "checking…"
    if (!root.ready) return "not set up yet"
    if (root.nAhead > 0 && root.nBehind > 0) return "diverged ↑" + root.nAhead + " ↓" + root.nBehind
    if (root.nBehind > 0) return root.nBehind + " waiting on GitHub"
    if (root.nDirty > 0 || root.nAhead > 0) return "unsaved changes"
    return "everything saved"
  }

  // One sentence telling the user what to do next, or nothing at all when
  // there is nothing to do. A banner that is always present stops being read.
  readonly property string advice: {
    if (!root.asked || !root.ready) return ""
    if (root.nBehind > 0) return "Another machine saved " + root.nBehind + " change(s) — press Pull to bring them here."
    if (root.nDirty > 0) return root.nDirty + " file(s) changed on this machine — press Save to GitHub."
    if (root.nAhead > 0) return root.nAhead + " commit(s) committed but not pushed — press Save to GitHub."
    return ""
  }

  readonly property var tabs: [
    { value: "overview", label: "Overview", icon: "󰸞", tooltip: "State of this machine and what to do next" },
    { value: "settings", label: "Settings", icon: "󰒓", tooltip: "Change a value and it is written and saved" },
    { value: "files",    label: "Files",    icon: "󰈔", tooltip: "Every file being backed up" },
    { value: "restore",  label: "Restore",  icon: "󰦛", tooltip: "Bring a whole machine back" }
  ]

  // ── config list, grouped ──────────────────────────────────────────────────
  readonly property var groupOrder: ["shell","git/ssh","claude","dev","hypr","session","omarchy","appearance","terminal","plugins","scripts","branding","system","replicant","other"]
  readonly property var visibleConfigs: {
    var arr = (root.repoState.configs || []).slice()
    var needle = root.fileSearch.toLowerCase()
    var filter = root.fileFilter
    arr = arr.filter(function(c) {
      if (filter === "changed" && c.sync_state !== "modified") return false
      if (filter === "saved" && c.sync_state !== "saved") return false
      if (filter === "default" && c.sync_state !== "default") return false
      if (needle !== "") {
        var hay = (String(c.label || "") + " " + String(c.src || "") + " " + String(c.group || "")).toLowerCase()
        if (hay.indexOf(needle) === -1) return false
      }
      return true
    })
    var order = root.groupOrder
    arr.sort(function(a, b) {
      var ra = order.indexOf(a.group || "other"); if (ra === -1) ra = order.length
      var rb = order.indexOf(b.group || "other"); if (rb === -1) rb = order.length
      if (ra !== rb) return ra - rb
      return String(a.label).localeCompare(String(b.label))
    })
    return arr
  }
  readonly property int countChanged: (root.repoState.configs || []).filter(function(c){ return c.sync_state === "modified" }).length

  // ── settings, grouped in registry order ───────────────────────────────────
  readonly property var settingGroups: {
    var out = []
    var seen = ({})
    var list = root.repoState.settings || []
    for (var i = 0; i < list.length; i++) {
      var g = list[i].group || "Other"
      if (seen[g] === undefined) { seen[g] = out.length; out.push({ name: g, items: [] }) }
      out[seen[g]].items.push(list[i])
    }
    return out
  }

  // ── actions ───────────────────────────────────────────────────────────────
  function refresh() { if (hostWidget) hostWidget.refresh(true); logProc.running = true }
  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  function doSavegame() { root.busyLabel = "Saving to GitHub…"; saveProc.command = [root.cli, "savegame"]; saveProc.running = true }
  function doPull()     { root.busyLabel = "Pulling…";          pullProc.command = [root.cli, "pull", "-y"]; pullProc.running = true }
  function doBackup()   { root.busyLabel = "Copying files…";    backupProc.command = [root.cli, "backup"]; backupProc.running = true }
  function doDoctor()   { root.busyLabel = "Checking…";         root.lastOutput = "Running health check…"; doctorProc.command = [root.cli, "doctor"]; doctorProc.running = true }

  // Open the editor. Deliberately NOT through
  // omarchy-launch-floating-terminal-with-presentation: that wraps the command
  // in the Omarchy logo plus a "press a key to close" prompt, so reading one
  // file cost two extra interactions. The CLI detaches the editor itself.
  function doEdit(id) {
    editProc.command = [root.cli, "edit", id]
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
    root.lastOutput = id + " → " + value
    setProc.command = [root.cli, "set", id, String(value)]
    setProc.running = true
  }

  // Controls that emit a burst of values (holding a stepper, dragging a
  // slider) would otherwise be one commit and push per intermediate value.
  property string pendingSettingId: ""
  property string pendingSettingValue: ""
  function queueSetting(id, value) {
    root.pendingSettingId = id
    root.pendingSettingValue = String(value)
    root.lastOutput = id + " → " + value + "  (saving in a moment…)"
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
    if (a === "reset-file")       { root.busyLabel = "Resetting " + arg + "…"; dangerProc.command = [root.cli, "reset", arg] }
    else if (a === "reset-all")   { root.busyLabel = "Resetting everything…"; dangerProc.command = [root.cli, "reset-all", "--apply", "--yes"] }
    else if (a === "restore-all") { root.busyLabel = "Restoring everything…"; dangerProc.command = [root.cli, "restore", "--apply", "--all", "--yes"] }
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
    var text = (String(out || "") + "\n" + String(err || "")).replace(/\n{3,}/g, "\n\n").trim()
    if (code !== 0) text = label + " failed (exit " + code + ")\n" + text
    root.lastOutput = text.length > 1400 ? "…" + text.slice(-1400) : text
    root.refresh()
  }

  CliProcess { id: saveProc;     onExited: function(c){ root.finish("Save", c, saveProc.stdout.text, saveProc.stderr.text) } }
  CliProcess { id: pullProc;     onExited: function(c){ root.finish("Pull", c, pullProc.stdout.text, pullProc.stderr.text) } }
  CliProcess { id: backupProc;   onExited: function(c){ root.finish("Copy", c, backupProc.stdout.text, backupProc.stderr.text) } }
  CliProcess { id: setProc;      onExited: function(c){ root.finish("Set", c, setProc.stdout.text, setProc.stderr.text) } }
  CliProcess { id: fileSaveProc; onExited: function(c){ root.finish("Save file", c, fileSaveProc.stdout.text, fileSaveProc.stderr.text) } }
  CliProcess { id: dangerProc;   onExited: function(c){ root.finish("Restore", c, dangerProc.stdout.text, dangerProc.stderr.text) } }
  CliProcess { id: doctorProc;   onExited: function(c){ root.busyLabel = ""; root.lastOutput = (doctorProc.stdout.text + "\n" + doctorProc.stderr.text).replace(/\[[0-9;]*m/g, "").trim() } }
  Process { id: editProc }

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
  function open() { root.opened = true; root.refresh() }
  function close() { root.opened = false; root.diffOpen = false; confirmDialog.opened = false }
  function toggle() { root.opened ? root.close() : root.open() }

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
        else if (t === "2") root.activeTab = "settings"
        else if (t === "3") root.activeTab = "files"
        else if (t === "4") root.activeTab = "restore"
        else if (t === "r") root.refresh()
        else if (t === "s" && root.ready && !root.busy) root.doSavegame()
        else if (t === "/") { root.activeTab = "files"; searchField.forceActiveFocus() }
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
          title: "Omarchy Replicant"
          meta: root.repoState.remote_name
                ? (root.repoState.remote_name + " · " + root.summary)
                : root.summary
          foreground: root.fg
          fontFamily: root.ff
          iconComponent: Component {
            Text { text: "󰸞"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.display }
          }
          trailingControl: Component {
            Button {
              iconText: "⟳"
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
                text: "Create private repo"; iconText: "󰘐"; bordered: true
                foreground: root.fg; accent: Color.accent; fontFamily: root.ff
                tooltipText: "Creates <hostname>-replicant on your GitHub account, private, and pushes this machine into it"
                onClicked: root.doCreate()
              }
              Button {
                text: "Clone existing…"; iconText: "󰓹"; bordered: true
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
              StatCard { label: "tracked files"; value: String((root.repoState.configs || []).length) }
              StatCard { label: "changed here";  value: String(root.countChanged); highlight: root.countChanged > 0 }
              StatCard { label: "to pull";       value: String(root.nBehind);      highlight: root.nBehind > 0 }
              StatCard { label: "settings";      value: String((root.repoState.settings || []).length) }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Button {
                text: "Save to GitHub"; iconText: "󰆓"; bordered: true
                foreground: root.fg; accent: Color.accent; fontFamily: root.ff
                iconSpinning: saveProc.running
                enabled: root.ready && !root.busy
                tooltipText: "Copy this machine into the repo, commit and push  (s)"
                onClicked: root.doSavegame()
              }
              Button {
                text: "Pull"; iconText: "↓"; bordered: root.nBehind > 0
                foreground: root.nBehind > 0 ? Color.accent : root.fg; accent: Color.accent; fontFamily: root.ff
                iconSpinning: pullProc.running
                enabled: root.ready && !root.busy
                tooltipText: "Bring down what another machine saved"
                onClicked: root.doPull()
              }
              Button {
                text: "Copy files only"; bordered: false
                foreground: root.fg; fontFamily: root.ff
                enabled: !root.busy
                tooltipText: "Refresh the local copy without committing or pushing"
                onClicked: root.doBackup()
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
                  implicitHeight: Style.space(22)
                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)
                    Text {
                      width: Style.space(96)
                      text: recentRow.modelData.date
                      color: root.dim; font.family: root.mono; font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: parent.width - Style.space(106)
                      text: recentRow.modelData.subject
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
                text: "Health check"; iconText: "󰸞"; bordered: false
                foreground: root.fg; fontFamily: root.ff
                enabled: !doctorProc.running
                tooltipText: "Verify login, that the repo is private, hooks and permissions"
                onClicked: root.doDoctor()
              }
              Button {
                text: "Open repo folder"; iconText: "󰉋"; bordered: false
                foreground: root.fg; fontFamily: root.ff
                tooltipText: root.repoState.repo_dir || ""
                onClicked: { root.run("xdg-open " + root.shellQuote(root.repoState.repo_dir || "")); root.close() }
              }
            }
          }

          // ══════════════ Settings ══════════════
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.ready && root.activeTab === "settings"

            Text {
              width: parent.width
              text: "Change a value here and Replicant writes it to the real config file, applies it, and commits it to your repo."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.settingGroups
              delegate: Column {
                id: settingGroup
                required property var modelData
                width: content.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  width: parent.width
                  text: settingGroup.modelData.name
                  foreground: root.fg
                  fontFamily: root.ff
                }

                Repeater {
                  model: settingGroup.modelData.items
                  delegate: SettingRow {
                    required property var modelData
                    setting: modelData
                    width: settingGroup.width
                  }
                }
              }
            }
          }

          // ══════════════ Files ══════════════
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.ready && root.activeTab === "files"

            Row {
              width: parent.width
              spacing: Style.space(8)
              TextField {
                id: searchField
                width: parent.width - filterChips.width - Style.space(8)
                placeholderText: "Filter by name or path…   (/)"
                foreground: root.fg
                accent: Color.accent
                font.family: root.ff
                onTextChanged: root.fileSearch = text
                Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
              }
              ButtonGroup {
                id: filterChips
                options: [
                  { value: "all",     label: "All" },
                  { value: "changed", label: "Changed" },
                  { value: "saved",   label: "Saved" },
                  { value: "default", label: "Default" }
                ]
                value: root.fileFilter
                foreground: root.fg
                accent: Color.accent
                fontFamily: root.ff
                focusable: false
                onChanged: function(v) { root.fileFilter = v }
              }
            }

            Text {
              width: parent.width
              text: "○ untouched Omarchy default   ●  changed here, not saved yet   ◆ saved on GitHub"
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.visibleConfigs.length === 0
              text: "Nothing matches that filter."
              color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
            }

            // A ListView (not Column + nested Repeaters) — that nesting caused a
            // real QQuickItem::polish() loop here; section.property gives the
            // per-group headers without a second Repeater level. Non-interactive
            // so it never fights the panel's own scroll for the wheel.
            ListView {
              width: parent.width
              height: contentHeight
              interactive: false
              clip: false
              spacing: Style.space(6)
              model: root.visibleConfigs
              section.property: "group"
              section.criteria: ViewSection.FullString
              section.delegate: PanelSectionHeader {
                required property string section
                width: ListView.view.width
                text: section
                foreground: root.fg
                fontFamily: root.ff
              }
              delegate: FileRow {
                required property var modelData
                config: modelData
                width: ListView.view.width
              }
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
              body: "Brings every config, secret and setting saved in your repo down onto this machine. This is how you set up a second machine, or undo a bad day."
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
              body: "Throws away your changes to every file Omarchy ships a default for and puts the factory version back. Your repo is not touched, so you can restore from it afterwards."
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
            iconText: "󰅖"; bordered: false; foreground: root.dim; fontFamily: root.ff
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

  component StatCard: BorderSurface {
    id: statCard
    property string label: ""
    property string value: ""
    property bool highlight: false
    // Explicit width: a Row gives its children no width, and a BorderSurface
    // with no width renders at zero — the cards were simply invisible.
    width: (parent.width - Style.space(24)) / 4
    implicitHeight: Style.space(46)
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec(statCard.highlight ? "focus" : "normal", root.fg, Color.accent)
    Column {
      anchors.centerIn: parent
      spacing: 0
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: statCard.value
        color: statCard.highlight ? Color.accent : root.fg
        font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: statCard.label
        color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
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
          text: "Preview"; iconText: "≠"; bordered: false
          foreground: root.fg; fontFamily: root.ff
          enabled: !root.busy
          tooltipText: "Shows what would change and writes nothing"
          onClicked: card.preview()
        }
        Button {
          text: card.actionText; iconText: "󰦛"; bordered: true
          foreground: root.fg; accent: card.actionAccent ? Color.accent : Color.urgent; fontFamily: root.ff
          enabled: !root.busy
          onClicked: card.act()
        }
      }
    }
  }

  component SettingRow: BorderSurface {
    id: srow
    property var setting: ({})
    readonly property bool isNumber: setting.type === "number" || setting.type === "toml-int" || setting.type === "lua-int"
    readonly property bool isFloat:  setting.type === "toml-float"
    readonly property bool isBool:   setting.type === "bool" || setting.type === "lua-bool"
    readonly property bool isChoice: setting.type === "enum" || setting.type === "lua-enum"
                                  || setting.type === "line-enum" || setting.type === "theme"
    readonly property bool isLongList: srow.isChoice && (setting.options || []).length > 8
    readonly property bool usable: setting.available === true && !root.busy

    // Fixed height on purpose. Deriving it from the children while the inner
    // Row is verticalCenter-anchored to this same item is a parent-height <->
    // child-position feedback loop; the row then renders at zero height.
    implicitHeight: Style.space(56)
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
    opacity: srow.setting.available === true ? 1.0 : 0.45

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.spacing.rowPaddingX

      Column {
        width: parent.width - controlSlot.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: srow.setting.label + (srow.setting.implicit === true ? "   (default)" : "")
          color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: srow.setting.available === true
                ? String(srow.setting.hint || "")
                : "not present in this machine's config"
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // One control per type. Every control is instantiated on every row, so
      // each binding has to stay type-safe even on rows it is not used for —
      // an enum's string value assigned to NumberField.value is a runtime error.
      Item {
        id: controlSlot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(170)
        height: Style.space(32)

        NumberField {
          visible: srow.isNumber
          enabled: srow.usable
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          foreground: root.fg
          fontFamily: root.ff
          from: srow.isNumber && typeof srow.setting.min === "number" ? srow.setting.min : 0
          to: srow.isNumber && typeof srow.setting.max === "number" ? srow.setting.max : 999999
          stepSize: srow.setting.unit === "s" ? 30 : 1
          value: srow.isNumber && typeof srow.setting.value === "number" ? srow.setting.value : 0
          onModified: function(v) { if (srow.usable) root.queueSetting(srow.setting.id, v) }
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
            width: Style.space(120)
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
    }
  }

  component FileRow: BorderSurface {
    id: frow
    property var config: ({})
    readonly property string syncState: frow.config.sync_state || "modified"
    readonly property bool isDefault: frow.syncState === "default"
    readonly property bool isModified: frow.syncState === "modified"
    readonly property bool missing: frow.config.exists === false

    implicitHeight: Style.space(56)
    radius: Style.cornerRadius
    color: frow.isModified ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
                           : Style.controlFill(false, false, root.fg, Color.accent)
    borderSpec: Border.controlSpec(frow.isModified ? "focus" : "normal", root.fg, Color.accent)

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
        text: frow.missing ? "·" : frow.isDefault ? "○" : frow.isModified ? "●" : "◆"
        color: frow.missing ? root.dim
             : frow.isDefault ? root.dim
             : frow.isModified ? Color.accent : root.okColor
        font.family: root.ff; font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        width: parent.width - Style.space(14) - actions.width - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs
        Text {
          width: parent.width
          text: frow.config.label
          color: frow.missing ? root.dim : root.fg
          font.family: root.ff; font.pixelSize: Style.font.subtitle; font.bold: frow.isModified
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: frow.missing ? (frow.config.src + "  — not on this machine") : frow.config.src
          color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Row {
        id: actions
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Button {
          iconText: "󰏫"; bordered: false; foreground: root.fg; fontFamily: root.ff
          enabled: !frow.missing
          tooltipText: "Open in your editor"
          onClicked: root.doEdit(frow.config.id)
        }
        Button {
          iconText: "≠"; bordered: false; foreground: root.fg; fontFamily: root.ff
          enabled: !frow.missing
          tooltipText: "Show what changed"
          onClicked: root.doDiff(frow.config.id)
        }
        Button {
          iconText: "󰆓"; bordered: false
          foreground: frow.isModified ? Color.accent : root.dim; fontFamily: root.ff
          enabled: !frow.missing && frow.isModified && !root.busy
          tooltipText: frow.isModified ? "Commit and push just this file" : "Already saved"
          onClicked: root.doSaveFile(frow.config.id)
        }
        Button {
          iconText: "󰦛"; bordered: false; foreground: root.dim; fontFamily: root.ff
          // Only offered where there is a factory version to go back to.
          enabled: !frow.missing && frow.config.has_default === true && !frow.isDefault && !root.busy
          tooltipText: frow.config.has_default === true
                       ? "Put Omarchy's default back (keeps a .bak copy)"
                       : "Omarchy ships no default for this file"
          onClicked: root.ask("reset-file", frow.config.id,
                              "Replace " + frow.config.label + " with Omarchy's default?\n\nYour current version is kept as .bak.<epoch>.",
                              "Reset")
        }
      }
    }
  }
}
