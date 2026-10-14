import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons

SearchController {
    id: root

    function focusedOutput() {
        var screens = Quickshell.screens
        if (!screens || screens.length === 0) return undefined
        try {
            var monitor = Hyprland.focusedMonitor
            if (monitor) {
                var name = String(monitor.name || "")
                for (var i = 0; i < screens.length; i++)
                    if (String(screens[i].name || "") === name) return screens[i]
            }
        } catch (e) {
            // Keep the overlay usable if compositor focus metadata is transient.
        }
        return screens[0]
    }

    onFocusRequested: Qt.callLater(function() { card.inputControl.forceActiveFocus() })
    onSelectionMoved: index => card.ensureSelectionVisible(index)

    PanelWindow {
        id: panel
        visible: root.opened
        screen: root.focusedOutput()
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.namespace: "pontual-search"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle { anchors.fill: parent; color: Color.menu.scrim }
        MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

        SearchCard {
            id: card
            anchors.fill: parent
            controller: root
            outputWidth: panel.width
            outputHeight: panel.height
        }
    }
}
