// Engine conformance for Layout.js. Run it with:
//
//     qml6 test.qml        # exits 0 if Layout.js loads and runs under V4
//
// The assertions live in test.js and run under node, because `qml6` on a
// stock Arch build swallows QML console output -- a failing check here can
// only report an exit code, which is useless for finding out what broke.
//
// What this file is for is the other half: Layout.js ships as a QML library
// and runs in QML's V4 engine, not in node. This exercises every entry point
// the panels call, so a syntax error or something V4 lacks fails here rather
// than in the bar at the next shell restart.

import QtQml
import "Layout.js" as Layout

QtObject {
  function exercise() {
    var raw = JSON.stringify([
      { name: "eDP-1", description: "AU Optronics B160UAN04.9", width: 1920, height: 1200,
        refreshRate: 60, x: 5120, y: 0, scale: 1, transform: 0, disabled: false,
        availableModes: ["1920x1200@60.00Hz"] },
      { name: "DP-5", description: "Lenovo Group Limited T27QD-40 VNACDZ1G", width: 2560, height: 1440,
        refreshRate: 119.998, x: 2560, y: 0, scale: 1, transform: 0, disabled: false, focused: true,
        availableModes: ["2560x1440@120.00Hz", "2560x1440@59.95Hz"] },
      { name: "DP-7", description: "Lenovo Group Limited T27QD-40 VNACDZ5V", width: 2560, height: 1440,
        refreshRate: 119.998, x: 0, y: 0, scale: 1, transform: 0, disabled: false,
        availableModes: ["2560x1440@120.00Hz"] }
    ])
    var live = Layout.parseMonitors(raw)
    if (live.length !== 3 || live[0].name !== "DP-7") throw new Error("parse")

    var ladder = Layout.scaleLadder(2560, 1440)
    if (ladder.length !== 13) throw new Error("ladder")
    if (Layout.scaleOptions(2560, 1440, 1).length !== 7) throw new Error("presets")
    if (Layout.scaleLabel(Layout.cleanScale(1.5, 2560, 1440)) !== "1.6") throw new Error("clean")
    if (!Layout.isValidScale(1.5, 1920, 1200)) throw new Error("valid")
    Layout.formatScale(ladder[1])
    Layout.sameScale(1, 1.0000001)
    Layout.gdkScale(live)
    Layout.refreshLabel(59.951)
    Layout.modeString(2560, 1440, 120)
    Layout.parseMode("2560x1440@120.00Hz")
    Layout.resolutions(live[0].modes)
    Layout.refreshRates(live[0].modes, 2560, 1440)
    Layout.nearestRefresh(live[0].modes, 2560, 1440, 100)
    Layout.displayName(live[0])
    Layout.transformLabel(1)
    Layout.logicalSize(live[0])
    Layout.enabledRects(live)

    var block = Layout.adoptionBlock(live)
    var parsed = Layout.parseBlock(block)
    if (parsed.rules.length !== 3) throw new Error("block")
    if (Layout.renderRules(parsed.rules, parsed.gdkScale) !== block) throw new Error("round trip")
    Layout.extractBlock("x\n" + block + "\ny")

    var change = Layout.withChange(live, parsed.rules, "DP-5", { scale: 1.25 })
    if (Layout.find(change.layout, "eDP-1").x !== 4608) throw new Error("reflow")
    if (!change.check.ok) throw new Error("validate")

    var rects = Layout.enabledRects(change.layout)
    Layout.snap(rects[0], rects.slice(1), 32)
    Layout.attach(rects[0], rects.slice(1))
    Layout.nudge(rects[0], rects.slice(1), 1, 0)
    Layout.normalize(change.layout)

    var drifted = Layout.parseMonitors(raw)
    drifted[1].scale = 1.6
    if (Layout.divergence(drifted, parsed.rules).length !== 1) throw new Error("divergence")
    if (!Layout.reconciled(drifted, parsed.rules)) throw new Error("reconciled")
    var parked = Layout.parseMonitors(raw)
    parked[1].x = 6528
    if (Layout.drift(parked, parsed.rules).length !== 1) throw new Error("drift")
    Layout.mirrored(parked)

    Layout.clampBrightness(140)
    Layout.brightnessName(50)
  }

  Component.onCompleted: {
    try { exercise() } catch (e) { Qt.exit(1); return }
    Qt.exit(0)
  }
}
