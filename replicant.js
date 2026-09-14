.pragma library
// Pure functions that the bar, the panel and its components share. No QML
// context reaches a library file, so every input is a parameter. That is what
// lets tests/qml/tst_replicant.qml test them without a running shell.

// Icons are held as Material Design Icon CODE POINTS, never as pasted glyphs.
// Every one of them lives above U+FFFF, where a re-encoding of a file silently
// truncates the character into a different symbol. The name of each icon is in
// a comment beside its code point.
function mdi(cp) { return String.fromCodePoint(cp) }

// "1 file", "4 files". The panel printed "file(s)" eleven times on one screen,
// and the number was always right there next to it.
function plural(n, one, many) { return n + " " + (n === 1 ? one : (many || one + "s")) }

// ── sync states ─────────────────────────────────────────────────────────────
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
  // Not a state of the core: a scope change the panel has sent and the next
  // status has not confirmed yet.
  if (st === "pending") return "…"
  return "◆"
}

// The colour role of a state. The panel maps each role to its own palette.
// "incoming" has a role of its own, and deliberately not the accent that the
// other two "do something" states share: pressing Save on an incoming row is
// the one mistake in this panel that destroys somebody else's work, so its
// badge must not look like the badge that asks for Save.
function stateRole(st) {
  if (st === "incoming") return "warn"
  if (st === "unsaved" || st === "unpushed") return "accent"
  if (st === "saved") return "ok"
  return "dim"
}

function stateWord(st) {
  // "off", the word the scope button, the legend and the card already use.
  // This said "not synced": two words for one state, two tabs apart.
  if (st === "off") return "switched off"
  if (st === "missing") return "not on this machine"
  // Short on purpose. These are printed beside the path on a row that also
  // carries a Save button and sits under a banner that already says "press
  // Save to GitHub", so a longer sentence bought nothing and cost the path its
  // last few characters on exactly the rows that had one worth reading.
  if (st === "incoming") return "newer copy in your repo"
  if (st === "unsaved") return "not saved yet"
  if (st === "unpushed") return "not pushed yet"
  if (st === "default") return "untouched Omarchy default"
  if (st === "pending") return "saving the change…"
  return "saved on GitHub"
}

// ── the header ──────────────────────────────────────────────────────────────
// f: { asked, ready, ahead, behind, incoming, dirty }. The counts come from the
// rows themselves, so the header and the badges answer to one source.
function summary(f) {
  if (!f.asked) return "checking…"
  if (!f.ready) return "not set up yet"
  if (f.ahead > 0 && f.behind > 0) return "diverged"
  if (f.behind > 0) return f.behind + " waiting on GitHub"
  if (f.incoming > 0) return "changes to restore"
  if (f.dirty > 0 || f.ahead > 0) return "unsaved changes"
  return "everything saved"
}

// One sentence telling the user what to do next, or nothing at all when there
// is nothing to do. A banner that is always present stops being read.
function advice(f) {
  if (!f.asked || !f.ready) return ""
  if (f.behind > 0) return "Another machine saved " + plural(f.behind, "change") + " — press Pull to bring them here."
  // Before the unsaved line, and that order is the whole point of the state.
  // Both mean "this file and its copy differ"; only this one knows which way,
  // and pressing Save here commits over what the other machine saved.
  // One line, and it has to fit on one line: the banner elides, and the half
  // that got cut was the half naming the button.
  if (f.incoming > 0) return plural(f.incoming, "file") + " came from another machine — press Restore, not Save."
  if (f.dirty > 0) return plural(f.dirty, "file") + " changed on this machine — press Save to GitHub."
  if (f.ahead > 0) return plural(f.ahead, "commit") + " committed but not pushed — press Save to GitHub."
  return ""
}

// The status card on the Overview tab: one headline, one line under it, and a
// tone. f is the facts of summary() plus { tracked, lastSave } (lastSave is
// the agoText of the newest save, or "").
function headline(f) {
  if (!f.asked) return { title: "Checking this machine…", detail: "", tone: "dim" }
  if (!f.ready) return { title: "No backup repo yet", detail: "", tone: "dim" }
  if (f.ahead > 0 && f.behind > 0)
    return { title: "This machine and GitHub have diverged", detail: "Pull first, then save.", tone: "warn" }
  if (f.behind > 0)
    return { title: plural(f.behind, "change") + " waiting on GitHub",
             detail: "Another machine saved. Pull brings the changes here.", tone: "warn" }
  if (f.incoming > 0)
    return { title: plural(f.incoming, "file") + " came from another machine",
             detail: "Restore puts " + (f.incoming === 1 ? "it" : "them") + " here. Save would overwrite that work.", tone: "warn" }
  if (f.dirty > 0)
    return { title: plural(f.dirty, "file") + " not saved yet",
             detail: "Save to GitHub copies, commits and pushes them.", tone: "accent" }
  if (f.ahead > 0)
    return { title: plural(f.ahead, "commit") + " not pushed yet",
             detail: "Save to GitHub pushes them.", tone: "accent" }
  return { title: "Everything is saved",
           detail: plural(f.tracked || 0, "file") + " backed up" + (f.lastSave ? " · last save " + f.lastSave : ""),
           tone: "ok" }
}

// A list of names for a tooltip: the first few, and how many more there are.
function nameList(names, max) {
  var m = max || 8
  var out = names.slice(0, m).map(function(n) { return "  " + n })
  if (names.length > m) out.push("  +" + (names.length - m) + " more")
  return out.join("\n")
}

// A repo path in the words of the Configs tab. config/x is x, a profile's copy
// says whose it is, and a secret says that it is one.
function repoPathLabel(p) {
  var s = String(p || "")
  var m = s.match(/^profiles\/([^\/]+)\/config\/(.+)$/)
  if (m) return { label: m[2], note: m[1] + " profile" }
  if (s.indexOf("config/") === 0) return { label: s.slice(7), note: "" }
  if (s.indexOf("secrets/") === 0) return { label: s.slice(8), note: "secret" }
  return { label: s, note: "" }
}

// Where the repo keeps a row's copy. repo_path_for is the rule in the core;
// this only says it in words, next to the row.
function repoCopyText(row, scope, profile) {
  if (row.secret) return "secrets/" + row.id
  if (scope === "profile") return "profiles/" + profile + "/config/" + row.id
  return "config/" + row.id
}

// Bytes, the way `ls -h` says them.
function sizeText(b) {
  var n = Number(b) || 0
  if (n < 1024) return n + " B"
  if (n < 1048576) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB"
  return (n / 1048576).toFixed(1) + " MB"
}

// A path the way the CLI prints it: under $HOME it starts with ~.
function prettyPath(p, home) {
  var s = String(p || "")
  if (home && (s === home || s.indexOf(home + "/") === 0)) return "~" + s.slice(home.length)
  return s
}

// The page of a GitHub remote, for "Open on GitHub". Anything else has none.
function webUrl(remote) {
  var r = String(remote || "")
  var m = r.match(/^git@github\.com:(.+?)(\.git)?$/)
  if (m) return "https://github.com/" + m[1]
  m = r.match(/^https:\/\/github\.com\/(.+?)(\.git)?$/)
  if (m) return "https://github.com/" + m[1]
  return ""
}

// The row states that have a button worth pressing. A file gone from this
// machine is one: it asks whether to bring it back or to forget it.
function needsAttention(st) {
  return st === "unsaved" || st === "unpushed" || st === "incoming" || st === "missing"
}

// Which rows a filter keeps: "all", "changed" or "off".
function rowMatchesFilter(row, filter) {
  if (filter === "changed") return needsAttention(row.sync_state)
  if (filter === "off") return row.sync_state === "off"
  return true
}

// Whether a restore would write this row: it is synced, the repo holds a copy,
// and the copy differs from what is here, or nothing is here.
function wouldRestore(row) {
  if (row.synced === false || row.saved !== true) return false
  return row.sync_state === "unsaved" || row.sync_state === "incoming" || row.sync_state === "missing"
}

// The scope a row shows. A change the user just made wins until a status that
// was built after the change arrives.
function effectiveScope(row, overrides) {
  var o = overrides ? overrides[row.id] : undefined
  return o ? o : (row.scope || "shared")
}

// The state a row shows while its scope change is in flight. Switched off is
// known at once. Switched on is not: the copy may differ, so it says pending.
function displayState(row, overrides) {
  var o = overrides ? overrides[row.id] : undefined
  if (!o || o === (row.scope || "shared")) return row.sync_state
  if (o === "off") return "off"
  return row.sync_state === "off" ? "pending" : row.sync_state
}

// ── rows ────────────────────────────────────────────────────────────────────
// Secrets live in their own part of the payload because they carry different
// facts (mode, kind, the NAMES of the variables and never their values), but
// the panel shows them in the same list as everything else in their area.
function secretRows(repoState) {
  var out = []
  var list = repoState.secrets || []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    out.push({
      id: s.id, label: s.id, src: s.src, category: "secrets",
      sync_state: s.sync_state, exists: s.exists, has_default: false, saved: s.saved === true,
      synced: s.synced, scope: s.synced === false ? "off" : "shared",
      source: s.source || "manifest", is_dir: false, nfiles: 0,
      secret: true, kind: s.kind, mode: s.mode,
      vars: s.vars || [], var_count: s.var_count || 0
    })
  }
  return out
}

// The rows of one area in one uniform shape, secrets included, filtered by
// the search text and the state filter (rowMatchesFilter), and sorted by label.
function rowsFor(repoState, categoryId, search, filter) {
  var out = []
  var list = repoState.configs || []
  var needle = String(search || "").toLowerCase()
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if ((c.category || "other") !== categoryId) continue
    out.push({
      id: c.id, label: c.label, src: c.src, category: c.category,
      sync_state: c.sync_state, exists: c.exists, has_default: c.has_default, saved: c.saved === true,
      is_default: c.is_default === true, synced: c.synced, scope: c.scope || "shared",
      source: c.source || "manifest", is_dir: c.is_dir === true, nfiles: c.nfiles || 0,
      secret: false, kind: "", mode: "", vars: [], var_count: 0
    })
  }
  if (categoryId === "secrets") out = out.concat(secretRows(repoState))
  if (needle !== "") {
    out = out.filter(function(r) {
      return (String(r.label) + " " + String(r.src)).toLowerCase().indexOf(needle) !== -1
    })
  }
  if (filter && filter !== "all") out = out.filter(function(r) { return rowMatchesFilter(r, filter) })
  out.sort(function(a, b) { return String(a.label).localeCompare(String(b.label)) })
  return out
}

// ── plugins ─────────────────────────────────────────────────────────────────
// An origin the way a person reads it: no scheme, no .git, no trailing slash.
function originLabel(origin) {
  var s = String(origin || "").replace(/^[a-z+]+:\/\//, "").replace(/^git@([^:]+):/, "$1/")
  return s.replace(/\.git$/, "").replace(/\/$/, "")
}

// Every plugin of the payload, with where its settings live. A plugin that
// keeps its own file (~/.config/omarchy/<last segment of the id>.json) has a
// row in the Plugins card. A bar widget keeps its settings in its entry in
// shell.json, which the Desktop & bar area saves. Some plugins have neither.
function pluginRows(repoState) {
  var rows = ({})
  var list = repoState.configs || []
  for (var i = 0; i < list.length; i++) rows[list[i].id] = true
  return (repoState.plugins || []).map(function(p) {
    var fileId = "plugins/" + String(p.id).split(".").pop() + ".json"
    var where = rows[fileId] ? "file" : p.in_bar === true ? "bar" : "none"
    return { id: p.id, name: p.name || p.id, version: p.version || "", installed: p.installed === true,
             origin: p.origin || "", method: p.method || "", recorded: p.recorded === true,
             settings: where, settingsId: where === "file" ? fileId : "" }
  })
}

// The words on the right of a plugin's row: where its settings are.
function pluginWhere(p) {
  if (!p.installed) return "not installed here"
  if (p.settings === "file") return "own settings file"
  if (p.settings === "bar") return "settings in shell.json"
  return "no settings"
}

// The line under a plugin's name: its version and where it comes from, as the
// repo records it. A plugin installed after the last save is not recorded yet.
function pluginDetail(p) {
  var v = p.version !== "" ? "v" + p.version + "  ·  " : ""
  if (p.installed && !p.recorded) return v + "not in your repo yet: the next save records it"
  if (p.origin === "") return v + "no origin: nothing can install it again"
  if (p.method === "clone") return v + "a copy of " + p.origin + ", edited here"
  return v + originLabel(p.origin)
}

// ── the reader and the result bar ───────────────────────────────────────────
// How the reader colours one line. "diff" is a unified diff. "output" is what a
// command printed, with the marks the CLI draws: ✓ done, ✗ failed, ! a warning,
// · skipped, » what a dry run would run.
function lineRole(line, kind) {
  var s = String(line || "")
  if (kind === "diff") {
    if (s.indexOf("+++") === 0 || s.indexOf("---") === 0) return "dim"
    var c = s.charAt(0)
    if (c === "+") return "add"
    if (c === "-") return "del"
    if (c === "@") return "hunk"
    if (c === "#") return "dim"
    return "fg"
  }
  var t = s.replace(/^\s+/, "")
  var indented = t !== s
  if (t.indexOf("==") === 0 || t.indexOf("──") === 0) return "head"
  // A section of `doctor`: one word or two, at the start of the line.
  if (!indented && /^[A-Z][A-Za-z ]{1,20}$/.test(t)) return "head"
  var m = t.charAt(0)
  if (m === "✓") return "ok"
  if (m === "✗" || / failed/.test(t)) return "bad"
  if (m === "!") return "warn"
  if (m === "·") return "dim"
  if (m === "»" || m === "→") return "accent"
  if (t.indexOf("@@") === 0) return "hunk"
  // The diff lines of a restore preview are indented under their file.
  if (indented && m === "+") return "add"
  if (indented && m === "-" && t.charAt(1) !== "-") return "del"
  return "fg"
}

// The one line the result bar shows. When a command worked, the last thing it
// said. When it failed, the first line (which names the action) and the last
// (which says why). The marks go, because the bar draws its own.
function resultLine(text, ok) {
  var lines = String(text || "").split("\n")
    .map(function(l) { return l.replace(/^[\s✓✗·!→»]+/, "").trim() })
    .filter(function(l) { return l !== "" })
  if (lines.length === 0) return ""
  if (ok || lines.length === 1) return lines[lines.length - 1]
  return lines[0] + ": " + lines[lines.length - 1]
}

// ── the safety net ──────────────────────────────────────────────────────────
// Newest per id: undo takes the newest, so a row per id is a row per button.
// The rest are counted, never listed: twelve rows of the same file is a wall,
// and only one of them is reachable. `backups` comes newest first.
function backupRows(backups) {
  var seen = ({}), out = []
  for (var i = 0; i < backups.length; i++) {
    var b = backups[i]
    if (seen[b.id]) { out[seen[b.id] - 1].older += 1; continue }
    seen[b.id] = out.push({ id: b.id, path: b.path, epoch: b.epoch,
                            state: b.state, older: 0 })
  }
  return out
}

// A backup's age in the words a person uses about one. The epoch is in the
// filename and says nothing; "3 days ago" is the whole question being asked.
// `now` is in seconds and exists for the tests.
function agoText(epoch, now) {
  var t = now === undefined ? Math.floor(Date.now() / 1000) : now
  var s = Math.max(0, t - epoch)
  if (s < 90) return "just now"
  if (s < 5400) return plural(Math.round(s / 60), "minute") + " ago"
  if (s < 129600) return plural(Math.round(s / 3600), "hour") + " ago"
  return plural(Math.round(s / 86400), "day") + " ago"
}
