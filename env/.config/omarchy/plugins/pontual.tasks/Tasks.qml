import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Session manager for the task sessionizer. No search on purpose: j/k or
// arrows move, enter opens, x removes after a y/n, q or esc closes. All the
// work is done by ~/.config/tmux/scripts/task-sessionizer.sh.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string script: Quickshell.env("HOME") + "/.config/tmux/scripts/task-sessionizer.sh"

  property bool opened: false
  property int selectedIndex: 0
  // Which y/n question is showing: "", "remove", "force" or "kill".
  property string confirm: ""
  property string confirmName: ""
  property string message: ""
  property string fontFamily: Style.font.menuFamily

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int rowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int footerHeight: Style.font.body + Style.space(16)
  property int cardWidth: Math.min(Style.space(700), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(
    contentMargin * 2 + headerHeight + Math.max(1, rows.count) * (rowHeight + Style.space(4)) + footerHeight,
    panel.height - Style.gapsOut * 2)

  readonly property string footerText: {
    if (root.confirm === "remove")
      return "Remove task " + root.confirmName + "? Worktrees and session go, branches stay.   y / n"
    if (root.confirm === "force")
      return root.message + " Discard and remove anyway?   y / n"
    if (root.confirm === "kill")
      return "Kill session " + root.confirmName + "?   y / n"
    return root.message || "j/k or arrows: move  ·  enter: open  ·  x: remove  ·  q: close"
  }

  ListModel { id: rows }

  function open(payloadJson) {
    root.opened = true
    root.confirm = ""
    root.message = ""
    root.selectedIndex = 0
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "pontual.tasks")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    rowsProc.running = true
  }

  // Lines of "kind<TAB>name<TAB>detail" from `task-sessionizer.sh rows`.
  function loadRows(text) {
    rows.clear()
    var lines = (text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 2) continue
      rows.append({ kind: parts[0], name: parts[1], detail: parts[2] || "" })
    }
    if (root.selectedIndex >= rows.count) root.selectedIndex = Math.max(0, rows.count - 1)
  }

  function move(delta) {
    if (rows.count === 0) return
    root.message = ""
    root.selectedIndex = (root.selectedIndex + delta + rows.count) % rows.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate() {
    if (rows.count === 0) return
    var name = rows.get(root.selectedIndex).name
    root.dismiss()
    Quickshell.execDetached([root.script, "open", name])
  }

  function askRemove() {
    if (rows.count === 0) return
    var row = rows.get(root.selectedIndex)
    root.message = ""
    root.confirmName = row.name
    root.confirm = row.kind === "task" ? "remove" : "kill"
  }

  function answer(yes) {
    var kind = root.confirm
    root.confirm = ""
    if (!yes) {
      root.message = ""
      return
    }
    var args = kind === "kill" ? ["kill", root.confirmName] : ["rm", root.confirmName]
    if (kind === "force") args.push("--force")
    root.message = "working..."
    // One stream, with the exit code on the last line.
    actionProc.command = ["bash", "-c", "\"$0\" \"$@\" 2>&1; echo \"rc=$?\"", root.script].concat(args)
    actionProc.running = true
  }

  function actionDone(text) {
    var lines = (text || "").trim().split("\n")
    var rc = (lines.pop() || "").replace("rc=", "")
    var last = (lines.length ? lines[lines.length - 1] : "").replace(/^error: /, "")
    if (rc !== "0" && last.indexOf("use --force") >= 0) {
      root.message = last.replace(" (use --force)", ".")
      root.confirm = "force"
    } else {
      root.message = last
    }
    root.refresh()
  }

  Process {
    id: rowsProc
    command: [root.script, "rows"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadRows(text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionDone(text)
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "pontual-tasks"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // Every key is consumed: there is no search field to type into.
          event.accepted = true
          if (root.confirm) {
            root.answer(event.key === Qt.Key_Y)
          } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.dismiss()
          } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            root.move(1)
          } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
            root.move(-1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate()
          } else if (event.key === Qt.Key_X) {
            root.askRemove()
          }
        }
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Text {
          id: header
          textFormat: Text.PlainText
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.headerHeight
          text: "Tasks and sessions"
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }

        ListView {
          id: resultList
          anchors.top: header.bottom
          anchors.bottom: footer.top
          anchors.left: parent.left
          anchors.right: parent.right
          model: rows
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: row
            required property int index
            required property string kind
            required property string name
            required property string detail

            readonly property bool hasCursor: index === root.selectedIndex

            width: ListView.view.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: hasCursor ? root.selectedBackground : "transparent"

            Text {
              id: glyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.font.iconLarge
              text: row.kind === "task" ? "" : ""
              color: row.hasCursor ? root.selectedText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              anchors.left: glyph.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: row.name
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: row.detail
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            MouseArea {
              anchors.fill: parent
              onClicked: {
                if (root.confirm) return
                root.selectedIndex = row.index
                root.activate()
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: resultList
          visible: rows.count === 0
          text: "No tasks or sessions"
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          id: footer
          textFormat: Text.PlainText
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.footerHeight
          text: root.footerText
          color: root.foreground
          opacity: root.confirm ? 1 : 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          verticalAlignment: Text.AlignBottom
          elide: Text.ElideRight
        }
      }
    }
  }
}
