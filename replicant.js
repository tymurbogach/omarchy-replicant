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
      sync_state: s.sync_state, exists: s.exists, has_default: false,
      synced: s.synced, scope: s.synced === false ? "off" : "shared",
      source: s.source || "manifest", is_dir: false, nfiles: 0,
      secret: true, kind: s.kind, mode: s.mode,
      vars: s.vars || [], var_count: s.var_count || 0
    })
  }
  return out
}

// The rows of one area in one uniform shape, secrets included, filtered by
// the search text and sorted by label.
function rowsFor(repoState, categoryId, search) {
  var out = []
  var list = repoState.configs || []
  var needle = String(search || "").toLowerCase()
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
  if (categoryId === "secrets") out = out.concat(secretRows(repoState))
  if (needle !== "") {
    out = out.filter(function(r) {
      return (String(r.label) + " " + String(r.src)).toLowerCase().indexOf(needle) !== -1
    })
  }
  out.sort(function(a, b) { return String(a.label).localeCompare(String(b.label)) })
  return out
}

// Three scopes, cycled in the order a person actually reasons about them:
// "everyone gets this" -> "each kind of machine gets its own" -> "nobody".
function nextScope(scope, allowProfile) {
  if (scope === "off") return "shared"
  if (scope === "shared") return allowProfile ? "profile" : "off"
  return "off"
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
