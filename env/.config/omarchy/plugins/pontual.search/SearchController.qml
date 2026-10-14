import Quickshell
import Quickshell.Io
import QtQuick

Item {
    id: root
    property var shell: null
    property var manifest: null
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property string bridgePath: Quickshell.env("HOME") + "/.config/omarchy/plugins/pontual.search/bridge.py"
    property bool mock: false
    property bool opened: false
    property bool started: false
    property bool ready: false
    property int generation: 0
    property int selectedIndex: 0
    property string selectedKey: ""
    property string message: ""
    property string lastError: ""
    property bool busy: false
    property bool activating: false
    property string mode: "all"
    readonly property int resultCount: rows.count
    readonly property var prefixes: ({"/": "files", "=": "calc", ";": "clipboard", ">": "tasks", "$": "sessions", "?": "websearch", "@": "themes", ":": "commands"})
    readonly property var defaultProviders: ["desktopapplications", "tasks", "sessions", "commands"]
    readonly property string actualMode: prefixes[inputText.charAt(0)] || mode
    readonly property string queryText: prefixes[inputText.charAt(0)] ? inputText.slice(1).trim() : inputText
    readonly property string statusText: lastError || message || (busy ? "Searching…" : rows.count + " results")
    property string inputText: ""
    property alias resultsModel: rows
    onInputTextChanged: schedule()
    signal focusRequested()
    signal selectionMoved(int index)
    signal resultsReady(int count)

    ListModel { id: rows }
    function send(value) {
        if (!ready) return false
        bridge.write(JSON.stringify(value) + "\n")
        return true
    }
    function open(payloadJson) {
        var payload = {}
        try { payload = JSON.parse(payloadJson || "{}") } catch (error) { payload = {} }
        opened = true
        mode = typeof payload.mode === "string" ? payload.mode : "all"
        inputText = typeof payload.query === "string" ? payload.query : ""
        started = true
        Qt.callLater(function() { root.focusRequested(); root.schedule() })
    }
    function close() {
        opened = false
        debounce.stop()
        send({op: "cancel", requestId: generation})
        generation += 1
        busy = false
        activating = false
    }
    function dismiss() {
        close()
        if (shell && typeof shell.hide === "function") shell.hide("pontual.search")
    }
    function toggle() { if (opened) dismiss(); else open("{}") }
    function schedule() {
        if (!opened) return
        // Immediately invalidate rows/actions from the previous query, even
        // while debouncing. Never activate an old result under new input.
        if (rows.count && selectedIndex < rows.count) selectedKey = key(rows.get(selectedIndex))
        send({op: "cancel", requestId: generation})
        generation += 1
        rows.clear()
        selectedIndex = 0
        busy = true
        activating = false
        lastError = ""
        message = ""
        debounce.restart()
    }
    function query() {
        if (!opened) return
        var providers = actualMode === "all" ? defaultProviders : [actualMode]
        if (!send({op: "query", requestId: generation, providers: providers, query: queryText, limit: 40})) {
            busy = false
            lastError = "Search bridge unavailable; open again to retry"
        }
    }
    function key(item) { return item.provider + "\u001f" + item.identifier }
    function receive(line) {
        var event
        try { event = JSON.parse(line) } catch (error) { lastError = "Invalid search bridge response"; return }
        if (event.requestId !== generation) return
        if (event.type === "reset") { rows.clear(); selectedIndex = 0 }
        else if (event.type === "item" && event.item) {
            var item = event.item
            var actions = item.actions || []
            var modelItem = {provider: item.provider, identifier: item.identifier, title: item.text,
                icon: item.icon || "",
                subtitle: item.subtext || "", score: Number(item.score || 0), actionsJson: JSON.stringify(actions)}
            var itemKey = key(item)
            var found = -1
            for (var i = 0; i < rows.count; i++) if (key(rows.get(i)) === itemKey) { found = i; break }
            if (found >= 0) rows.set(found, modelItem)
            else { found = rows.count; rows.append(modelItem) }
            if (itemKey === selectedKey) selectedIndex = found
        } else if (event.type === "done") {
            busy = false
            if (!lastError) message = rows.count ? rows.count + " results" : "No results"
            resultsReady(rows.count)
        } else if (event.type === "error") {
            busy = false
            activating = false
            lastError = event.message || "Search failed"
        } else if (event.type === "activated") {
            activating = false
            dismiss()
        }
    }
    function move(delta) {
        if (!rows.count) return
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
        selectedKey = key(rows.get(selectedIndex))
        selectionMoved(selectedIndex)
    }
    function activate() {
        if (activating || !rows.count || selectedIndex >= rows.count) return
        var item = rows.get(selectedIndex)
        var offered = JSON.parse(item.actionsJson)
        // Only non-destructive primary actions. Other advertised actions are
        // deliberately not assigned to Enter (delete/clear/pin are not open).
        var preferred = {desktopapplications: "start", files: "open", calc: "copy", clipboard: "copy", websearch: "search", tasks: "open", sessions: "open", commands: "open", themes: "apply"}
        var action = preferred[item.provider]
        if (item.provider === "websearch" && offered.indexOf("open_url") >= 0) action = "open_url"
        if (!action || offered.indexOf(action) < 0) { lastError = "No supported primary action for this result"; return }
        activating = send({op: "activate", requestId: generation, provider: item.provider, identifier: item.identifier, action: action})
    }

    Timer { id: debounce; interval: 80; onTriggered: root.query() }
    Process {
        id: bridge
        command: root.mock ? ["python3", root.bridgePath, "--mock"] : ["python3", root.bridgePath]
        stdinEnabled: true
        running: root.started
        stdout: SplitParser { onRead: data => root.receive(data) }
        stderr: StdioCollector { waitForEnd: true }
        onStarted: { root.ready = true; if (root.opened) root.schedule() }
        onExited: exitCode => {
            root.ready = false
            root.started = false
            root.busy = false
            root.activating = false
            if (root.opened) root.lastError = "Bridge exited (" + exitCode + "); close and reopen to retry"
        }
    }
}
