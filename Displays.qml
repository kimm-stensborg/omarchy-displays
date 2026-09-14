import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import "Layout.js" as Layout

// The bar button and its popup: brightness, text size, scale, which displays
// are on, and the way into Arrange displays. It replaces Omarchy's built-in
// Display panel (omarchy.monitor), and follows it closely -- the same cursor
// model, the same brightness debounce, the same text-size bridge -- except
// where the built-in is broken:
//
//   - Scale is written into the managed block of ~/.config/hypr/monitors.lua,
//     per display, and the reload that write causes is what applies it. The
//     built-in applies live and then seds one shared value into the file, and
//     the reload its own write triggers undoes the change a few seconds later.
//   - The arrangement is re-derived around the new size instead of the
//     rescaled display being parked at the end of the row by `auto`.
//   - Every valid scale for the display's actual mode is offered, not six
//     presets that collapse into each other.
//   - Switching a display off survives a restart.
Panel {
  id: root
  moduleName: "io.github.kimm-stensborg.displays"
  ipcTarget: "io.github.kimm-stensborg.displays"
  manageIpc: false

  // Injected for third-party entry points that declare them.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.displays"
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string script: root.pluginDir + "/monitors.py"

  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false

  // What Hyprland shows, and what the file declares.
  property var live: []
  property var rules: []
  property bool adopted: true
  property string statusMessage: ""

  // The declared layout laid over what is connected: what the rows show and
  // what a scale change is made against. Externals are on when the block says
  // so; the laptop panel is on when Omarchy's toggle and clamshell say so.
  readonly property var displays: Layout.layoutFrom(root.live, root.rules).layout
  readonly property int enabledDisplayCount: root.displays.filter(function(d) { return d.enabled }).length
  readonly property var focusedDisplay: {
    for (var i = 0; i < root.displays.length; i++) {
      if (root.displays[i].focused) return root.displays[i]
    }
    return null
  }
  readonly property string focusedMonitor: root.focusedDisplay ? root.focusedDisplay.name : ""

  // Every monitor's bar has its own copy of this widget, and an IPC target
  // belongs to whichever copy registered it first. So only the copy on the
  // focused screen holds it, and SUPER+CTRL+D opens the popup where you are
  // looking. `omarchy-shell shell toggle` cannot do this for a plugin that
  // also has an overlay: the shell routes that to the overlay. The claim waits
  // a beat, so the copy giving the target up has let go first.
  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    var screen = window && window.screen ? window.screen : null
    if (!screen) return ""
    if (typeof Hyprland.monitorFor === "function") {
      var hypr = Hyprland.monitorFor(screen)
      if (hypr && hypr.name) return String(hypr.name)
    }
    return String(screen.name || "")
  }
  readonly property bool focusedHere: root.screenName !== "" && !!Hyprland.focusedMonitor
    && root.screenName === String(Hyprland.focusedMonitor.name || "")
  property bool ipcOwner: false

  onFocusedHereChanged: {
    if (!root.focusedHere) root.ipcOwner = false
    else ipcClaim.restart()
  }

  Timer {
    id: ipcClaim
    interval: 150
    repeat: false
    onTriggered: root.ipcOwner = root.focusedHere
  }

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel. Only
  //                  present if a controllable backlight was detected.
  //   "textsize"   - single slider row, same sentinel.
  //   "scale"      - the focused display's valid scales; one row from j/k's
  //                  perspective, h/l walks it.
  //   "monitors"   - one row per display; j/k walks them.
  //   "arrange"    - the row that opens Arrange displays.
  // Mouse hover on a target updates root state, so keyboard cursor and
  // pointer share one highlight.
  readonly property var scaleValues: root.focusedDisplay
    ? Layout.scaleLadder(root.focusedDisplay.width, root.focusedDisplay.height) : []
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated notches (px). The panel snaps to these stops;
  // the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    if (scaleValues.length) list.push("scale")
    if (displays.length > 1) list.push("monitors")
    list.push("arrange")
    return list
  }

  function sectionCount(section) {
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    return section === "brightness" || section === "textsize" || section === "scale" || section === "arrange"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    if (section === "scale") return Math.max(0, activeScaleIndex())
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      toggleDisplay(displays[selectedIndex])
      return
    }
    if (focusSection === "arrange") openArrange()
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (focusSection === "arrange") selectedIndex = 0
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays).
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    root.setBrightness(Number(percent))
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.focusedDisplay ? Layout.scaleLabel(root.focusedDisplay.scale) : "",
      displays: root.displays.map(function(d) {
        return { name: d.name, selector: d.selector, enabled: d.enabled, focused: d.focused,
                 mode: Layout.modeString(d.width, d.height, d.refresh), position: d.x + "x" + d.y,
                 scale: Layout.formatScale(d.scale), transform: d.transform }
      })
    })
  }

  IpcHandler {
    enabled: root.ipcOwner
    target: root.ipcTarget

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!monitorsProc.running) monitorsProc.running = true
    if (!blockProc.running) blockProc.running = true
  }

  function readBrightness() {
    // A read right behind a set races the driver and can come back empty.
    if (brightnessProc.running || setBrightnessProc.running || brightnessDebounce.running) return
    if (!root.focusedMonitor) return
    brightnessProc.command = ["omarchy-brightness-display", "--monitor", root.focusedMonitor]
    brightnessProc.running = true
  }

  function setBrightness(value) {
    var percent = Layout.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Layout.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function activeScaleIndex() {
    var d = root.focusedDisplay
    if (!d) return -1
    for (var i = 0; i < scaleValues.length; i++) {
      if (Layout.sameScale(scaleValues[i], d.scale)) return i
    }
    return -1
  }

  function showStatus(text) {
    root.statusMessage = text
    statusTimer.restart()
  }

  // ---- Writing ----
  //
  // Every change goes out as a whole new block, built from the declared layout
  // with the one change made and the arrangement re-derived around it. The
  // local copy of the rules is updated at once, so a second click before the
  // file round-trip lands builds on the first instead of undoing it.

  property string pendingBlock: ""
  property bool writeQueued: false

  function commit(result) {
    if (!result) return
    if (!result.check.ok) {
      root.showStatus("Can't: " + result.check.reason)
      return
    }
    root.rules = Layout.parseBlock(result.block).rules
    root.pendingBlock = result.block
    if (writeProc.running) {
      root.writeQueued = true
      return
    }
    root.startWrite()
  }

  function startWrite() {
    root.writeQueued = false
    writeProc.command = ["python3", root.script, "write", "--text", root.pendingBlock]
    writeProc.running = true
  }

  function setScale(value) {
    var d = root.focusedDisplay
    if (!d) return
    root.commit(Layout.withChange(root.live, root.rules, d.name, { scale: Number(value) }))
  }

  function toggleDisplay(d) {
    if (!d) return
    if (d.enabled && root.enabledDisplayCount <= 1) return
    // The laptop panel goes through Omarchy's own toggle: clamshell switches a
    // `disabled` internal rule straight back on.
    if (d.internal) {
      internalProc.command = ["omarchy-hyprland-monitor-internal", d.enabled ? "off" : "on"]
      if (!internalProc.running) internalProc.running = true
      return
    }
    root.commit(Layout.withChange(root.live, root.rules, d.name, { enabled: !d.enabled }))
  }

  function openArrange() {
    root.close()
    var api = root.shell || (root.bar ? root.bar.shell : null)
    if (api && typeof api.summon === "function") api.summon(root.pluginId, "{}")
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    if (root.focusedHere) ipcClaim.restart()
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound summons land with
  // j/k ready to navigate. Keep a default landing point, but don't paint the
  // cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = sectionFirstIndex("scale")
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the popup is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh covers the rest.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Straight from hyprctl: omarchy-monitor-state drops x, y, transform,
  // description and availableModes.
  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.live = Layout.parseMonitors(text)
        root.readBrightness()
      }
    }
  }

  Process {
    id: blockProc
    command: ["python3", root.script, "read"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (!payload || !payload.ok) return
        // Don't overwrite the optimistic copy while our own write is out.
        if (writeProc.running || root.writeQueued) return
        root.adopted = payload.adopted === true
        root.rules = Layout.parseBlock(String(payload.block || "")).rules
      }
    }
  }

  Process {
    id: brightnessProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var brightness = String(String(text || "").split("\n")[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== "" && isFinite(parseInt(brightness, 10))
        if (root.brightnessAvailable) root.brightnessPercent = Math.max(0, Math.min(100, parseInt(brightness, 10)))
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT refresh after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading races the
    // hardware/driver and can return an empty string, visible as a "bounce to
    // zero" after h/l keypresses. External changes are still picked up by the
    // periodic refresh and the open-time refresh.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: writeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (payload && payload.ok) return
        if (payload && payload.status === "not-adopted") {
          root.adopted = false
          root.showStatus("Displays hasn't taken over monitors.lua yet")
        } else {
          root.showStatus("Couldn't write monitors.lua")
          console.warn(root.pluginId, "write:", payload ? (payload.error || (payload.errors || []).join("; ")) : text.trim())
        }
      }
    }
    onRunningChanged: {
      if (running) return
      if (root.writeQueued) root.startWrite()
      else refreshSoon.restart()
    }
  }

  Process {
    id: internalProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) refreshSoon.restart()
  }

  // Hyprland reloads after a write; read back once it has.
  Timer {
    id: refreshSoon
    interval: 900
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: statusTimer
    interval: 4000
    repeat: false
    onTriggered: root.statusMessage = ""
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "a") root.openArrange() }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Displays"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return Layout.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercentText.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercentText
                textFormat: Text.PlainText
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            visible: root.scaleValues.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.scaleValues.length > 0

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the display SCALE targets, always: it only ever applies
              // to the focused one, which is easy to lose track of.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedDisplay
                  ? Layout.displayName(root.focusedDisplay) + " · " + root.focusedDisplay.name : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideLeft
                anchors.left: scaleHeader.right
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              visible: root.enabledDisplayCount > 1
              textFormat: Text.PlainText
              text: "󰋼  Only the focused display changes. Focus another display to scale it, or use Arrange displays."
              color: Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: Math.max(1, Math.min(root.scaleValues.length, 5))
              spacing: Style.spacing.xs

              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: root.scaleValues

                Button {
                  id: pill
                  required property var modelData
                  required property int index

                  width: scaleRow.cellWidth
                  text: Layout.scaleLabel(modelData) + "x"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.sm
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true

                  active: root.activeScaleIndex() === pill.index
                  hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === pill.index

                  onClicked: root.setScale(pill.modelData)
                  onHovered: function(isHovered) {
                    if (!isHovered || root.reflowingText) return
                    root.cursorActive = true
                    root.focusSection = "scale"
                    root.selectedIndex = pill.index
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.statusMessage !== "" || !root.adopted
              textFormat: Text.PlainText
              text: root.statusMessage !== "" ? root.statusMessage : "Displays hasn't taken over monitors.lua yet"
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Displays ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              CursorSurface {
                id: monitorRow
                required property var modelData
                required property int index

                readonly property bool canToggle: !modelData.enabled || root.enabledDisplayCount > 1

                width: panelColumn.width
                hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === monitorRow.index
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
                current: modelData.focused
                foreground: root.bar.foreground
                fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
                currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
                implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
                opacity: canToggle ? 1.0 : 0.45

                Row {
                  id: monitorInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Text {
                    text: monitorRow.modelData.internal ? "󰌢" : "󰍹"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                    width: Style.space(22)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      text: Layout.displayName(monitorRow.modelData) + " · " + monitorRow.modelData.name
                            + (monitorRow.modelData.focused ? " · focused" : "")
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      width: parent.width
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: {
                        var d = monitorRow.modelData
                        if (!d.enabled) return "Off"
                        var size = Layout.logicalSize(d)
                        return d.width + "×" + d.height + " @ " + Layout.refreshLabel(d.refresh) + " Hz · "
                          + Layout.scaleLabel(d.scale) + "x · " + size.width + "×" + size.height + " logical"
                      }
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: parent.width
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: monitorRow.modelData.enabled ? "󰄬" : ""
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.subtitle
                    width: Style.space(14)
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                    root.cursorActive = true
                    root.focusSection = "monitors"
                    root.selectedIndex = monitorRow.index
                  }
                  onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.modelData)
                }
              }
            }
          }

          // ---------- Arrange displays… ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          CursorSurface {
            id: arrangeRow
            width: parent.width
            implicitHeight: arrangeInner.implicitHeight + Style.spacing.xl
            hasCursor: root.cursorActive && root.focusSection === "arrange"
            onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(arrangeRow)
            foreground: root.bar.foreground
            fill: Style.hoverFillFor(root.bar.foreground, Color.accent)

            Row {
              id: arrangeInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                text: "󰍺"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: "Arrange displays…"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  width: parent.width
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  text: "Position, resolution, refresh rate, rotation"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                  elide: Text.ElideRight
                }
              }

              Text {
                textFormat: Text.PlainText
                text: "󰅂"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                width: Style.space(14)
                horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                root.cursorActive = true
                root.focusSection = "arrange"
                root.selectedIndex = 0
              }
              onClicked: root.openArrange()
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }
}
