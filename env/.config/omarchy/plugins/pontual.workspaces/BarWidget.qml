// Adapted from the installed Omarchy 4.0.4 workspace widget. It keeps the
// installed Lua dispatcher and WidgetButton's click, wheel, and tooltip APIs.
import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui as Ui

Ui.BarWidget {
  id: root
  moduleName: "pontual.workspaces"

  readonly property var glyphs: ["", "", "", "󰖺", "󰗃", "󰎧", "󰖣", "󰊻", "", "󰓇"]
  readonly property var names: ["Terminal", "Browser", "Assistant", "Games", "YouTube", "Workspace 6", "WhatsApp", "Teams", "Vesktop", "Spotify"]
  // Keep the stock full-height hit target while restoring a compact visual
  // group: a 30px theme-colored container with 22px per-workspace highlights.
  readonly property real slotWidth: Style.space(28)
  readonly property real groupInset: Style.space(4)
  readonly property real groupHeight: Style.space(30)
  readonly property real innerPillSize: Style.space(22)
  readonly property real groupGap: Style.space(2)
  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)
  // Keep the palette color opaque and blend it as a rendered surface.
  readonly property real surfaceTintOpacity: 0.10

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (Number(values[i].id) === Number(id)) return values[i]
    }
    return null
  }

  function workspaceIds() {
    // Show only real compositor workspace entries. This presentation never
    // allocates placeholders; the list follows Hyprland create/destroy events.
    var values = Hyprland.workspaces.values
    var ids = []
    for (var i = 0; i < values.length; i++) {
      var id = Number(values[i].id)
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }
    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    // Recheck before dispatch in case an empty workspace vanished after a
    // pointer event was queued; this avoids creating a missing workspace.
    if (!root.bar || !root.workspaceById(id)) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  function focusAdjacent(id, delta) {
    var ids = root.workspaceIds()
    if (ids.length < 2) return
    var index = ids.indexOf(Number(id))
    if (index < 0) return
    var direction = delta > 0 ? -1 : 1
    root.focusWorkspace(ids[(index + direction + ids.length) % ids.length])
  }

  // The root remains a full-height bar slot. Its painted group is intentionally
  // shorter, so top and bottom padding are equal without shrinking click areas.
  implicitWidth: root.vertical ? grid.implicitWidth : grid.implicitWidth + root.groupInset * 2 + root.trailingGap
  implicitHeight: root.vertical ? grid.implicitHeight : root.barSize

  Rectangle {
    id: workspaceGroup
    visible: !root.vertical && root.workspaceIds().length > 0
    x: 0
    y: Math.round((root.barSize - height) / 2)
    width: grid.implicitWidth + root.groupInset * 2
    height: root.groupHeight
    radius: Style.space(8)
    color: Color.bar.background
    opacity: root.surfaceTintOpacity
  }

  GridLayout {
    id: grid
    x: root.vertical ? Math.round((root.width - implicitWidth) / 2) : root.groupInset
    y: 0
    width: implicitWidth
    height: root.vertical ? implicitHeight : root.barSize
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : root.groupGap
    rowSpacing: root.vertical ? root.groupGap : 0

    Repeater {
      model: root.workspaceIds()

      Item {
        id: workspaceSlot
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Number(Hyprland.focusedWorkspace.id) === modelData
        readonly property bool highlighted: focused || workspaceButton.tooltipHovered
        readonly property string caption: root.names[modelData - 1] || ("Workspace " + modelData)
        readonly property string iconGlyph: root.glyphs[modelData - 1] || String(modelData)
        implicitWidth: root.vertical ? root.barSize : root.slotWidth
        implicitHeight: root.vertical ? root.slotWidth : root.barSize

        Rectangle {
          anchors.centerIn: parent
          width: root.innerPillSize
          height: root.innerPillSize
          radius: Style.space(6)
          color: workspaceSlot.highlighted ? Color.accent : "transparent"

          Behavior on color {
            ColorAnimation { duration: 80; easing.type: Easing.OutCubic }
          }
        }

        Ui.BarIconButton {
          id: workspaceButton
          anchors.fill: parent
          bar: root.bar
          text: workspaceSlot.iconGlyph
          tooltipText: "Workspace " + workspaceSlot.modelData + " · " + workspaceSlot.caption
            + (workspaceSlot.focused ? " · active" : (workspaceSlot.occupied ? " · occupied" : " · empty"))
          fontSize: Style.space(16)
          slotSize: root.slotWidth
          opticalSize: root.innerPillSize
          foreground: Color.accent
          activeColor: Color.background
          active: workspaceSlot.highlighted
          opacity: 1
          onPressed: function() { root.focusWorkspace(workspaceSlot.modelData) }
          onWheelMoved: function(delta) { root.focusAdjacent(workspaceSlot.modelData, delta) }
        }
      }
    }
  }
}
