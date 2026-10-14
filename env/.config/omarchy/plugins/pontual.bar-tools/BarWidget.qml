import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "../pontual.bar/widgets" as PersonalBar
import "file:/usr/share/omarchy/shell/plugins/notifications/components" as NativeNotifications

// Fixed actions only: shell.json cannot supply arbitrary execution strings.
Ui.BarWidget {
  id: root
  moduleName: "pontual.bar-tools"
  readonly property string role: String(setting("role", "quicksettings"))
  readonly property var roles: ["menu", "quicksettings", "system", "wallpaper", "notifications", "clock"]
  readonly property bool supported: roles.indexOf(role) !== -1
  readonly property var openPanelIndicatorAnchor: role === "notifications" ? opticalButtonLoader.item : null
  readonly property bool usesOpticalIcon: role === "menu" || role === "quicksettings" || role === "wallpaper" || role === "notifications"
  property var notificationServiceProxy: null
  readonly property string iconText: role === "menu" ? "󰍜"
    : role === "quicksettings" ? "󰒓"
    : role === "wallpaper" ? ""
    : role === "notifications" ? "󰂚" : ""
  readonly property string iconFontFamily: "JetBrainsMono Nerd Font"
  property bool popupOpen: false
  property bool syntheticReviewMode: false
  readonly property var notificationService: role === "notifications"
    ? (notificationServiceProxy || (bar && bar.shell
      && typeof bar.shell.firstPartyServiceFor === "function"
      ? bar.shell.firstPartyServiceFor("omarchy.notifications") : null)) : null
  property string historyError: ""
  property bool historyClearPending: false
  readonly property string historyReaderPath: decodeURIComponent(Qt.resolvedUrl("notifications-history.py").toString().replace(/^file:\/\//, ""))
  function notificationServiceHas(name) {
    try { return !!notificationService && name in notificationService } catch (e) { return false }
  }
  function notificationArchiveDirectory() {
    return notificationServiceHas("historyDir") ? notificationService.historyDir
      : Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history"
  }
  function notificationArchiveLimit() {
    return notificationServiceHas("historyLimit") ? Number(notificationService.historyLimit) : 10
  }
  function currentPopupModel() {
    return notificationServiceHas("popupModel") ? notificationService.popupModel : null
  }
  function notificationCardRadius() {
    return notificationServiceHas("cornerRadius") ? notificationService.cornerRadius : Style.cornerRadius
  }
  readonly property string notificationCountText: notificationCount > 99 ? "99+" : String(notificationCount)
  readonly property real notificationCountWidth: notificationCountMetrics.advanceWidth
  readonly property int notificationCount: {
    var total = notificationHistory.count
    var model = currentPopupModel()
    if (!model || !model.get) return total
    for (var i = 0; i < model.count; i++) {
      var live = model.get(i)
      if (!live || Number(live.originalId) < 0 || !Number(live.timestamp)) continue
      var key = String(live.timestamp) + "-" + String(live.originalId || live.id || 0) + ".json"
      if (!historyKeys[key]) total++
    }
    return total
  }
  readonly property int notificationPopupCount: currentPopupModel() ? currentPopupModel().count : -1
  readonly property int notificationCenterRowCount: notificationCenterRows.count
  property var previous: null
  property var cpuHistory: []
  property var memoryHistory: []
  property real latestCpu: 0
  property real latestMemory: 0
  property string sampleError: "Waiting for CPU/RAM sample"
  readonly property int historyLimit: 30
  property string clockText: ""
  readonly property string metricPath: decodeURIComponent(Qt.resolvedUrl("metrics.py").toString().replace(/^file:\/\//, ""))

  function run(command) { if (bar) bar.run(command) }
  readonly property var opened: role === "quicksettings" || role === "notifications" ? popupOpen : undefined
  function open() {
    if (role !== "quicksettings" && role !== "notifications") return
    syntheticReviewMode = false
    popupOpen = true
    if (role === "notifications") refreshNotificationHistory()
  }
  function close() {
    popupOpen = false
    if (syntheticReviewMode) notificationCenterRows.clear()
    syntheticReviewMode = false
  }
  function toggle() {
    if (role !== "quicksettings" && role !== "notifications") return
    popupOpen = !popupOpen
    syntheticReviewMode = false
    if (popupOpen && role === "notifications") refreshNotificationHistory()
  }
  function ingest(raw) {
    try {
      var v = JSON.parse(raw)
      if (root.role === "clock") {
        if (typeof v.clock !== "string" || !/^\d{2}:\d{2}:\d{2}$/.test(v.clock)) throw new Error(v.error || "Invalid clock")
        clockText = v.clock
        return
      }
      if (v.error || typeof v.total !== "number" || typeof v.idle !== "number" || typeof v.memory !== "number" || !isFinite(v.total) || !isFinite(v.idle) || !isFinite(v.memory) || v.total < 0 || v.idle < 0 || v.memory < 0 || v.memory > 100) throw new Error(v.error || "Invalid sample")
      if (previous && v.total > previous.total) {
        var elapsed = v.total - previous.total
        var idleElapsed = v.idle - previous.idle
        if (idleElapsed < 0 || idleElapsed > elapsed) throw new Error("CPU counters reset; collecting a fresh baseline")
        latestCpu = Math.max(0, Math.min(100, 100 * (1 - idleElapsed / elapsed)))
        latestMemory = v.memory
        cpuHistory = cpuHistory.concat([latestCpu]).slice(-root.historyLimit)
        memoryHistory = memoryHistory.concat([latestMemory]).slice(-root.historyLimit)
        graph.requestPaint()
      }
      previous = v
      sampleError = ""
    } catch (error) { sampleError = String(error); previous = null; graph.requestPaint() }
  }
  implicitWidth: role === "notifications" ? Style.space(52) + notificationCountMetrics.advanceWidth
    : usesOpticalIcon ? Style.space(36)
    : role === "system" ? graph.width + Style.space(16) : button.implicitWidth
  implicitHeight: Style.space(36)

  Process {
    id: sampler
    command: root.role === "clock" ? ["python3", root.metricPath, "--clock"] : ["python3", root.metricPath]
    stdout: StdioCollector { onStreamFinished: root.ingest(text) }
    onExited: function(code, status) { if (code !== 0) { root.sampleError = "Bar reader failed (" + code + ")"; if (root.role === "clock") root.clockText = "Clock unavailable" } }
  }
  Timer {
    interval: root.role === "clock" ? 1000 : 2000
    running: root.role === "system" || root.role === "clock"
    repeat: true; triggeredOnStart: true
    onTriggered: if (!sampler.running) sampler.running = true
  }
  Timer {
    interval: 30000
    running: root.role === "notifications"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNotificationHistory()
  }
  TextMetrics {
    id: notificationCountMetrics
    font.family: root.iconFontFamily
    font.pixelSize: Style.space(16)
    text: root.notificationCountText
  }
  Loader {
    id: opticalButtonLoader
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.usesOpticalIcon ? Style.space(36) : 0
    height: parent.height
    z: 1
    active: root.usesOpticalIcon
    sourceComponent: opticalButtonComponent
  }

  Rectangle {
    z: 0
    visible: root.role === "notifications"
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(36)
    height: Style.space(36)
    radius: Style.space(8)
    color: Color.accent
  }

  Text {
    visible: root.role === "notifications"
    anchors.left: opticalButtonLoader.right
    anchors.leftMargin: Style.space(8)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: root.notificationCountText
    color: root.bar ? root.bar.foreground : "white"
    font.family: root.iconFontFamily
    font.pixelSize: Style.space(16)
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) { root.activate(mouse.button) }
    }
  }

  Component {
    id: opticalButtonComponent
    Ui.BarIconButton {
      id: opticalButton
    objectName: "pontual.openPanelIndicatorAnchor"
      anchors.fill: parent
      bar: root.bar
      text: root.iconText
      fontFamily: root.iconFontFamily
      fontSize: 20
      foreground: root.role === "notifications" ? "#24283b" : (root.bar ? root.bar.foreground : "white")
      slotSize: Style.space(36)
      opticalSize: Style.space(36)
      tooltipText: root.role === "menu" ? "Omarchy menu · right click: terminal"
        : root.role === "notifications" ? "Notification history · right click: DND" : root.role
      iconComponent: Component {
        PersonalBar.OpticalBarGlyph {
          text: opticalButton.text
          fontFamily: opticalButton.fontFamily
          color: opticalButton.active && opticalButton.useActiveColor ? opticalButton.activeColor : opticalButton.foreground
        }
      }
      onPressed: function(mouseButton) { root.activate(mouseButton) }
    }
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    visible: !root.usesOpticalIcon
    bar: root.bar
    text: !root.supported ? "?" : root.role === "system" ? "" : root.role === "clock" ? root.clockText : ""
    hasVisualContent: root.role === "system" || text !== ""
    tooltipText: !root.supported ? "Unsupported bar role: " + root.role : root.role === "system" ? (root.sampleError ? root.sampleError + " · CPU/RAM · 2s sampling" : "CPU " + root.latestCpu.toFixed(1) + "% · RAM " + root.latestMemory.toFixed(1) + "% · " + root.cpuHistory.length + "/" + root.historyLimit + " samples · 2s interval · click: btop") : root.role === "clock" ? "America/Sao_Paulo · calendar" : root.role === "notifications" ? "Notification history · right click: DND" : root.role
    horizontalMargin: 8
    fixedWidth: -1
    onPressed: function(mouseButton) { root.activate(mouseButton) }
    Canvas {
      id: graph
      visible: root.role === "system"
      width: Style.space(64); height: Style.space(20)
      anchors.right: parent.right; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onVisibleChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d"); ctx.clearRect(0, 0, width, height)
        var lineWidth = 1.8
        var inset = Math.max(1, lineWidth / 2)
        var plotWidth = Math.max(1, width - inset * 2)
        var plotHeight = Math.max(1, height - inset * 2)
        var series = [root.cpuHistory, root.memoryHistory]
        for (var n = 0; n < series.length; n++) {
          var values = series[n]
          if (!values.length) continue
          ctx.strokeStyle = n === 0 ? Color.accent : root.bar ? root.bar.foreground : "white"
          ctx.lineWidth = lineWidth; ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.beginPath()
          for (var i = 0; i < values.length; i++) {
            var x = values.length < 2 ? inset + plotWidth / 2 : inset + i * plotWidth / (values.length - 1)
            var y = inset + plotHeight * (1 - values[i] / 100)
            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
          }
          if (values.length === 1) ctx.lineTo(inset + plotWidth / 2 + 1, inset + plotHeight * (1 - values[0] / 100))
          ctx.stroke()
        }
      }
    }

  }

  function activate(mouseButton) {
    if (!supported) return
    if (role === "menu") run(mouseButton === Qt.RightButton ? "xdg-terminal-exec" : "omarchy-shell shell toggle omarchy.menu '{\"menu\":\"root\"}'")
    else if (role === "quicksettings") popupOpen = !popupOpen
    else if (role === "system") run("~/.config/omarchy/plugins/pontual.bar-tools/open-btop.sh")
    else if (role === "wallpaper") run("omarchy menu summon style.background")
    else if (role === "notifications") {
      if (mouseButton === Qt.RightButton) {
        if (notificationService && typeof notificationService.setDoNotDisturb === "function")
          notificationService.setDoNotDisturb(!notificationService.doNotDisturb)
      } else {
        toggle()
      }
    }
    else if (role === "clock") run("omarchy-shell shell toggle omarchy.clock")
  }

  ListModel { id: notificationHistory }
  property var historyKeys: ({})
  property string pendingHistoryKey: ""

  function refreshNotificationHistory() {
    if (role !== "notifications" || historyReader.running) return
    historyError = ""
    historyReader.command = ["python3", historyReaderPath, "--directory",
      notificationArchiveDirectory(), "--limit", String(notificationArchiveLimit())]
    historyReader.running = true
  }

  function acceptNotificationHistory(raw) {
    var rows
    try {
      rows = JSON.parse(raw)
      if (!Array.isArray(rows)) throw new Error("invalid history result")
    } catch (error) {
      historyError = "Notification history could not be read"
      return
    }
    notificationHistory.clear()
    var keys = ({})
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row || row.actionsAvailable !== false || !isFinite(Number(row.timestamp))) continue
      notificationHistory.append({
        key: String(row.key || ""), app: String(row.app || ""), appIcon: String(row.appIcon || ""),
        summary: String(row.summary || ""), body: String(row.body || ""), image: String(row.image || ""),
        glyph: String(row.glyph || ""), urgency: Number(row.urgency) || 1, timestamp: Number(row.timestamp),
        actionsAvailable: false
      })
      keys[String(row.key || "")] = true
    }
    historyKeys = keys
    rebuildNotificationRows()
  }

  // Omarchy's supported third-party bar proxy does not expose popupModel or
  // liveRefs. In this installed version the center therefore presents only
  // archived history; fresh notifications remain in Omarchy's native toast
  // surface. These guarded paths can use a future public live model without
  // making archive rows actionable or bypassing the PluginShellApi boundary.
  ListModel { id: notificationCenterRows }

  function rebuildNotificationRows() {
    if (role !== "notifications") return
    notificationCenterRows.clear()
    if (syntheticReviewMode) return
    var liveModel = currentPopupModel()
    var represented = ({})
    if (liveModel && liveModel.get) {
      for (var i = 0; i < liveModel.count; i++) {
        var live = liveModel.get(i)
        if (!live) continue
        var liveKey = String(live.timestamp) + "-" + String(live.originalId || live.id || 0) + ".json"
        represented[liveKey] = true
        notificationCenterRows.append({
          kind: notificationService.isRestoredRow && notificationService.isRestoredRow(live) ? "restored" : "live",
          app: String(live.app || ""), appIcon: String(live.appIcon || ""),
          summary: String(live.summary || ""), body: String(live.body || ""), image: String(live.image || ""),
          glyph: String(live.glyph || ""), urgency: Number(live.urgency) || 1,
          timestamp: Number(live.timestamp) || 0, originalId: Number(live.originalId), popupIndex: i,
          key: liveKey
        })
      }
    }
    for (var j = 0; j < notificationHistory.count; j++) {
      var archived = notificationHistory.get(j)
      if (!archived || represented[String(archived.key || "")]) continue
      notificationCenterRows.append({
        kind: "archive", app: archived.app, appIcon: archived.appIcon,
        summary: archived.summary, body: archived.body, image: archived.image,
        glyph: archived.glyph, urgency: archived.urgency, timestamp: archived.timestamp,
        originalId: -1, popupIndex: -1, key: archived.key
      })
    }
  }

  function centerRowKind(index) {
    return index >= 0 && index < notificationCenterRows.count
      ? String(notificationCenterRows.get(index).kind || "") : ""
  }

  function centerRowKey(index) {
    return index >= 0 && index < notificationCenterRows.count
      ? String(notificationCenterRows.get(index).key || "") : ""
  }

  function openSyntheticReviewCenter(rowCount) {
    if (role !== "notifications") return false
    syntheticReviewMode = true
    notificationCenterRows.clear()
    var count = Math.max(1, Math.min(20, Number(rowCount) || 1))
    for (var i = 0; i < count; i++) notificationCenterRows.append({
      kind: "fixture", app: "Synthetic preview", appIcon: "", summary: "Preview card " + (i + 1),
      body: "Only synthetic text is shown in this geometry check.", image: "", glyph: "󰂚",
      urgency: 1, timestamp: Date.now() + i, originalId: -1, popupIndex: -1,
      key: "synthetic-preview-" + i
    })
    popupOpen = true
    return true
  }

  function notificationPopupGeometry() {
    var anchorX = null
    var anchorY = null
    var anchorItemWidth = null
    var anchorItemHeight = null
    try {
      anchorX = Math.round(historyPopup.anchor.rect.x)
      anchorY = Math.round(historyPopup.anchor.rect.y)
      anchorItemWidth = Math.round(historyPopup.anchorItem.width)
      anchorItemHeight = Math.round(historyPopup.anchorItem.height)
    } catch (e) { }
    var serviceAvailable = notificationService !== null && notificationService !== undefined
    var liveModelAvailable = false
    var dndAvailable = false
    var popupCount = -1
    if (serviceAvailable) {
      try {
        liveModelAvailable = notificationServiceHas("popupModel")
          && !!notificationService.popupModel
          && typeof notificationService.popupModel.count === "number"
        if (liveModelAvailable) popupCount = notificationService.popupModel.count
      } catch (e1) { }
      try { dndAvailable = typeof notificationService.setDoNotDisturb === "function" } catch (e2) { }
    }
    return {
      open: popupOpen,
      syntheticFixture: syntheticReviewMode,
      visible: historyPopup.visible,
      notificationServiceAvailable: serviceAvailable,
      nativeLiveModelAvailable: liveModelAvailable,
      dndControlAvailable: dndAvailable,
      popupCount: popupCount,
      anchorX: anchorX, anchorY: anchorY,
      anchorItemWidth: anchorItemWidth, anchorItemHeight: anchorItemHeight,
      screenWidth: Math.round(historyPopup.screenW), screenHeight: Math.round(historyPopup.screenH),
      barHeight: Math.round(historyPopup.barH),
      width: Math.round(historyPopup.width), height: Math.round(historyPopup.height),
      contentWidth: Math.round(historyPopup.contentWidth), contentHeight: Math.round(historyPopup.contentHeight),
      listHeight: Math.round(historyList.height), listContentHeight: Math.round(historyList.contentHeight),
      listCanScroll: historyList.contentHeight > historyList.height + 1,
      rowCount: notificationCenterRows.count
    }
  }

  function invokeLiveAction(centerIndex, identifier, label) {
    if (!notificationService || centerIndex < 0 || centerIndex >= notificationCenterRows.count) return
    var centerRow = notificationCenterRows.get(centerIndex)
    if (!centerRow || centerRow.kind !== "live") return
    var index = Number(centerRow.popupIndex)
    var model = currentPopupModel()
    if (!model) return
    if (!model || index < 0 || index >= model.count) return
    var live = model.get(index)
    if (!live || Number(live.originalId) !== Number(centerRow.originalId)
        || Number(live.timestamp) !== Number(centerRow.timestamp)
        || notificationService.isRestoredRow(live)) return
    var ref = notificationService.liveRefs[centerRow.originalId]
    if (!ref || !ref.actions) return
    var action = null
    for (var i = 0; i < ref.actions.length; i++) {
      var candidate = ref.actions[i]
      if (candidate && String(candidate.identifier) === String(identifier)
          && String(candidate.text) === String(label)) { action = candidate; break }
    }
    if (!action || typeof action.invoke !== "function") return
    try {
      action.invoke()
      notificationService.dismissPopup(index)
    } catch (error) {
      historyError = "That notification action is no longer available"
    }
  }

  function invokeLiveDefault(centerIndex) {
    if (!notificationService || centerIndex < 0 || centerIndex >= notificationCenterRows.count) return
    var centerRow = notificationCenterRows.get(centerIndex)
    if (!centerRow || centerRow.kind !== "live") return
    var index = Number(centerRow.popupIndex)
    var model = currentPopupModel()
    if (!model) return
    if (!model || index < 0 || index >= model.count) return
    var live = model.get(index)
    if (!live || Number(live.originalId) !== Number(centerRow.originalId)
        || Number(live.timestamp) !== Number(centerRow.timestamp)
        || (notificationService.isRestoredRow && notificationService.isRestoredRow(live))) return
    notificationService.invokePopupDefault(index)
  }

  function dismissActiveRow(centerIndex) {
    if (!notificationService || centerIndex < 0 || centerIndex >= notificationCenterRows.count) return
    var centerRow = notificationCenterRows.get(centerIndex)
    if (!centerRow || (centerRow.kind !== "live" && centerRow.kind !== "restored")) return
    var index = Number(centerRow.popupIndex)
    var model = currentPopupModel()
    if (!model) return
    if (!model || index < 0 || index >= model.count) return
    var live = model.get(index)
    if (!live || Number(live.originalId) !== Number(centerRow.originalId)
        || Number(live.timestamp) !== Number(centerRow.timestamp)) return
    notificationService.dismissPopup(index)
  }

  Connections {
    target: root.currentPopupModel()
    function onCountChanged() { root.rebuildNotificationRows() }
    function onDataChanged() { root.rebuildNotificationRows() }
    function onRowsInserted() { root.rebuildNotificationRows() }
    function onRowsRemoved() { root.rebuildNotificationRows() }
    function onModelReset() { root.rebuildNotificationRows() }
  }

  function hideNotificationHistoryEntry(key) {
    if (historyAction.running) return
    pendingHistoryKey = String(key || "")
    var found = false
    for (var i = 0; i < notificationHistory.count; i++) {
      if (String(notificationHistory.get(i).key || "") === pendingHistoryKey) { found = true; break }
    }
    if (!found) return
    historyAction.command = ["python3", historyReaderPath, "--directory",
      notificationArchiveDirectory(), "--remove", pendingHistoryKey]
    historyAction.running = true
  }

  Process {
    id: historyReader
    running: false
    stdout: StdioCollector { onStreamFinished: root.acceptNotificationHistory(text) }
    onExited: function(code) {
      if (code !== 0) root.historyError = "Notification history reader failed"
    }
  }

  Process {
    id: historyAction
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          if (result.removed === true) root.refreshNotificationHistory()
          else if (result.cleared === true) {
            root.historyClearPending = false
            root.historyError = ""
            root.refreshNotificationHistory()
          }
          else root.historyError = "That archived notification could not be dismissed"
        } catch (error) { root.historyError = "Notification history action failed" }
      }
    }
    onExited: function(code) {
      if (code !== 0) {
        root.historyClearPending = false
        root.historyError = "Notification history action failed"
      }
    }
  }

  function clearArchivedHistory() {
    if (historyAction.running || syntheticReviewMode || !notificationHistory.count) return
    historyClearPending = true
    historyAction.command = ["python3", historyReaderPath, "--directory",
      notificationArchiveDirectory(), "--clear"]
    historyAction.running = true
  }

  Ui.PopupCard {
    id: historyPopup
    anchorItem: opticalButtonLoader.item || root
    bar: root.bar
    owner: root
    open: root.role === "notifications" && root.popupOpen
    contentWidth: fittedContentWidth(Style.space(420))
    contentHeight: fittedContentHeight(centerContent.implicitHeight, Style.space(560))

    ColumnLayout {
      id: centerContent
      anchors.fill: parent
      spacing: Style.space(8)

      RowLayout {
        Layout.fillWidth: true
        Text {
          Layout.fillWidth: true
          text: "Notifications · " + notificationCenterRows.count
          color: root.bar ? root.bar.foreground : "white"
          font.family: "JetBrainsMono Nerd Font"
          font.pixelSize: Style.font.title
          font.bold: true
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Ui.Button {
          text: notificationService && notificationService.doNotDisturb ? "DND on" : "DND off"
          enabled: !root.syntheticReviewMode
          onClicked: if (notificationService && typeof notificationService.setDoNotDisturb === "function")
            notificationService.setDoNotDisturb(!notificationService.doNotDisturb)
        }
        Ui.Button {
          text: "Clear history"
          enabled: !root.syntheticReviewMode && notificationHistory.count > 0 && !historyAction.running
          onClicked: root.clearArchivedHistory()
        }
        Ui.Button { text: "Close"; onClicked: root.popupOpen = false }
      }

      Text {
        id: historyEmptyLabel
        Layout.fillWidth: true
        visible: root.historyError !== ""
        text: root.historyError
        color: Color.urgent
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Style.font.body
      }

      Text {
        Layout.fillWidth: true
        visible: notificationCenterRows.count === 0 && root.historyError === ""
        text: "No recorded notifications"
        color: Color.foreground
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Style.font.body
      }

      ListView {
        id: historyList
        Layout.fillWidth: true
        visible: notificationCenterRows.count > 0
        Layout.minimumHeight: Style.space(1)
        Layout.preferredHeight: Math.min(contentHeight, Style.space(320))
        clip: true
        implicitHeight: Math.min(contentHeight, Style.space(320))
        spacing: Style.space(8)
        model: notificationCenterRows

        delegate: ColumnLayout {
          id: historyRow
          required property int index
          required property string kind
          required property string key
          required property string app
          required property string appIcon
          required property string summary
          required property string body
          required property string image
          required property string glyph
          required property int urgency
          required property double timestamp
          required property int originalId
          required property int popupIndex
          readonly property var actionDescriptors: kind === "live"
            ? root.liveActionsFor(originalId, popupIndex) : []
          width: historyList.width
          spacing: Style.space(3)

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: (historyRow.kind === "live" ? "New · "
                : historyRow.kind === "restored" ? "Restored · " : "Earlier · ")
                + (historyRow.app || "Notification") + " · "
                + Qt.formatDateTime(new Date(historyRow.timestamp), "ddd dd MMM yyyy · HH:mm:ss")
              color: Color.foreground
              font.family: "JetBrainsMono Nerd Font"
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Ui.Button {
              visible: historyRow.kind !== "fixture"
              text: "Dismiss"
              onClicked: historyRow.kind === "archive"
                ? root.hideNotificationHistoryEntry(historyRow.key) : root.dismissActiveRow(historyRow.index)
            }
          }

          NativeNotifications.NotificationCard {
            Layout.fillWidth: true
            enabled: historyRow.kind === "live"
            app: historyRow.app
            appIcon: historyRow.appIcon
            summary: historyRow.summary
            body: historyRow.body
            image: historyRow.image
            glyph: historyRow.glyph
            urgency: historyRow.urgency
            timestamp: historyRow.timestamp
            cornerRadius: root.notificationCardRadius()
            fontFamily: root.bar ? root.bar.fontFamily : "JetBrainsMono Nerd Font"
            // Live cards use Omarchy's native default action/focus path.
            // Archived rows have no live handle and remain inert.
            onCloseRequested: historyRow.kind === "archive"
              ? root.hideNotificationHistoryEntry(historyRow.key) : root.dismissActiveRow(historyRow.index)
            onCardClicked: root.invokeLiveDefault(historyRow.index)
          }

          Repeater {
            model: historyRow.actionDescriptors
            delegate: Ui.Button {
              required property int index
              Layout.fillWidth: true
              required property var modelData
              text: modelData.text
              onClicked: root.invokeLiveAction(historyRow.index, modelData.identifier, modelData.text)
            }
          }
        }
      }
    }
  }

  function liveActionsFor(originalId, popupIndex) {
    if (!notificationService) return []
    var model = currentPopupModel()
    if (!model) return []
    if (!model || popupIndex < 0 || popupIndex >= model.count) return []
    var row = model.get(popupIndex)
    if (!row || Number(row.originalId) !== Number(originalId) || notificationService.isRestoredRow(row)) return []
    var ref = notificationService.liveRefs[originalId]
    if (!ref || !ref.actions) return []
    var actions = []
    for (var i = 0; i < ref.actions.length; i++) {
      var action = ref.actions[i]
      if (action && action.identifier && action.text && typeof action.invoke === "function")
        actions.push({ identifier: String(action.identifier), text: String(action.text) })
    }
    return actions
  }

  Ui.PopupCard {
    anchorItem: root; bar: root.bar; owner: root; open: root.role === "quicksettings" && root.popupOpen
    contentWidth: fittedContentWidth(Style.space(260))
    contentHeight: fittedContentHeight(actions.implicitHeight)
    Column {
      id: actions
      anchors.fill: parent; spacing: Style.space(5)
      Repeater {
        model: [
          { label: "Audio / mixer", command: "omarchy-shell shell toggle omarchy.audio" },
          { label: "Network", command: "omarchy-shell shell toggle omarchy.network" },
          { label: "Bluetooth", command: "omarchy-shell shell toggle omarchy.bluetooth" },
          { label: "Display / brightness", command: "omarchy-shell shell toggle omarchy.monitor" },
          { label: "Toggle night light", command: "omarchy toggle nightlight" },
          { label: "System / power", command: "omarchy menu summon system" },
          { label: "Settings", command: "omarchy menu summon setup" }
        ]
        Ui.Button {
          required property var modelData
          text: modelData.label; foreground: root.bar ? root.bar.foreground : "white"
          onClicked: { root.popupOpen = false; root.run(modelData.command) }
        }
      }
    }
  }
}
