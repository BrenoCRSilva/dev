import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons

// Visual-only card shared by the live overlay and safe offscreen UI fixtures.
// All query, selection and activation decisions stay in SearchController.
Item {
    id: root
    required property var controller
    property real outputWidth: width
    property real outputHeight: height
    readonly property real cardWidth: Math.max(280, Math.min(620, outputWidth - 32))
    readonly property real viewportHeight: controller.resultsModel.count > 0
        ? Math.max(0, Math.min(results.contentHeight, Math.min(6 * 48, outputHeight - 172))) : 0
    readonly property real cardHeight: body.implicitHeight + 28
    readonly property real cardX: Math.max(16, (outputWidth - cardWidth) / 2)
    readonly property real cardY: Math.max(16, Math.min(outputHeight - cardHeight - 16, outputHeight * 0.23))
    readonly property int visibleResultRows: controller.resultsModel.count > 0
        ? Math.min(6, controller.resultsModel.count) : 0
    property var iconIndex: ({})
    property var pendingIconIndex: ({})
    property bool iconIndexReady: false
    readonly property alias inputControl: input
    readonly property real inputHeight: 64

    function ensureSelectionVisible(index) {
        results.positionViewAtIndex(index, ListView.Contain)
    }

    function resolveIcon(value, provider) {
        var raw = String(value || "")
        if (raw.indexOf("file://") === 0 || raw.indexOf("image://") === 0) return raw
        if (raw.charAt(0) === "/") return Util.fileUrl(raw)
        if (raw.length > 0) {
            var indexed = iconIndex[raw]
            if (indexed) return Util.fileUrl(indexed)
            var themed = Quickshell.iconPath(raw, true)
            if (themed && themed.length > 0) return themed
        }
        var semantic = ({
            desktopapplications: "application-x-executable",
            files: "folder",
            calc: "accessories-calculator",
            clipboard: "edit-paste",
            tasks: "view-list",
            sessions: "utilities-terminal",
            commands: "utilities-terminal",
            themes: "preferences-desktop-theme",
            websearch: "web-browser"
        })[provider] || "application-x-executable"
        var semanticPath = iconIndex[semantic]
        if (semanticPath) return Util.fileUrl(semanticPath)
        return Quickshell.iconPath(semantic, true)
    }

    function iconIndexCommand() {
        return 'dirs="$HOME/.icons $HOME/.local/share/icons"; '
            + 'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS; '
            + 'for ext in svg png; do for base in $dirs; do [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null; done; '
            + 'find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null; done'
    }

    function indexIconLine(path) {
        var value = String(path || "").trim()
        if (!value) return
        var slash = value.lastIndexOf("/")
        var file = slash >= 0 ? value.slice(slash + 1) : value
        var dot = file.lastIndexOf(".")
        var name = dot > 0 ? file.slice(0, dot) : file
        if (name && pendingIconIndex[name] === undefined) pendingIconIndex[name] = value
    }

    function fallbackGlyph(provider) {
        return ({
            desktopapplications: "󰀻", files: "󰉋", calc: "󰃬", clipboard: "󰅌",
            tasks: "󰄬", sessions: "󰆍", commands: "󰆍", themes: "󰏘",
            websearch: "󰖟"
        })[provider] || "󰀻"
    }

    Process {
        id: iconIndexProcess
        command: ["bash", "-lc", root.iconIndexCommand()]
        stdout: SplitParser { onRead: data => root.indexIconLine(data) }
        stderr: StdioCollector { waitForEnd: true }
        running: true
        onExited: {
            root.iconIndex = root.pendingIconIndex
            root.iconIndexReady = true
        }
    }

    Rectangle {
        id: card
        x: root.cardX
        y: root.cardY
        width: root.cardWidth
        height: root.cardHeight
        radius: 12
        color: Color.menu.background
        border.color: Color.menu.border
        border.width: 1
        clip: true

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
            id: body
            anchors.fill: parent
            anchors.margins: 14
            spacing: 8

            Rectangle {
                id: searchField
                width: body.width
                height: root.inputHeight
                radius: 9
                color: Color.menu.selectedBackground
                border.color: Qt.darker(Color.menu.border, 1.1)
                border.width: 1

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 16
                    spacing: 14

                    Item {
                        width: 28
                        height: parent.height
                        Text {
                            anchors.centerIn: parent
                            text: "⌕"
                            color: Color.menu.text
                            font.family: "sans-serif"
                            font.pixelSize: 28
                        }
                    }
                    TextInput {
                        id: input
                        width: parent.width - 42
                        height: parent.height
                        verticalAlignment: TextInput.AlignVCenter
                        color: Color.menu.text
                        selectedTextColor: Color.menu.text
                        selectionColor: Color.menu.border
                        font.family: "sans-serif"
                        font.pixelSize: 21
                        selectByMouse: true
                        clip: true
                        text: root.controller.inputText
                        onTextChanged: root.controller.inputText = text
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: "Search apps, files, and more"
                            color: Color.menu.text
                            opacity: 0.48
                            font: input.font
                            visible: input.text.length === 0
                            elide: Text.ElideRight
                        }
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) root.controller.dismiss()
                            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.controller.activate()
                            else if (event.key === Qt.Key_Down || ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_J)) root.controller.move(1)
                            else if (event.key === Qt.Key_Up || ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_K)) root.controller.move(-1)
                            else { event.accepted = false; return }
                            event.accepted = true
                        }
                    }
                }
            }

            ListView {
                id: results
                width: body.width
                height: root.viewportHeight
                visible: root.controller.resultsModel.count > 0
                model: root.controller.resultsModel
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                spacing: 0
                currentIndex: root.controller.selectedIndex
                delegate: Rectangle {
                    id: resultRow
                    required property int index
                    required property string title
                    required property string subtitle
                    required property string provider
                    required property string icon
                    width: ListView.view.width
                    height: 48
                    radius: 7
                    color: index === root.controller.selectedIndex ? Color.menu.selectedBackground : "transparent"

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 12
                        spacing: 12
                        Item {
                            width: 32; height: parent.height
                            property bool iconFailed: false
                            property bool usingSemantic: false
                            property string semanticSource: root.resolveIcon("", resultRow.provider)
                            property string primarySource: root.resolveIcon(resultRow.icon, resultRow.provider)
                            onPrimarySourceChanged: { iconFailed = false; usingSemantic = false }
                            onSemanticSourceChanged: { iconFailed = false }
                            Image {
                                id: providerIcon
                                anchors.centerIn: parent
                                width: 27; height: 27
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                source: parent.usingSemantic ? parent.semanticSource : parent.primarySource
                                onStatusChanged: {
                                    if (status === Image.Error && !parent.usingSemantic) parent.usingSemantic = true
                                    else if (status === Image.Error) parent.iconFailed = true
                                }
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: parent.iconFailed || providerIcon.status === Image.Null
                                text: root.fallbackGlyph(resultRow.provider)
                                color: Color.menu.text
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 20
                            }
                        }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 44
                            spacing: 1
                            Text {
                                width: parent.width
                                text: resultRow.title
                                textFormat: Text.PlainText
                                color: Color.menu.text
                                font.family: "sans-serif"
                                font.pixelSize: 15
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                            Text {
                                width: parent.width
                                text: resultRow.subtitle || resultRow.provider
                                textFormat: Text.PlainText
                                color: Color.menu.text
                                opacity: 0.62
                                font.family: "sans-serif"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.controller.selectedIndex = resultRow.index; root.controller.activate() }
                    }
                }
            }

            Text {
                width: body.width
                visible: root.controller.lastError.length > 0 || root.controller.activating
                    || (root.controller.resultsModel.count === 0
                        && (root.controller.busy || root.controller.inputText.trim().length > 0))
                height: visible ? 24 : 0
                text: root.controller.lastError ? root.controller.lastError
                    : root.controller.activating ? "Opening…"
                    : root.controller.resultsModel.count > 0 ? ""
                    : root.controller.busy ? "Searching…" : "No results"
                textFormat: Text.PlainText
                color: root.controller.lastError ? "#f7768e" : Color.menu.text
                opacity: root.controller.lastError ? 1 : 0.62
                font.family: "sans-serif"
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }
}
