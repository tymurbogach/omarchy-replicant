import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One suggestion: a file that looks like config and that nothing tracks yet.
ListRow {
  id: srow
  property var item: ({})
  readonly property bool isSecret: srow.item.kind === "secret"
  readonly property bool selected: panel.selectedIds.indexOf(srow.item.id) !== -1

  icon: srow.isSecret ? panel.icKey : panel.icFile
  iconColor: srow.isSecret ? panel.warnColor : panel.dim
  title: srow.item.pretty || ""
  detail: srow.item.reason || ""
  // A file that holds a credential is not a normal suggestion: tracked as
  // ordinary config it would sit world-readable in a git checkout.
  detailColor: srow.isSecret ? Color.urgent : panel.dim

  RowAction {
    panel: srow.panel
    anchors.verticalCenter: parent.verticalCenter
    text: panel.manageMode ? (srow.selected ? "Selected" : "Select") : (srow.isSecret ? "Track (600)" : "Track")
    iconText: panel.icPlus
    enabled: !panel.busy
    tooltipText: srow.isSecret
                 ? "Add it to your list as a secret: stored at mode 600, and its contents are never rendered"
                 : "Add it to your list. It is saved with your next Save to GitHub."
    onClicked: panel.manageMode ? panel.toggleSelected(srow.item.id, false) : panel.doTrack(srow.item.path, srow.item.kind)
  }
}
