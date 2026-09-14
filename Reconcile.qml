import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Layout.js" as Layout

// Headless half of Displays: the part that makes enabling the plugin enough,
// and that keeps the file honest afterwards.
//
// `omarchy plugin add` clones files and flips a bit in shell.json; it never
// runs an install hook. So on every shell start this does, in order, what an
// installer would:
//
//   recover   undo an Apply whose confirm countdown was interrupted
//   adopt     take over ~/.config/hypr/monitors.lua, once, with a .bak
//   retire    disable the old omarchy-monitor-scale-persist unit, if present
//   menu      add Setup → Displays to the Omarchy menu, once
//
// Every one of them is a no-op once done, so running them at each start costs
// a few milliseconds and nothing else.
//
// After that it reconciles. Scale can still be changed behind the plugin's
// back: omarchy-hyprland-monitor-scaling is bound to SUPER+/ and sits in the
// Omarchy menu, applies live, and never writes it down (its sed does not match
// a managed block). Left alone, the next reload would silently undo it, and its
// `position = "auto"` has already knocked the monitor out of the row. So when a
// live scale disagrees with the block -- twice, a moment apart, with no write
// of our own still landing -- the new scale is written down and the
// arrangement re-derived around it. The write is the apply step: the reload it
// causes puts every monitor back where the block says.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.displays"
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string script: root.pluginDir + "/monitors.py"

  // What the file declares, as of the last read, and what Hyprland shows.
  property var rules: []
  property bool adopted: false
  property bool pending: false
  property real fileAge: 0
  property var live: []

  property bool ready: false
  property string stage: ""

  // A disagreement seen once, waiting for a second look before it is believed.
  property string candidate: ""
  // The disagreement last acted on. If exactly that one is still there after
  // acting, Hyprland is refusing it for some reason, and acting again would
  // only reload in a loop -- so it is left alone until the state changes.
  property string lastActed: ""
  property string warned: ""

  function parse(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function py(args) {
    return ["python3", root.script].concat(args)
  }

  function notify(body) {
    Quickshell.execDetached(["notify-send", "-a", "Displays", "Displays", body])
  }

  // ── startup ───────────────────────────────────────────────────────────────

  // Hyprland is not necessarily done reading its config when the shell comes
  // up, and adoption wants monitors that are actually enumerated.
  Timer {
    running: true
    interval: 1500
    repeat: false
    onTriggered: root.step("recover")
  }

  function step(next) {
    root.stage = next
    if (next === "recover") startProc.command = root.py(["recover"])
    else if (next === "adopt") startProc.command = root.py(["adopt", "--text", Layout.adoptionBlock(root.live)])
    else if (next === "retire") startProc.command = root.py(["retire"])
    else if (next === "menu") startProc.command = root.py(["menu"])
    else {
      root.ready = true
      root.sample()
      return
    }
    startProc.running = true
  }

  function afterStep(payload) {
    if (!payload || payload.ok === false) {
      var why = payload ? (payload.error || (payload.errors || []).join("; ") || payload.status) : "no reply"
      console.warn(root.pluginId, root.stage + ":", why)
    }

    if (root.stage === "recover") {
      if (payload && payload.status === "reverted")
        root.notify("An unconfirmed display change was undone")
      root.readBlock(function() {
        if (root.adopted) { root.step("retire"); return }
        root.readLive(function() {
          if (root.live.length) root.step("adopt")
          else root.step("retire")
        })
      })
    } else if (root.stage === "adopt") {
      if (payload && payload.status === "adopted")
        root.notify("Now managing ~/.config/hypr/monitors.lua. The previous file is kept as "
                    + String(payload.backup || "a .bak next to it").replace(Quickshell.env("HOME"), "~"))
      root.readBlock(function() { root.step("retire") })
    } else if (root.stage === "retire") {
      if (payload && payload.status === "disabled")
        root.notify("Disabled omarchy-monitor-scale-persist; Displays records scale changes now")
      root.step("menu")
    } else if (root.stage === "menu") {
      if (payload && payload.status === "added")
        root.notify("Added to the Omarchy menu under Setup → Displays")
      root.step("done")
    }
  }

  Process {
    id: startProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.afterStep(root.parse(text))
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim().length > 0) console.warn(root.pluginId, root.stage + ":", text.trim())
    }
  }

  // ── reading ───────────────────────────────────────────────────────────────

  property var readThen: null

  function readBlock(then) {
    if (readProc.running) return
    root.readThen = then || null
    readProc.running = true
  }

  Process {
    id: readProc
    command: root.py(["read"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = root.parse(text)
        if (payload && payload.ok) {
          root.adopted = payload.adopted === true
          root.rules = Layout.parseBlock(payload.block).rules
          root.pending = payload.pending !== null && payload.pending !== undefined
          root.fileAge = payload.age === null || payload.age === undefined ? 1e9 : Number(payload.age)
        }
        var then = root.readThen
        root.readThen = null
        if (then) then()
      }
    }
  }

  property var liveThen: null

  function readLive(then) {
    if (liveProc.running) return
    root.liveThen = then || null
    liveProc.running = true
  }

  // Straight from hyprctl: omarchy-monitor-state drops x, y, transform,
  // description and availableModes, and every one of them matters here.
  Process {
    id: liveProc
    command: ["hyprctl", "monitors", "all", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.live = Layout.parseMonitors(text)
        var then = root.liveThen
        root.liveThen = null
        if (then) then()
      }
    }
  }

  // ── reconciling ───────────────────────────────────────────────────────────

  // Hyprland announces hotplugs and reloads; a live scale change made through
  // `hyprctl eval` is not guaranteed an event of its own, so a slow poll backs
  // the events up. One hyprctl call every few seconds, and the block is only
  // re-read when the live state disagrees with the cached copy.
  Timer {
    interval: 2500
    repeat: true
    running: root.ready
    onTriggered: root.sample()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.ready) return
      var name = String(event.name || "")
      if (name.indexOf("monitor") === 0 || name === "configreloaded") settle.restart()
    }
  }

  Timer {
    id: settle
    interval: 800
    repeat: false
    onTriggered: root.sample()
  }

  Timer {
    id: secondLook
    interval: 1500
    repeat: false
    onTriggered: root.sample()
  }

  function settled() {
    root.candidate = ""
    root.lastActed = ""
    root.warned = ""
  }

  function sample() {
    if (!root.ready || writeProc.running || reloadProc.running) return
    root.readLive(function() {
      if (!Layout.divergence(root.live, root.rules).length && !Layout.drift(root.live, root.rules).length) {
        root.settled()
        return
      }
      // The cached block may simply be old -- the popup or Arrange may have
      // just written a new one. Read it fresh before believing anything.
      root.readBlock(root.judge)
    })
  }

  function judge() {
    // Mid-countdown the block is supposed to disagree with nothing yet; and a
    // file written in the last few seconds is a reload still landing, whose
    // monitors have not caught up with it.
    if (!root.adopted || root.pending || root.fileAge < 5) {
      root.candidate = ""
      return
    }
    var diverged = Layout.divergence(root.live, root.rules)
    // A scale change is written down, and its reload fixes positions too, so
    // drift only counts when the scales all agree.
    var drifted = diverged.length ? [] : Layout.drift(root.live, root.rules)
    if (!diverged.length && !drifted.length) {
      root.settled()
      return
    }

    var key = JSON.stringify({
      scale: diverged.map(function(d) { return [d.name, Layout.scaleUnits(d.live)] }),
      position: drifted.map(function(d) { return [d.name, d.live] })
    })
    if (key === root.lastActed) {
      if (root.warned !== key) {
        root.warned = key
        console.warn(root.pluginId, "Hyprland did not take the declared layout; leaving it:", key)
      }
      return
    }
    if (key !== root.candidate) {
      root.candidate = key
      secondLook.restart()
      return
    }
    root.candidate = ""
    root.lastActed = key

    if (!diverged.length) {
      // omarchy-hyprland-monitor-scaling applies with `position = "auto"` even
      // when the scale is unchanged. The block is already right; reloading it
      // puts the displays back.
      console.info(root.pluginId, "putting displays back where monitors.lua says:", key)
      reloadProc.running = true
      return
    }

    var result = Layout.reconciled(root.live, root.rules)
    if (!result) return
    var check = Layout.validate(result.layout)
    if (!check.ok) {
      console.warn(root.pluginId, "not recording an out-of-band scale change:", check.reason)
      return
    }
    console.info(root.pluginId, "recording out-of-band scale:", key)
    writeProc.command = root.py(["write", "--text", result.block])
    writeProc.running = true
  }

  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: writeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = root.parse(text)
        if (!payload || payload.ok !== true)
          console.warn(root.pluginId, "write:", payload ? (payload.error || (payload.errors || []).join("; ")) : text.trim())
        root.readBlock(null)
      }
    }
  }
}
