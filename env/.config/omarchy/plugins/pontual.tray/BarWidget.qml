// Keep the installed Omarchy tray implementation and popup behavior, but
// expose it under a user-owned id so Omarchy 4's built-in layout normalizer
// does not force it to the inner edge of its section.
import QtQuick
import qs.Ui as Ui
import "file:/usr/share/omarchy/shell/plugins/bar/widgets" as StockBarWidgets

Ui.BarWidget {
  id: root
  moduleName: "pontual.tray"

  StockBarWidgets.Tray {
    id: nativeTray
    anchors.fill: parent
    bar: root.bar
    moduleName: root.moduleName
    settings: root.settings
  }

  // Mirror the native widget's visibility policy from its data model rather
  // than the child's effective Item.visible value, which includes this
  // wrapper's own visibility and would form a parent/child feedback loop.
  visible: nativeTray.pinnedItems.length > 0 || nativeTray.drawerCount > 0
  implicitWidth: nativeTray.implicitWidth
  implicitHeight: nativeTray.implicitHeight
}
