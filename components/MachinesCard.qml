import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../replicant.js" as R

// Every machine that saves into this repo, its profile, and when it last
// saved. With two machines this answers "did the desktop actually push?",
// which is why the repo exists. The remote, the branch and this machine's
// name used to be a table of their own, and nobody read it.
Card {
  id: mc
  readonly property var machines: panel.repoState.machines || []

  icon: panel.icMachine
  title: "Machines"
  subtitle: "Every machine that saves into " + (panel.repoState.remote_name || "this repo")
  countText: String(mc.machines.length)

  Repeater {
    model: mc.machines
    delegate: ListRow {
      required property var modelData
      panel: mc.panel
      width: mc.width
      icon: panel.icMachine
      iconColor: modelData.current ? Color.accent : panel.dim
      title: modelData.name
      titleBold: modelData.current
      // A machine with no recorded profile guessed one from its chassis.
      detail: (modelData.profile ? modelData.profile + " profile"
               : (modelData.current ? panel.profileName + " profile (guessed)" : "no profile"))
              + "  ·  "
              + ((modelData.last_epoch || 0) > 0 ? "saved " + R.agoText(modelData.last_epoch)
                 : (modelData.last_save ? "saved " + modelData.last_save : "no saves yet"))
      meta: modelData.current ? "this machine" : ""
      metaColor: Color.accent
    }
  }
}
