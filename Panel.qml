import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.tymurbogach.omarchy-replicant"
  manageIpc: false

  property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-replicant"
  property string cliFallback: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.tymurbogach.omarchy-replicant/bin/omarchy-replicant"
  property var state: ({ initialized: false, configs: [], secrets: [] })
  property string lastOutput: ""
  property string busyId: ""
  Component.onCompleted: console.log("replicant Panel loaded, state initialized:", state.initialized)
  onStateChanged: console.log("replicant Panel state changed:", state.initialized, state.configs ? state.configs.length : 0, "pending:", state.pending)

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  function effectiveCli() { return cli }
  function run(cmd) { if (bar) bar.run(cmd) }
  function runVisible(cmd) { run("omarchy-launch-floating-terminal-with-presentation '" + cmd.replace(/'/g, "'\\''") + "'") }

  function doPush() { lastOutput = "push…"; pushProc.command = [effectiveCli(), "push", "-y"]; pushProc.running = true }
  function doPull() { lastOutput = "pull…"; pullProc.command = [effectiveCli(), "pull", "-y"]; pullProc.running = true }
  function doStatus() { lastOutput = "status…"; statusProc.command = [effectiveCli(), "status"]; statusProc.running = true }
  function doCloneInTerminal() { runVisible(effectiveCli() + " clone"); root.close() }
  function doCreateInTerminal() { runVisible(effectiveCli() + " create --push"); root.close() }
  function doSavegame() { lastOutput = "savegame…"; saveProc.command = [effectiveCli(), "savegame"]; saveProc.running = true }
  function doBackup() { lastOutput = "backup…"; backupProc.command = [effectiveCli(), "backup"]; backupProc.running = true }
  function doRestoreDry() { runVisible(effectiveCli() + " restore --dry-run") }
  function doEdit(id) {
    // lanza editor en terminal flotante para que no bloquee el panel
    busyId = id
    runVisible(effectiveCli() + " edit '" + id.replace(/'/g, "'\\''") + "'")
    // refresh tras un momento
    Qt.callLater(function(){ refreshTimer.restart() })
  }
  function doDiff(id) {
    runVisible(effectiveCli() + " diff '" + id.replace(/'/g, "'\\''") + "'")
  }
  function doReset(id) {
    runVisible(effectiveCli() + " reset '" + id.replace(/'/g, "'\\''") + "'")
  }

  // agrupación por group para la lista editable
  readonly property var grouped: {
    var m = {}
    var arr = state.configs || []
    for (var i=0;i<arr.length;i++) {
      var e = arr[i]
      var g = e.group || "otros"
      if (!m[g]) m[g] = []
      m[g].push(e)
    }
    var order = ["shell","git/ssh","claude","dev","hypr","sesión","omarchy","terminal","scripts","branding","sistema","replicant","otros"]
    var out = []
    for (var oi=0; oi<order.length; oi++) if (m[order[oi]]) out.push({group: order[oi], items: m[order[oi]]})
    for (var k in m) if (order.indexOf(k)===-1) out.push({group:k, items:m[k]})
    return out
  }
  onGroupedChanged: console.log("replicant grouped", grouped.length, "configs", state.configs ? state.configs.length : 0)

  readonly property string summary: {
    if (!state.initialized) return "No inicializado"
    if ((state.ahead || 0) > 0 && (state.behind || 0) > 0) return "Divergido ↑" + state.ahead + " ↓" + state.behind
    if ((state.ahead || 0) > 0) return "↑ " + state.ahead + " por pushear"
    if ((state.behind || 0) > 0) return "↓ " + state.behind + " por bajar"
    if ((state.dirty || 0) > 0) return "● " + state.dirty + " modificados"
    return "✓ sincronizado"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  Item { id: button; implicitWidth: 0; implicitHeight: 0 }

  Timer { id: refreshTimer; interval: 1500; onTriggered: if (hostWidget) hostWidget.refresh() }

  Process {
    id: pushProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-800); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = text.slice(-800) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="push falló ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }
  Process {
    id: pullProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-800); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = text.slice(-800) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="pull falló ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = text.slice(-800) }
    }
  }
  Process {
    id: saveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200); if (hostWidget) hostWidget.refresh() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = (root.lastOutput + "\n" + text).slice(-1200) }
    }
    onExited: function(code){ if(code!==0) root.lastOutput="savegame falló ("+code+")\n"+root.lastOutput; if(hostWidget) hostWidget.refresh() }
  }
  Process {
    id: backupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.lastOutput = text.slice(-1200) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.lastOutput = (root.lastOutput + "\n" + text).slice(-1200) }
    }
  }

  property var bar
  property var anchorItem
  property var hostWidget
  property bool opened: false
  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: col
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Omarchy Replicant"
          meta: root.summary
          foreground: root.fg
          fontFamily: root.ff
          iconComponent: Component { Text { text: "󰸞"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.display } }
        }
        Text { width: parent.width; text: state.remote ? state.remote : "sin remote"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; elide: Text.ElideMiddle }
        Text { width: parent.width; text: "branch: " + (state.branch || "main") + "   dirty: " + (state.dirty || 0) + "   ahead/behind: " + (state.ahead||0) + "/" + (state.behind||0); color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        Text { width: parent.width; visible: !!(state.pending && String(state.pending).trim() !== ""); text: "pendientes:" + (state.pending || ""); color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption }

        Row {
          width: parent.width; spacing: Style.space(8)
          Button { text: "Savegame"; iconText: "󰆓"; bordered: true; foreground: root.fg; accent: Color.accent; fontFamily: root.ff; enabled: !!(state && state.initialized === true); tooltipText: "backup + commit state auto + push"; onClicked: root.doSavegame() }
          Button { text: "Backup"; iconText: "󰃨"; bordered: false; foreground: root.fg; fontFamily: root.ff; onClicked: root.doBackup() }
          Button { text: "Status"; iconText: "󰦒"; bordered: false; foreground: root.fg; fontFamily: root.ff; onClicked: root.doStatus() }
        }
        Row {
          width: parent.width; spacing: Style.space(8)
          Button { text: "Push"; iconText: "󰸝"; bordered: false; foreground: root.fg; fontFamily: root.ff; enabled: !!(state && state.initialized === true); onClicked: root.doPush() }
          Button { text: "Pull"; iconText: "󰸜"; bordered: false; foreground: root.fg; fontFamily: root.ff; enabled: !!(state && state.initialized === true); onClicked: root.doPull() }
          Button { text: "Restore dry"; iconText: "󰦛"; bordered: false; foreground: root.fg; fontFamily: root.ff; onClicked: root.doRestoreDry() }
        }

        Column {
          width: parent.width; spacing: Style.space(6); visible: !(state && state.initialized)
          Text { width: parent.width; text: "No hay repo local. Crea uno privado o clona el existente (todo: config+secrets+state)."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
          Row { spacing: Style.space(8)
            Button { text: "Create privado"; iconText: "󰘐"; bordered: true; foreground: root.fg; accent: Color.accent; fontFamily: root.ff; onClicked: root.doCreateInTerminal() }
            Button { text: "Clone…"; iconText: "󰓹"; bordered: true; foreground: root.fg; fontFamily: root.ff; onClicked: root.doCloneInTerminal() }
          }
        }

        // ——— Lista editable por configuración ———
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !!(state && state.initialized && state.configs && state.configs.length > 0)

          PanelSeparator { width: parent.width }

          Text {
            width: parent.width
            text: "Configuraciones (" + (state.configs ? state.configs.length : 0) + ") — distintivo: por defecto vs personalizado"
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            text: "Editar abre el fichero en tu editor. 'por defecto' = idéntico a /usr/share/omarchy (se recupera con omarchy refresh)."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Scroll para las 37 filas — Flickable fijo 420 para que no colapse a 0
          Flickable {
            width: parent.width
            height: 420
            contentHeight: groupedCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onHeightChanged: console.log("replicant Flickable height", height, "content", contentHeight, "grouped", root.grouped ? root.grouped.length : 0)
            Column {
              id: groupedCol
              width: parent.width
              spacing: Style.space(8)
              onImplicitHeightChanged: console.log("replicant groupedCol height", implicitHeight)
              Repeater {
                model: root.grouped
                delegate: Column {
                  required property var modelData
                  anchors.left: parent.left
                  anchors.right: parent.right
                  spacing: Style.space(6)

                  PanelSectionHeader {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    text: modelData.group
                    foreground: root.fg
                    fontFamily: root.ff
                  }

                  Repeater {
                    model: modelData.items
                    delegate: BorderSurface {
                  required property var modelData
                  readonly property bool isDefault: !!modelData.is_default
                  readonly property bool isDirty: !!modelData.dirty
                  anchors.left: parent.left
                  anchors.right: parent.right
                  // altura mínima para que el distintivo y los botones quepan
                  implicitHeight: Math.max(64, row.implicitHeight + Style.spacing.rowPaddingY * 2)
                  radius: Style.cornerRadius
                  color: isDirty ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08) : Style.controlFill(false, false, root.fg, Color.accent)
                  borderSpec: Border.controlSpec(isDirty ? "focus" : "normal", root.fg, Color.accent)

                  Row {
                    id: row
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.rowPaddingX
                    spacing: Style.spacing.rowPaddingX
                    // izquierda: label + src
                    Column {
                      width: parent.width - badgeCol.width - btnCol.width - parent.spacing*2
                      spacing: Style.spacing.xs
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        width: parent.width
                        text: modelData.label + (modelData.dirty ? " ●" : "")
                        color: modelData.exists ? root.fg : Qt.darker(root.fg, 1.6)
                        font.family: root.ff
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        text: modelData.src
                        color: root.dim
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }
                    }
                    // distintivo
                    Column {
                      id: badgeCol
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 2
                      width: 92
                      Text {
                        text: modelData.exists ? (isDefault ? "por defecto" : "personalizado") : "ausente"
                        color: !modelData.exists ? Qt.darker(root.fg, 1.6) : isDefault ? root.dim : Color.accent
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                        font.bold: !isDefault && modelData.exists
                        horizontalAlignment: Text.AlignHCenter
                        width: parent.width
                      }
                      Text {
                        text: isDefault ? "󰦒" : "󰸞"
                        color: isDefault ? root.dim : Color.accent
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        horizontalAlignment: Text.AlignHCenter
                        width: parent.width
                      }
                    }
                    // acciones
                    Column {
                      id: btnCol
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 4
                      Button {
                        text: "Editar"; iconText: "󰏫"; bordered: false; foreground: root.fg; fontFamily: root.ff
                        enabled: modelData.exists
                        onClicked: root.doEdit(modelData.id)
                      }
                      Row { spacing: 4
                        Button {
                          text: "Diff"; iconText: "󰦓"; bordered: false; foreground: root.fg; fontFamily: root.ff
                          // Diff solo tiene sentido si hay default contra el que comparar
                          enabled: !isDefault
                          tooltipText: isDefault ? "idéntico al default — sin diff" : "diff vs /usr/share/omarchy"
                          onClicked: root.doDiff(modelData.id)
                        }
                        Button {
                          text: "Reset"; iconText: "󰦛"; bordered: false; foreground: root.fg; fontFamily: root.ff
                          enabled: !isDefault && modelData.exists
                          tooltipText: "restaura default (omarchy refresh) con .bak"
                          onClicked: root.doReset(modelData.id)
                        }
                      }
                    }
                  }
                  // click en la fila abre edición (atajo)
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (modelData.exists) root.doEdit(modelData.id) }
                }
              }
            }
          }
        }
      }
    }

        PanelSeparator { width: parent.width; visible: root.lastOutput !== "" }
        Text { width: parent.width; visible: root.lastOutput !== ""; text: root.lastOutput; color: root.dim; font.family: "monospace"; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
        Text { width: parent.width; text: "CLI: savegame | backup | edit <id> | diff <id> | reset <id> | restore --apply\nRepo privado: ~/.local/share/omarchy-replicant/repo (config/secrets/state)"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      }
    }
  }
}
