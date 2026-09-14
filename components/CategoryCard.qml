import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One area of the Configs tab: its files, and how the area comes back.
Card {
  id: cc
  property var card: ({})

  icon: cc.card.icon
  title: cc.card.label
  subtitle: cc.card.description
  countText: String(cc.card.count)
  statusText: cc.card.incoming > 0 ? cc.card.incoming + " to restore"
            : cc.card.changed > 0 ? cc.card.changed + " changed"
            : cc.card.off > 0 ? cc.card.off + " off" : "in sync"
  statusTone: cc.card.incoming > 0 ? "warn" : cc.card.changed > 0 ? "accent" : ""
  tint: cc.card.incoming > 0 ? "warn" : cc.card.changed > 0 ? "accent" : ""
  collapsible: true
  // A filter is a question about the rows, so while one is on, every card
  // that has an answer is open. Filtering and then opening eleven cards to
  // find the three matches was the search doing half its job.
  expanded: panel.isOpen(cc.card.id) || panel.filtering
  onToggled: panel.toggleCard(cc.card.id)

  // Shortcuts is the one area where the files are not the point: what you
  // want to see is the keyboard. The file row is still there below.
  ShortcutsView {
    panel: cc.panel
    width: parent.width
    visible: cc.card.id === "shortcuts" && !panel.filtering
  }

  Repeater {
    model: cc.open ? cc.card.rows : []
    delegate: FileRow {
      required property var modelData
      panel: cc.panel
      config: modelData
      width: cc.width
    }
  }

  // The selling point, said out loud where it matters: not "we copied your
  // files back" but "here is the Omarchy command that puts this back
  // properly".
  CardNote { panel: cc.panel; icon: panel.icInfo; text: cc.card.method || "" }
}
