import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// Arrange displays: the drag canvas.
//
// Every display is drawn at its logical size -- physical size, rotated,
// divided by scale -- which is the size Hyprland lays it out at. So changing a
// scale visibly shrinks or grows the box. While a box is dragged, a ghost
// shows where it will land and the others slide aside to make room; whatever
// the move leaves behind closes up. So a gap or an overlap -- which Hyprland
// would accept, leaving a wall the pointer cannot cross -- is not a state the
// canvas can get into.
//
// Nothing is written until Apply, and Apply is the one change in this plugin
// that can leave the machine unusable, so it comes with a way back:
//
//   1. monitors.py stores the file as it was in ~/.local/state/omarchy/
//      displays.json, then writes the new block. Hyprland reloads; that is the
//      apply.
//   2. A countdown appears on every screen that exists after the reload.
//      Keep confirms; Revert, Escape, or letting it run out restores the old
//      file.
//   3. The deadline is also enforced by a detached watchdog process, and by
//      Reconcile.qml at the next shell start, so a crash of the shell in the
//      middle of all this still ends in the old layout.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.displays"
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string script: root.pluginDir + "/monitors.py"

  readonly property int confirmSeconds: 15

  property bool opened: false

  // ── model ─────────────────────────────────────────────────────────────────

  property var live: []
  property var rules: []
  property var passthrough: []
  property string currentBlock: ""
  property bool adopted: true
  property bool liveLoaded: false
  property bool blockLoaded: false

  // The layout being edited, and the one it started from. Keyed by live
  // output name, since that is what is on screen right now; the block is
  // written with each display's stable selector.
  property var working: []
  property var initial: []
  property string selected: ""
  property string statusMessage: ""

  // What the stage's Repeater is given. `working` changes on every edit, and
  // handing that to a Repeater would re-create every box out from under the
  // pointer; this only changes when the set of enabled displays does.
  property var stageNames: []

  readonly property var selectedMonitor: Layout.find(root.working, root.selected)
  readonly property var check: Layout.validate(root.working)
  readonly property string proposedBlock: Layout.renderBlock(Layout.normalize(root.working), root.passthrough)
  readonly property bool dirty: root.blockLoaded && root.proposedBlock !== root.currentBlock
  readonly property bool edited: JSON.stringify(Layout.renderBlock(root.initial, root.passthrough))
                                 !== JSON.stringify(Layout.renderBlock(root.working, root.passthrough))
  readonly property var offMonitors: root.working.filter(function(m) { return !m.enabled })
  readonly property int enabledCount: root.working.filter(function(m) { return m.enabled }).length
  readonly property bool busy: writeProc.running || internalProc.running

  readonly property string banner: {
    if (!root.adopted) return "Displays hasn't taken over monitors.lua yet; it does a moment after the shell starts"
    if (!root.check.ok) return root.check.reason
    return root.statusMessage
  }

  // ── theme: the same [menu] surface tokens the Omarchy menu uses ──────────

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.25)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int labelWidth: Style.space(110)

  // ── lifecycle ─────────────────────────────────────────────────────────────

  property string openScreen: ""

  function open(payloadJson) {
    var payload = ({})
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || ({})
    } catch (error) {
      console.warn(root.pluginId, "ignoring unreadable payload", payloadJson)
    }
    root.statusMessage = ""
    root.focusSection = "canvas"
    root.selectedIndex = 0
    root.cursorActive = false
    root.openScreen = root.focusedMonitorName()
    root.opened = true
    root.reload()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.cancelDrag()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function focusedMonitorName() {
    return Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
  }

  // The overlay opens on the screen that had focus, and stays there while you
  // work, rather than following the pointer across the displays being moved.
  readonly property var targetScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var hypr = typeof Hyprland.monitorFor === "function" ? Hyprland.monitorFor(screens[i]) : null
      var name = hypr && hypr.name ? String(hypr.name) : String(screens[i].name || "")
      if (name === root.openScreen) return screens[i]
    }
    return screens.length ? screens[0] : null
  }

  // Keep-loaded, so this runs once per shell start: a countdown that was
  // interrupted by a shell restart comes back up rather than silently lapsing.
  Component.onCompleted: readProc.running = true

  // ── reading ───────────────────────────────────────────────────────────────

  function reload() {
    root.liveLoaded = false
    root.blockLoaded = false
    if (!liveProc.running) liveProc.running = true
    if (!readProc.running) readProc.running = true
  }

  Process {
    id: liveProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.live = Layout.parseMonitors(text)
        root.liveLoaded = true
        root.maybeBuild()
      }
    }
  }

  Process {
    id: readProc
    command: ["python3", root.script, "read"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (!payload || !payload.ok) {
          console.warn(root.pluginId, "read:", text.trim())
          return
        }
        root.adopted = payload.adopted === true
        root.currentBlock = String(payload.block || "")
        root.rules = Layout.parseBlock(root.currentBlock).rules
        root.blockLoaded = true
        if (payload.pending && !root.confirming)
          root.startCountdown(Date.now() + Number(payload.pending.remaining) * 1000)
        root.maybeBuild()
      }
    }
  }

  function maybeBuild() {
    if (!root.liveLoaded || !root.blockLoaded || !root.opened) return
    var base = Layout.layoutFrom(root.live, root.rules)
    root.passthrough = base.passthrough
    root.initial = base.layout
    root.setWorking(base.layout)
    if (!Layout.find(root.working, root.selected)) {
      var focused = root.working.filter(function(m) { return m.focused && m.enabled })
      var enabled = root.working.filter(function(m) { return m.enabled })
      root.selected = focused.length ? focused[0].name : (enabled.length ? enabled[0].name : "")
    }
  }

  function setWorking(layout) {
    root.working = layout
    var names = layout.filter(function(m) { return m.enabled }).map(function(m) { return m.name })
    if (names.join("|") !== root.stageNames.join("|")) root.stageNames = names
    if (!root.dragName) root.frameStage()
  }

  // ── editing ───────────────────────────────────────────────────────────────

  function select(name) {
    root.selected = name
  }

  function selectAdjacent(delta) {
    var order = root.working.filter(function(m) { return m.enabled }).concat(root.offMonitors)
    if (!order.length) return
    var index = -1
    for (var i = 0; i < order.length; i++) if (order[i].name === root.selected) index = i
    index = (index + delta + order.length) % order.length
    root.selected = order[index].name
  }

  // One change to one display. Sizes may have changed, so the arrangement is
  // re-derived around it rather than left with a gap or an overlap.
  function edit(name, patch) {
    var before = root.working
    var after = Layout.cloneLayout(before)
    var e = Layout.find(after, name)
    if (!e) return
    for (var key in patch) e[key] = patch[key]
    e.scale = Layout.cleanScale(e.scale, e.width, e.height) || 1
    root.statusMessage = ""
    root.setWorking(Layout.reflow(before, after))
  }

  function setScale(value) {
    if (root.selectedMonitor) root.edit(root.selected, { scale: Number(value) })
  }

  function setResolution(label) {
    var m = root.selectedMonitor
    var mode = Layout.parseMode(label)
    if (!m || !mode) return
    root.edit(root.selected, {
      width: mode.width,
      height: mode.height,
      refresh: Layout.nearestRefresh(m.modes, mode.width, mode.height, m.refresh)
    })
  }

  function setRefresh(value) {
    if (root.selectedMonitor) root.edit(root.selected, { refresh: Number(value) })
  }

  function setTransform(value) {
    if (root.selectedMonitor) root.edit(root.selected, { transform: Number(value) & 7 })
  }

  // The laptop panel's on/off belongs to Omarchy's own toggle, which clamshell
  // respects and which refuses to turn off the last display; a `disabled`
  // rule for it would be switched straight back on by clamshell. So it takes
  // effect at once instead of waiting for Apply.
  function setEnabled(on) {
    var m = root.selectedMonitor
    if (!m || m.enabled === on) return
    if (!on && root.enabledCount <= 1) {
      root.statusMessage = "At least one display has to stay on"
      return
    }
    if (m.internal) {
      internalProc.command = ["omarchy-hyprland-monitor-internal", on ? "on" : "off"]
      if (!internalProc.running) internalProc.running = true
      return
    }
    root.edit(root.selected, { enabled: on })
  }

  function nudge(dx, dy) {
    var m = root.selectedMonitor
    if (!m || !m.enabled) return
    var moved = Layout.stepMove(root.working, m.name, dx, dy)
    if (!moved) return
    root.statusMessage = ""
    root.setWorking(Layout.normalize(moved.layout))
  }

  function reset() {
    root.setWorking(root.initial)
    root.statusMessage = ""
  }

  // ── dragging ──────────────────────────────────────────────────────────────

  property string dragName: ""
  property real dragX: 0
  property real dragY: 0
  // What the layout would be if the dragged box were let go now:
  // { layout, landing }. The other boxes are drawn from it, so they slide
  // aside as the drag goes, and the ghost is drawn at `landing`.
  property var dragPreview: null

  function dragTo(name, x, y, threshold) {
    root.dragName = name
    root.dragX = x
    root.dragY = y
    var preview = Layout.dropPreview(root.working, name, { x: x, y: y }, threshold)
    // Nowhere valid reachable from here: keep showing the last spot.
    if (preview) root.dragPreview = preview
  }

  function drop(name) {
    if (root.dragName !== name) return
    var preview = root.dragPreview
    root.dragName = ""
    root.dragPreview = null
    if (preview) {
      root.statusMessage = ""
      root.setWorking(Layout.normalize(preview.layout))
    } else {
      root.frameStage()
    }
  }

  function cancelDrag() {
    if (!root.dragName) return
    root.dragName = ""
    root.dragPreview = null
    root.frameStage()
  }

  // The part of the desk the stage shows, padded so there is room to drag a
  // display past the ends. Frozen while dragging, or the picture would slide
  // under the pointer as the bounds changed.
  property var viewBounds: ({ x: 0, y: 0, width: 1920, height: 1080 })

  function frameStage() {
    var rects = Layout.enabledRects(root.working)
    if (!rects.length) return
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < rects.length; i++) {
      minX = Math.min(minX, rects[i].x)
      minY = Math.min(minY, rects[i].y)
      maxX = Math.max(maxX, rects[i].x + rects[i].width)
      maxY = Math.max(maxY, rects[i].y + rects[i].height)
    }
    var pad = Math.max(maxX - minX, maxY - minY) * 0.18
    root.viewBounds = { x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2 }
  }

  // ── applying ──────────────────────────────────────────────────────────────

  property bool confirming: false
  property real deadline: 0
  property int secondsLeft: 0
  property int confirmIndex: 0

  function apply() {
    if (!root.check.ok || root.busy) return
    if (!root.dirty) {
      root.dismiss()
      return
    }
    writeProc.command = ["python3", root.script, "write", "--text", root.proposedBlock,
                         "--confirm-within", String(root.confirmSeconds)]
    writeProc.running = true
  }

  function startCountdown(deadlineMs) {
    root.deadline = deadlineMs
    root.confirmIndex = 0
    root.confirming = true
    root.updateCountdown()
  }

  function updateCountdown() {
    var left = Math.ceil((root.deadline - Date.now()) / 1000)
    root.secondsLeft = Math.max(0, left)
    if (left <= 0) root.revert()
  }

  function keep() {
    if (!root.confirming) return
    root.confirming = false
    confirmProc.running = true
    root.dismiss()
  }

  function revert() {
    if (!root.confirming) return
    root.confirming = false
    revertProc.running = true
  }

  Timer {
    interval: 200
    repeat: true
    running: root.confirming
    onTriggered: root.updateCountdown()
  }

  Process {
    id: writeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          root.statusMessage = payload && payload.status === "not-adopted"
            ? "monitors.lua has no managed block yet"
            : "Couldn't write monitors.lua: " + (payload ? (payload.error || (payload.errors || []).join("; ")) : text.trim())
          return
        }
        if (!payload.changed) {
          root.dismiss()
          return
        }
        root.currentBlock = root.proposedBlock
        root.startCountdown(Number(payload.deadline) * 1000)
      }
    }
  }

  Process {
    id: confirmProc
    command: ["python3", root.script, "confirm"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: revertProc
    command: ["python3", root.script, "revert"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.statusMessage = "Reverted to the previous layout"
        // Hyprland is reloading the old file; read after it has.
        reloadLater.restart()
      }
    }
  }

  Process {
    id: internalProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) reloadLater.restart()
  }

  Timer {
    id: reloadLater
    interval: 900
    repeat: false
    onTriggered: if (root.opened) root.reload()
  }

  // ── keyboard ──────────────────────────────────────────────────────────────
  //
  // The same cursor model as the bar popup: a focus section and an index in
  // it, shared with the pointer. j/k walk sections, h/l walk within one,
  // Enter or Space acts. On the canvas h/l (and Tab) pick a display and
  // Shift+H/J/K/L move it to the next free edge in that direction.

  property string focusSection: "canvas"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var scaleValues: root.selectedMonitor
    ? Layout.scaleOptions(root.selectedMonitor.width, root.selectedMonitor.height, root.selectedMonitor.scale) : []
  readonly property var resolutionOptions: {
    var m = root.selectedMonitor
    if (!m) return []
    var list = Layout.resolutions(m.modes)
    if (!list.length) list = [{ width: m.width, height: m.height, label: m.width + "x" + m.height }]
    return list.map(function(r) { return { value: r.label, label: r.width + " × " + r.height } })
  }
  readonly property var refreshOptions: {
    var m = root.selectedMonitor
    if (!m) return []
    var rates = Layout.refreshRates(m.modes, m.width, m.height)
    if (!rates.length) rates = [m.refresh]
    return rates.map(function(r) { return { value: String(r), label: Layout.refreshLabel(r) + " Hz" } })
  }
  readonly property var rotationOptions: Layout.TRANSFORMS.map(function(t) {
    return { value: String(t.value), label: t.label }
  })
  readonly property var actionNames: ["reset", "cancel", "apply"]

  readonly property var sections: {
    var m = root.selectedMonitor
    if (!m) return ["canvas", "actions"]
    if (!m.enabled) return ["canvas", "enabled", "actions"]
    return ["canvas", "scale", "resolution", "refresh", "rotation", "enabled", "actions"]
  }

  function sectionStart(section) {
    if (section === "scale") {
      var m = root.selectedMonitor
      for (var i = 0; m && i < root.scaleValues.length; i++) {
        if (Layout.sameScale(root.scaleValues[i], m.scale)) return i
      }
      return 0
    }
    if (section === "actions") return 2
    return 0
  }

  function moveCursor(delta) {
    var list = root.sections
    var index = list.indexOf(root.focusSection)
    var next = Math.max(0, Math.min(list.length - 1, (index < 0 ? 0 : index + delta)))
    root.focusSection = list[next]
    root.selectedIndex = root.sectionStart(root.focusSection)
  }

  function cycle(options, current, delta) {
    if (!options.length) return ""
    var index = 0
    for (var i = 0; i < options.length; i++) if (options[i].value === current) index = i
    return options[(index + delta + options.length) % options.length].value
  }

  function moveCursorH(delta) {
    var m = root.selectedMonitor
    var section = root.focusSection
    if (section === "canvas") root.selectAdjacent(delta)
    else if (section === "scale")
      root.selectedIndex = Math.max(0, Math.min(root.scaleValues.length - 1, root.selectedIndex + delta))
    else if (section === "resolution" && m)
      root.setResolution(root.cycle(root.resolutionOptions, m.width + "x" + m.height, delta))
    else if (section === "refresh" && m)
      root.setRefresh(root.cycle(root.refreshOptions, String(m.refresh), delta))
    else if (section === "rotation" && m)
      root.setTransform(root.cycle(root.rotationOptions, String(m.transform), delta))
    else if (section === "actions")
      root.selectedIndex = Math.max(0, Math.min(root.actionNames.length - 1, root.selectedIndex + delta))
  }

  function activateCursor() {
    var section = root.focusSection
    if (section === "scale" && root.selectedIndex < root.scaleValues.length)
      root.setScale(root.scaleValues[root.selectedIndex])
    else if (section === "enabled" && root.selectedMonitor)
      root.setEnabled(!root.selectedMonitor.enabled)
    else if (section === "actions")
      root.runAction(root.actionNames[root.selectedIndex])
  }

  function runAction(name) {
    if (name === "reset") root.reset()
    else if (name === "cancel") root.dismiss()
    else if (name === "apply") root.apply()
  }

  function hoverSection(section, index) {
    root.cursorActive = true
    root.focusSection = section
    root.selectedIndex = index
  }

  onSectionsChanged: {
    if (root.sections.indexOf(root.focusSection) < 0) {
      root.focusSection = "canvas"
      root.selectedIndex = 0
    }
  }
  onSelectedChanged: {
    if (root.focusSection === "scale") root.selectedIndex = root.sectionStart("scale")
  }

  // ── the editor ────────────────────────────────────────────────────────────

  PanelWindow {
    id: panel
    visible: root.opened && !root.confirming
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-displays"
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
      width: Math.min(Style.space(920), panel.width - Style.gapsOut * 2)
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      // BorderSurface only reports its insets; the content has to take them.
      PanelKeyCatcher {
        id: keys
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        blocked: resolutionDropdown.popupOpen || refreshDropdown.popupOpen || rotationDropdown.popupOpen
        onMoveRequested: function(dx, dy) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (dy !== 0) root.moveCursor(dy)
          else if (dx !== 0) root.moveCursorH(dx)
        }
        onActivateRequested: if (root.cursorActive) root.activateCursor()
        onCloseRequested: root.dismiss()
        onTabRequested: function(direction) { root.selectAdjacent(direction) }
        onTextKey: function(text) {
          if (text === "H") root.nudge(-1, 0)
          else if (text === "L") root.nudge(1, 0)
          else if (text === "K") root.nudge(0, -1)
          else if (text === "J") root.nudge(0, 1)
          else return
          root.cursorActive = true
          root.focusSection = "canvas"
        }

        Column {
          id: content
          width: parent.width
          spacing: Style.spacing.panelGap

          // ---------- header ----------
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              text: "Arrange displays"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
            }
            Text {
              width: parent.width
              text: "Drag to arrange. Apply writes monitors.lua; unless you keep the result, it reverts after "
                    + root.confirmSeconds + " seconds."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }
          }

          // ---------- the desk ----------
          Rectangle {
            id: stage
            width: parent.width
            height: Math.max(Style.space(220), Math.min(Style.space(380), width * 0.42))
            radius: Style.cornerRadius
            color: "transparent"
            border.width: root.cursorActive && root.focusSection === "canvas" ? 1 : 0
            border.color: root.hairline
            clip: true

            readonly property real factor: Math.min(width / root.viewBounds.width, height / root.viewBounds.height)
            readonly property real originX: (width - root.viewBounds.width * factor) / 2 - root.viewBounds.x * factor
            readonly property real originY: (height - root.viewBounds.height * factor) / 2 - root.viewBounds.y * factor

            onWidthChanged: root.frameStage()

            // Where the dragged display will land if let go now.
            Rectangle {
              id: ghost
              readonly property var landing: root.dragPreview ? root.dragPreview.landing : null
              visible: root.dragName !== "" && ghost.landing !== null
              x: stage.originX + (ghost.landing ? ghost.landing.x : 0) * stage.factor
              y: stage.originY + (ghost.landing ? ghost.landing.y : 0) * stage.factor
              width: Math.max(1, (ghost.landing ? ghost.landing.width : 0) * stage.factor)
              height: Math.max(1, (ghost.landing ? ghost.landing.height : 0) * stage.factor)
              z: 2
              radius: Style.cornerRadius
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
              border.width: 2
              border.color: root.accent

              Behavior on x {
                enabled: ghost.visible
                NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
              }
              Behavior on y {
                enabled: ghost.visible
                NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
              }
            }

            Repeater {
              model: root.stageNames

              Rectangle {
                id: box
                required property string modelData

                readonly property var mon: Layout.find(root.working, modelData)
                readonly property var rect: box.mon ? Layout.rectOf(box.mon) : ({ x: 0, y: 0, width: 0, height: 0 })
                readonly property bool dragged: root.dragName === box.modelData
                readonly property bool isSelected: root.selected === box.modelData
                // While another box is dragged, where this one would be.
                readonly property var shown: {
                  var preview = root.dragPreview && !box.dragged
                    ? Layout.find(root.dragPreview.layout, box.modelData) : null
                  return preview ? Layout.rectOf(preview) : box.rect
                }
                // No sliding in from the corner when the canvas first draws.
                property bool settled: false
                Component.onCompleted: Qt.callLater(function() { box.settled = true })

                x: stage.originX + (box.dragged ? root.dragX : box.shown.x) * stage.factor
                y: stage.originY + (box.dragged ? root.dragY : box.shown.y) * stage.factor
                width: Math.max(1, box.rect.width * stage.factor)
                height: Math.max(1, box.rect.height * stage.factor)
                z: box.dragged ? 3 : (box.isSelected ? 1 : 0)
                opacity: box.dragged ? 0.8 : 1

                Behavior on x {
                  enabled: box.settled && !box.dragged
                  NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                }
                Behavior on y {
                  enabled: box.settled && !box.dragged
                  NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                }
                radius: Style.cornerRadius
                color: box.isSelected ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFill
                border.width: box.isSelected ? 2 : 1
                border.color: box.isSelected ? root.accent : root.hairline

                Column {
                  anchors.centerIn: parent
                  width: parent.width - Style.spacing.md * 2
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: Layout.displayName(box.mon)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: box.mon ? box.mon.name + (box.mon.focused ? " · focused" : "") : ""
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: box.rect.width + " × " + box.rect.height + " · " + (box.mon ? Layout.scaleLabel(box.mon.scale) : "") + "x"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }
                }

                MouseArea {
                  id: grab
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                  property point pressAt: Qt.point(0, 0)
                  property bool moved: false

                  onPressed: function(mouse) {
                    grab.pressAt = grab.mapToItem(stage, mouse.x, mouse.y)
                    grab.moved = false
                    root.select(box.modelData)
                    root.hoverSection("canvas", 0)
                  }
                  onPositionChanged: function(mouse) {
                    if (!grab.pressed) return
                    var at = grab.mapToItem(stage, mouse.x, mouse.y)
                    if (!grab.moved && Math.abs(at.x - grab.pressAt.x) + Math.abs(at.y - grab.pressAt.y) < 4) return
                    grab.moved = true
                    root.dragTo(box.modelData,
                                box.rect.x + (at.x - grab.pressAt.x) / stage.factor,
                                box.rect.y + (at.y - grab.pressAt.y) / stage.factor,
                                Style.space(18) / stage.factor)
                  }
                  onReleased: if (grab.moved) root.drop(box.modelData)
                  onCanceled: root.cancelDrag()
                }
              }
            }
          }

          // ---------- displays that are off ----------
          Row {
            visible: root.offMonitors.length > 0
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Off:"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }

            Repeater {
              model: root.offMonitors

              Button {
                required property var modelData
                text: Layout.displayName(modelData) + " · " + modelData.name
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                active: root.selected === modelData.name
                onClicked: root.select(modelData.name)
              }
            }
          }

          // ---------- what's wrong, or what just happened ----------
          Text {
            width: parent.width
            visible: root.banner !== ""
            text: root.banner
            color: root.check.ok && root.adopted ? root.muted : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- the selected display ----------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.selectedMonitor !== null

            Text {
              text: root.selectedMonitor
                ? Layout.displayName(root.selectedMonitor) + " · " + root.selectedMonitor.name
                  + (root.selectedMonitor.description && !root.selectedMonitor.internal
                     ? " · " + root.selectedMonitor.description : "")
                : ""
              width: parent.width
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            // Scale: only the scales this mode can actually do.
            CursorSurface {
              width: parent.width
              visible: root.selectedMonitor !== null && root.selectedMonitor.enabled
              height: scaleRow.implicitHeight + Style.spacing.sm * 2
              hasCursor: false
              foreground: root.foreground

              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.spacing.sm + Style.spacing.controlPaddingY
                width: root.labelWidth
                text: "SCALE"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
              }

              Flow {
                id: scaleRow
                anchors.left: parent.left
                anchors.leftMargin: root.labelWidth
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                Repeater {
                  model: root.scaleValues

                  Button {
                    id: scalePill
                    required property var modelData
                    required property int index
                    text: Layout.scaleLabel(modelData) + "x"
                    fontSize: Style.font.caption
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.sm
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    active: root.selectedMonitor !== null && Layout.sameScale(modelData, root.selectedMonitor.scale)
                    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === index
                    onClicked: root.setScale(modelData)
                    onHovered: function(isHovered) { if (isHovered) root.hoverSection("scale", scalePill.index) }
                  }
                }
              }
            }

            // Resolution, refresh rate and rotation: h/l cycles through the
            // options without opening the list; a click opens it.
            Item {
              width: parent.width
              height: resolutionDropdown.implicitHeight
              visible: root.selectedMonitor !== null && root.selectedMonitor.enabled

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "RESOLUTION"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
              }
              Dropdown {
                id: resolutionDropdown
                anchors.left: parent.left
                anchors.leftMargin: root.labelWidth
                showLabel: false
                options: root.resolutionOptions
                value: root.selectedMonitor ? root.selectedMonitor.width + "x" + root.selectedMonitor.height : ""
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "resolution"
                onChanged: function(value) { root.setResolution(value) }
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("resolution", 0) }
              }
            }

            Item {
              width: parent.width
              height: refreshDropdown.implicitHeight
              visible: root.selectedMonitor !== null && root.selectedMonitor.enabled

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "REFRESH"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
              }
              Dropdown {
                id: refreshDropdown
                anchors.left: parent.left
                anchors.leftMargin: root.labelWidth
                showLabel: false
                options: root.refreshOptions
                value: root.selectedMonitor ? String(root.selectedMonitor.refresh) : ""
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "refresh"
                onChanged: function(value) { root.setRefresh(value) }
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("refresh", 0) }
              }
            }

            Item {
              width: parent.width
              height: rotationDropdown.implicitHeight
              visible: root.selectedMonitor !== null && root.selectedMonitor.enabled

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "ROTATION"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
              }
              Dropdown {
                id: rotationDropdown
                anchors.left: parent.left
                anchors.leftMargin: root.labelWidth
                showLabel: false
                options: root.rotationOptions
                value: root.selectedMonitor ? String(root.selectedMonitor.transform) : "0"
                fontFamily: root.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "rotation"
                onChanged: function(value) { root.setTransform(value) }
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("rotation", 0) }
              }
            }

            Item {
              width: parent.width
              height: enabledSwitch.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "ON"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                textFormat: Text.PlainText
              }
              ToggleSwitch {
                id: enabledSwitch
                anchors.left: parent.left
                anchors.leftMargin: root.labelWidth
                checked: root.selectedMonitor !== null && root.selectedMonitor.enabled
                busy: internalProc.running
                // The last display on cannot be switched off from here.
                interactive: root.selectedMonitor !== null
                  && (!root.selectedMonitor.enabled || root.enabledCount > 1)
                foreground: root.foreground
                accent: root.accent
                hasCursor: root.cursorActive && root.focusSection === "enabled"
                onToggled: if (root.selectedMonitor) root.setEnabled(!root.selectedMonitor.enabled)
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("enabled", 0) }
              }
              Text {
                anchors.left: enabledSwitch.right
                anchors.leftMargin: Style.spacing.lg
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.selectedMonitor !== null && root.selectedMonitor.internal
                text: "Uses Omarchy's laptop display toggle, and takes effect at once"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }
          }

          // ---------- footer ----------
          Item {
            width: parent.width
            height: applyButton.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: actions.left
              anchors.rightMargin: Style.spacing.lg
              text: "h/l or Tab pick a display · Shift+H/J/K/L move it · j/k walk the settings"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.md

              Button {
                text: "Reset"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                opacity: root.edited ? 1 : 0.45
                hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === 0
                onClicked: root.reset()
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("actions", 0) }
              }
              Button {
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === 1
                onClicked: root.dismiss()
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("actions", 1) }
              }
              Button {
                id: applyButton
                text: root.busy ? "Applying…" : "Apply"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                active: root.dirty && root.check.ok
                opacity: root.check.ok && root.adopted ? 1 : 0.45
                hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === 2
                onClicked: root.apply()
                onHovered: function(isHovered) { if (isHovered) root.hoverSection("actions", 2) }
              }
            }
          }
        }
      }
    }
  }

  // ── the countdown ─────────────────────────────────────────────────────────
  //
  // On every screen that exists after the reload, not just the one the editor
  // was on: that one may be the display that just went dark. Keyboard focus
  // goes to the focused screen's copy.

  Variants {
    model: root.confirming ? Quickshell.screens : []

    PanelWindow {
      id: confirmWindow
      required property var modelData
      screen: modelData

      readonly property bool focusedHere: {
        var hypr = typeof Hyprland.monitorFor === "function" ? Hyprland.monitorFor(confirmWindow.modelData) : null
        return !!hypr && !!Hyprland.focusedMonitor && hypr.name === Hyprland.focusedMonitor.name
      }

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-displays"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: confirmWindow.focusedHere ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Rectangle {
        anchors.fill: parent
        color: root.scrim
      }

      BorderSurface {
        id: confirmCard
        width: Math.min(Style.space(460), confirmWindow.width - Style.gapsOut * 2)
        height: confirmColumn.implicitHeight + confirmCard.contentTopInset + confirmCard.contentBottomInset
        anchors.centerIn: parent
        radius: Style.cornerRadius
        color: root.background
        borderSpec: root.borderSpec
        padding: root.contentMargin

        Item {
          anchors.fill: parent
          anchors.leftMargin: confirmCard.contentLeftInset
          anchors.rightMargin: confirmCard.contentRightInset
          anchors.topMargin: confirmCard.contentTopInset
          anchors.bottomMargin: confirmCard.contentBottomInset
          focus: true
          Component.onCompleted: if (confirmWindow.focusedHere) forceActiveFocus()

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) root.revert()
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              if (root.confirmIndex === 0) root.keep()
              else root.revert()
            } else if (event.key === Qt.Key_Left || event.text === "h" || event.key === Qt.Key_Backtab) root.confirmIndex = 0
            else if (event.key === Qt.Key_Right || event.text === "l" || event.key === Qt.Key_Tab) root.confirmIndex = 1
            else return
            event.accepted = true
          }

          Column {
            id: confirmColumn
            width: parent.width
            spacing: Style.spacing.panelGap

            Text {
              text: "Keep these display settings?"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
            }
            Text {
              width: parent.width
              text: "Reverting in " + root.secondsLeft + (root.secondsLeft === 1 ? " second" : " seconds")
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }
            Row {
              anchors.right: parent.right
              spacing: Style.spacing.md

              Button {
                text: "Keep"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                active: true
                hasCursor: root.confirmIndex === 0
                onClicked: root.keep()
                onHovered: function(isHovered) { if (isHovered) root.confirmIndex = 0 }
              }
              Button {
                text: "Revert"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                hasCursor: root.confirmIndex === 1
                onClicked: root.revert()
                onHovered: function(isHovered) { if (isHovered) root.confirmIndex = 1 }
              }
            }
          }
        }
      }
    }
  }
}
