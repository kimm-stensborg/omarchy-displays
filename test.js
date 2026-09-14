#!/usr/bin/env node
// Displays tests.
//
//     node test.js        # prints every failure, exits 1 if any
//     qml6 test.qml       # Layout.js under QML's own engine (exit code only)
//
// Three layers, cheapest first:
//
//   1. Layout.js on its own: the scale ladder, the arrangement maths, the
//      block it renders and reads back.
//   2. The rendered block against the scripts that read monitors.lua. The
//      clamshell functions below are copied verbatim out of
//      omarchy-hyprland-monitor-clamshell and run under bash, and the
//      -scaling gates are its own grep patterns -- so "clamshell can read the
//      laptop's position" is checked against clamshell's sed, not against a
//      guess at it.
//   3. monitors.py driven through a scratch directory: the gate, adoption,
//      the no-op write, confirm, revert, and the watchdog.
//
// Layout.js is loaded by evaluating it minus the QML `.pragma library` line,
// and re-exporting whatever it declares at the top level.

const fs = require("fs")
const os = require("os")
const path = require("path")
const cp = require("child_process")

function loadLayout() {
  const src = fs.readFileSync(path.join(__dirname, "Layout.js"), "utf8")
    .replace(/^\s*\.pragma\s+library\s*$/m, "")
  const names = []
  for (const m of src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)) names.push(m[1])
  return new Function(src + "\nreturn {" + names.join(", ") + "}")()
}

const L = loadLayout()
let checks = 0
const failures = []

function check(label, got, want) {
  checks += 1
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g !== w) failures.push(`${label}\n      got  ${g}\n      want ${w}`)
}

function ok(label, cond) { check(label, !!cond, true) }

function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms) }

// ---------------------------------------------------------------- fixtures

// `hyprctl monitors all -j` on the desk this was built for, trimmed to the
// fields that matter: two identical Lenovos (which trade DP-5/DP-7 between
// boots, hence desc: with the serial) and the laptop panel on the right.
const DESK = [
  {
    name: "eDP-1", description: "AU Optronics B160UAN04.9", make: "AU Optronics",
    model: "B160UAN04.9 ", serial: "", width: 1920, height: 1200, refreshRate: 60.0,
    x: 5120, y: 0, scale: 1, transform: 0, disabled: false, focused: false,
    availableModes: ["1920x1200@60.00Hz", "1920x1200@60.00Hz"]
  },
  {
    name: "DP-5", description: "Lenovo Group Limited T27QD-40 VNACDZ1G", make: "Lenovo Group Limited",
    model: "T27QD-40", serial: "VNACDZ1G", width: 2560, height: 1440, refreshRate: 119.998,
    x: 2560, y: 0, scale: 1, transform: 0, disabled: false, focused: true,
    availableModes: ["2560x1440@59.95Hz", "2560x1440@120.00Hz", "1920x1080@60.00Hz"]
  },
  {
    name: "DP-7", description: "Lenovo Group Limited T27QD-40 VNACDZ5V", make: "Lenovo Group Limited",
    model: "T27QD-40", serial: "VNACDZ5V", width: 2560, height: 1440, refreshRate: 119.998,
    x: 0, y: 0, scale: 1, transform: 0, disabled: false, focused: false,
    availableModes: ["2560x1440@59.95Hz", "2560x1440@120.00Hz", "1920x1080@60.00Hz"]
  }
]

// The monitors.lua this machine had before the plugin: positions computed with
// string.format, one shared scale local at column 0. Both are what the
// managed-block rules forbid, which makes it the migration to test.
const LEGACY = `-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all
-- Layout (left → right): DP-7, DP-5, eDP-1 (laptop)
--
-- Positions are logical pixels (physical / scale). Hardcoding 2560/5120 leaves
-- gaps at scale > 1, and the cursor cannot cross a gap.

-- Keep these names: \`omarchy hyprland monitor scaling\` updates them in place.
local omarchy_gdk_scale = 1
local omarchy_monitor_scale = 1

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))

local function logical(px)
  return math.floor(px / omarchy_monitor_scale + 0.5)
end

local left_w = logical(2560)
local mid_w = logical(2560)

hl.monitor({
  output = "eDP-1",
  mode = "1920x1200@60",
  position = string.format("%dx0", left_w + mid_w),
  scale = omarchy_monitor_scale,
})

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
`

const live = L.parseMonitors(DESK)
const withLive = (patch) => L.parseMonitors(DESK.map(m => Object.assign({}, m, patch[m.name] || {})))
const positions = (layout) => layout.filter(m => m.enabled).map(m => [m.name, m.x, m.y])

// -------------------------------------------------------------- scale math

check("g for 2560x1440", L.modeDivisor(2560, 1440), 19200)
check("2560x1440 ladder", L.scaleLadder(2560, 1440).map(L.scaleLabel),
      ["1", "1.0667", "1.25", "1.3333", "1.6", "1.6667", "2", "2.1333", "2.5", "2.6667", "3.2", "3.3333", "4"])
check("1.5 is not valid at 2560x1440", L.isValidScale(1.5, 2560, 1440), false)
check("1.5 rounds up to 1.6", L.scaleLabel(L.cleanScale(1.5, 2560, 1440)), "1.6")
check("3 rounds up to 3.2", L.scaleLabel(L.cleanScale(3, 2560, 1440)), "3.2")
check("never rounds down", L.scaleLabel(L.cleanScale(1.26, 2560, 1440)), "1.3333")

check("g for 1920x1200", L.modeDivisor(1920, 1200), 28800)
{
  const ladder = L.scaleLadder(1920, 1200).map(L.scaleLabel)
  for (const s of ["1", "1.2", "1.25", "1.3333", "1.5", "1.6", "1.875", "2", "2.4", "2.5", "3", "3.2", "3.75", "4"])
    ok(`1920x1200 ladder has ${s}`, ladder.includes(s))
  check("1.5 is valid at 1920x1200", L.isValidScale(1.5, 1920, 1200), true)
  check("3 is valid at 1920x1200", L.isValidScale(3, 1920, 1200), true)
  check("and stays put", L.cleanScale(3, 1920, 1200), 3)
}

const PRESETS = ["1", "1.25", "1.6", "2", "2.5", "3.2", "4"]
check("offered at 2560x1440", L.scaleOptions(2560, 1440, 1).map(L.scaleLabel), PRESETS)
check("offered at 1920x1200", L.scaleOptions(1920, 1200, 1).map(L.scaleLabel), PRESETS)
check("a preset the mode can't do is offered as what it rounds up to",
      L.scaleOptions(1920, 1080, 1).map(L.scaleLabel), ["1", "1.25", "1.6", "2", "2.5", "3.3333", "4"])
check("an off-list current scale is still shown",
      L.scaleOptions(2560, 1440, 1.0666667).map(L.scaleLabel),
      ["1", "1.0667", "1.25", "1.6", "2", "2.5", "3.2", "4"])
check("an on-list current scale adds nothing", L.scaleOptions(2560, 1440, 1.6).length, 7)
check("no mode, no options", L.scaleOptions(0, 0, 1), [])

check("clamped to g/120 on a tiny mode", L.cleanScale(4, 2, 2), 2)
check("a mode below 1x still has a ladder", L.scaleLadder(1, 1), [1])
check("no mode, no ladder", L.scaleLadder(0, 1080), [])

// Every value on both ladders survives the round trip through the file.
for (const [w, h] of [[2560, 1440], [1920, 1200], [3840, 2160], [2880, 1800]]) {
  for (const s of L.scaleLadder(w, h)) {
    const written = L.formatScale(s)
    ok(`${w}x${h} ${written} matches valid_scale`, /^[0-9]+([.][0-9]+)?$/.test(written))
    ok(`${w}x${h} ${written} is valid when read back`, L.isValidScale(Number(written), w, h))
  }
}
check("Hyprland's float is the same scale", L.sameScale(1.06666672, "1.066667"), true)

check("GDK from the lowest", L.gdkScale([{ enabled: true, scale: 1 }, { enabled: true, scale: 1.6 }]), 1)
check("GDK rounds half up", L.gdkScale([{ enabled: true, scale: 1.5 }, { enabled: true, scale: 2 }]), 2)
check("GDK ignores disabled", L.gdkScale([{ enabled: false, scale: 1 }, { enabled: true, scale: 2 }]), 2)
check("GDK never below 1", L.gdkScale([]), 1)

// ------------------------------------------------------------------ modes

check("mode string", L.modeString(2560, 1440, 119.998), "2560x1440@120")
check("fractional refresh", L.modeString(2560, 1440, 59.951), "2560x1440@59.95")
check("modes deduplicated and ordered",
      L.parseModes(DESK[1].availableModes).map(m => m.label),
      ["2560x1440@120", "2560x1440@59.95", "1920x1080@60"])
check("panel with a doubled mode", L.parseModes(DESK[0].availableModes).length, 1)
check("resolutions", L.resolutions(live[0].modes).map(r => r.label), ["2560x1440", "1920x1080"])
check("nearest refresh", L.nearestRefresh(live[0].modes, 2560, 1440, 100), 120)

// --------------------------------------------------------------- monitors

check("sorted left to right", live.map(m => m.name), ["DP-7", "DP-5", "eDP-1"])
check("externals by desc with serial", live[0].selector, "desc:Lenovo Group Limited T27QD-40 VNACDZ5V")
check("laptop by connector", live[2].selector, "eDP-1")
check("laptop is internal", live[2].internal, true)
check("hyprctl's refresh is tidied", live[0].refresh, 120)
{
  const twins = L.parseMonitors([
    { name: "DP-1", description: "Acme X", width: 1920, height: 1080, x: 0, y: 0, scale: 1 },
    { name: "DP-2", description: "Acme X", width: 1920, height: 1080, x: 1920, y: 0, scale: 1 }
  ])
  check("serial-less twins fall back to connectors", twins.map(m => m.selector), ["DP-1", "DP-2"])
  const hostile = L.parseMonitors([{ name: "DP-1", description: 'Evil "--" Co', width: 1920, height: 1080, scale: 1 }])
  check("a description that can't be a Lua string falls back", hostile[0].selector, "DP-1")
}
check("rotated logical size", L.logicalSize({ width: 2560, height: 1440, scale: 1.25, transform: 1 }),
      { width: 1152, height: 2048 })

// --------------------------------------------------------------- geometry

const R = (name, x, y, width, height) => ({ name, x, y, width, height })
const LAYOUT = (rects) => rects.map(r => ({ name: r.name, enabled: true, x: r.x, y: r.y, width: r.width, height: r.height, scale: 1, transform: 0 }))

check("a row is valid", L.validate(L.layoutFrom(live, []).layout).ok, true)
check("an overlap is refused", L.validate(LAYOUT([R("A", 0, 0, 100, 100), R("B", 50, 0, 100, 100)])).ok, false)
check("a gap is refused", L.validate(LAYOUT([R("A", 0, 0, 100, 100), R("B", 110, 0, 100, 100)])).ok, false)
check("a corner is not an edge", L.validate(LAYOUT([R("A", 0, 0, 100, 100), R("B", 100, 100, 100, 100)])).ok, false)
check("nothing on is refused", L.validate([{ name: "A", enabled: false, x: 0, y: 0, width: 1, height: 1, scale: 1 }]).ok, false)

check("snap to an edge", L.snap(R("B", 2575, 12, 1920, 1200), [R("A", 0, 0, 2560, 1440)], 32), { x: 2560, y: 0 })
check("no snap from afar", L.snap(R("B", 2700, 300, 1920, 1200), [R("A", 0, 0, 2560, 1440)], 32), { x: 2700, y: 300 })
check("a dropped overlap attaches to the nearest edge",
      L.attach(R("B", 2400, 0, 1920, 1200), [R("A", 0, 0, 2560, 1440)]), { x: 2560, y: 0 })
check("a valid spot is left alone",
      L.attach(R("B", 2560, 100, 1920, 1200), [R("A", 0, 0, 2560, 1440)]), { x: 2560, y: 100 })
check("a row prefers the end of the row",
      L.attach(R("C", 2560, 0, 1920, 1200), [R("A", 0, 0, 2560, 1440), R("B", 2560, 0, 1920, 1200)]),
      { x: 4480, y: 0 })
check("nudge right keeps the row",
      L.nudge(R("A", 0, 0, 2560, 1440), [R("B", 2560, 0, 2560, 1440)], 1, 0), { x: 5120, y: 0 })
check("nudge down goes below", L.nudge(R("A", 0, 0, 2560, 1440), [R("B", 2560, 0, 2560, 1440)], 0, 1).y, 1440)

// ---------------------------------------------------------------- reflow

const adoption = L.adoptionBlock(live)
const declared = L.parseBlock(adoption).rules

{
  const r = L.withChange(live, declared, "DP-5", { scale: 1.25 })
  check("middle at 1.25 closes up", positions(r.layout), [["DP-7", 0, 0], ["DP-5", 2560, 0], ["eDP-1", 4608, 0]])
  ok("and says so in the block", r.block.includes('position = "4608x0", scale = 1'))
  ok("with the new scale", r.block.includes('position = "2560x0", scale = 1.25'))
  check("and is valid", r.check.ok, true)
}
{
  const r = L.withChange(live, declared, "DP-5", { scale: 1.5 })
  check("an invalid request is cleaned", L.find(r.layout, "DP-5").scale, 1.6)
}
{
  const r = L.withChange(live, declared, "DP-7", { transform: 1 })
  check("rotating the left one", positions(r.layout), [["DP-7", 0, 0], ["DP-5", 1440, 0], ["eDP-1", 4000, 0]])
  ok("rotation is written", r.block.includes(", transform = 1 })"))
}
{
  const r = L.withChange(live, declared, "DP-5", { enabled: false })
  check("switching off the middle closes the gap", positions(r.layout), [["DP-7", 0, 0], ["eDP-1", 2560, 0]])
  ok("an external is written disabled",
     r.block.includes('hl.monitor({ output = "desc:Lenovo Group Limited T27QD-40 VNACDZ1G", disabled = true })'))
  check("and is valid", r.check.ok, true)

  // Back on again, from what that write left behind.
  const after = L.parseBlock(r.block).rules
  const nowLive = withLive({ "DP-5": { disabled: true }, "eDP-1": { x: 2560 } })
  const back = L.withChange(nowLive, after, "DP-5", { enabled: true })
  check("switching it back on is valid", back.check.ok, true)
  ok("and it is on in the block", !back.block.includes("disabled = true"))
}
{
  const r = L.withChange(live, declared, "eDP-1", { enabled: false })
  ok("the laptop is never written disabled", !r.block.includes("disabled = true"))
  ok("its rule keeps describing it", r.block.includes('hl.monitor({ output = "eDP-1", mode = "1920x1200@60"'))
}
{
  // A stack: the smaller one centred under the bigger one.
  const before = [
    { name: "A", enabled: true, x: 0, y: 0, width: 2560, height: 1440, scale: 1, transform: 0 },
    { name: "B", enabled: true, x: 320, y: 1440, width: 1920, height: 1200, scale: 1, transform: 0 }
  ]
  const after = L.cloneLayout(before)
  after[0].scale = 2
  const r = L.reflow(before, after)
  check("a centred stack stays centred", positions(r), [["A", 320, 0], ["B", 0, 720]])
  check("and valid", L.validate(r).ok, true)
}
{
  const before = [
    { name: "A", enabled: true, x: 0, y: 0, width: 2560, height: 1440, scale: 1, transform: 0 },
    { name: "B", enabled: true, x: 3000, y: 0, width: 1920, height: 1080, scale: 1, transform: 0 }
  ]
  check("an old gap is closed", positions(L.reflow(before, L.cloneLayout(before))), [["A", 0, 0], ["B", 2560, 0]])
}

// ----------------------------------------------------------------- block

check("parse reads every rule back", declared.map(r => r.output),
      ["desc:Lenovo Group Limited T27QD-40 VNACDZ5V", "desc:Lenovo Group Limited T27QD-40 VNACDZ1G", "eDP-1"])
check("rendering what was parsed gives the same bytes",
      L.renderRules(declared, L.parseBlock(adoption).gdkScale), adoption)
{
  const again = L.layoutFrom(live, declared)
  check("and so does rebuilding it from the live monitors", L.renderBlock(again.layout, again.passthrough), adoption)
}
{
  // The office monitor keeps its rule while the laptop is away from it.
  const office = { output: "desc:Dell Inc. U2720Q 12345", disabled: false, mode: "3840x2160@60",
                   position: "0x-2160", scale: "1.5", transform: 0 }
  const base = L.layoutFrom(live, declared.concat([office]))
  check("an absent display passes through", base.passthrough, [office])
  ok("and stays in the block", L.renderBlock(base.layout, base.passthrough).includes(L.renderRule(office)))
}
for (const line of adoption.split("\n")) {
  if (line.startsWith("--")) continue
  for (const s of line.match(/"[^"]*"/g) || []) ok(`no -- inside ${s}`, !s.includes("--"))
}
ok("every rule starts at column 0 with hl.monitor({",
   adoption.split("\n").filter(l => l.includes("hl.monitor")).every(l => l.startsWith("hl.monitor({ ")))
ok("GDK_SCALE goes through tostring", adoption.includes('hl.env("GDK_SCALE", tostring(gdk_scale))'))
ok("catch-all scale is a name", adoption.includes('position = "auto", scale = fallback_scale })'))
ok("no omarchy_* scale locals", !/^local omarchy_(monitor|gdk)_scale/m.test(adoption))

// ------------------------------------------------------------ reconciler

check("nothing to reconcile", L.reconciled(live, declared), null)
{
  // omarchy-hyprland-monitor-scaling on DP-5: 1.6, and `position = "auto"`
  // parks it at the right-hand end of the row.
  const oob = withLive({ "DP-5": { scale: 1.6, x: 7040 } })
  check("divergence found", L.divergence(oob, declared).map(d => [d.name, d.live]), [["DP-5", 1.6]])
  const r = L.reconciled(oob, declared)
  check("recorded, and put back in the row", positions(r.layout),
        [["DP-7", 0, 0], ["DP-5", 2560, 0], ["eDP-1", 4160, 0]])
  ok("with the new scale written", r.block.includes('position = "2560x0", scale = 1.6'))
}
{
  // The same script with the scale already in place: nothing to write down,
  // but `auto` has still moved the display to the end of the row.
  const parked = withLive({ "DP-5": { x: 6528 } })
  check("an unchanged scale is not a divergence", L.divergence(parked, declared), [])
  check("but the position is drift", L.drift(parked, declared).map(d => [d.name, d.declared, d.live]),
        [["DP-5", [2560, 0], [6528, 0]]])
  check("a matching desk has no drift", L.drift(live, declared), [])
  const mirroring = withLive({ "eDP-1": { mirrorOf: "DP-5", x: 2560, scale: 2 } })
  check("a mirror is not drift", L.drift(mirroring, declared), [])
  check("nor a divergence", L.divergence(mirroring, declared), [])
}
check("float noise is not a divergence", L.divergence(withLive({ "DP-5": { scale: 1.0000001 } }), declared), [])
check("a switched-off display is not a divergence",
      L.divergence(withLive({ "eDP-1": { disabled: true, scale: 2 } }), declared), [])

// ------------------------------------------- the scripts that read the file

// Copied verbatim from omarchy-hyprland-monitor-clamshell.
const CLAMSHELL = String.raw`
MONITOR_LUA="$1"
lua_identifier() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}
lua_local_value() {
  local name="$1" value
  lua_identifier "$name" && [[ -f $MONITOR_LUA ]] || return 0

  value=$(sed -nE 's/^[[:space:]]*local[[:space:]]+'"$name"'[[:space:]]*=[[:space:]]*("[^"]*"|[^"[:space:]]+)[[:space:]]*(--.*)?$/\1/p' "$MONITOR_LUA" | head -1)
  [[ $value == \"*\" ]] && value="${"${"}value:1:-1}"
  printf '%s\n' "$value"
}
lua_scalar() {
  local value="$1" resolved

  if [[ $value == \"*\" ]]; then
    printf '%s\n' "${"${"}value:1:-1}"
    return
  fi

  resolved=$(lua_local_value "$value")
  printf '%s\n' "${"${"}resolved:-$value}"
}
monitor_rules() {
  [[ -f $MONITOR_LUA ]] || return 0

  sed -E -e 's/--\[\[[^]]*\]\]//g' -e 's/--.*$//' "$MONITOR_LUA"
}
monitor_rule_regex() {
  printf '^[[:space:]]*hl\\.monitor\\(\\{.*output[[:space:]]*=[[:space:]]*"%s"' "$1"
}
configured_monitor_value() {
  local output="$1" key="$2" value

  value=$(monitor_rules | sed -nE '/'"$(monitor_rule_regex "$output")"'/s/.*[{,;[:space:]]'"$key"'[[:space:]]*=[[:space:]]*("[^"]*"|[^,;}[:space:]]+)[[:space:]]*([,;}].*)?$/\1/p' | head -1)
  lua_scalar "$value"
}
configured_monitor_value "$2" "$3"
`

// omarchy-hyprland-monitor-scaling's persistence gates and GDK sed, as grep.
const GATES = String.raw`
grep -q '^local omarchy_monitor_scale = ' "$1" && echo A
grep -Eq '^hl\.monitor\(\{ output = "", mode = "preferred", position = "auto", scale = ("auto"|[0-9.]+) \}\)' "$1" && echo B
grep -Eq '^hl\.env\("GDK_SCALE", ".*"\)' "$1" && echo G
true
`

function clamshell(file, output, key) {
  return cp.spawnSync("bash", ["-c", CLAMSHELL, "clamshell", file, output, key], { encoding: "utf8" }).stdout.trim()
}

function gates(file) {
  return cp.spawnSync("bash", ["-c", GATES, "gates", file], { encoding: "utf8" }).stdout.trim().split("\n").filter(Boolean)
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "displays-test-"))
const LUA = path.join(scratch, "monitors.lua")
const ENV = Object.assign({}, process.env, {
  DISPLAYS_MONITORS_LUA: LUA,
  DISPLAYS_STATE_FILE: path.join(scratch, "state", "displays.json"),
  DISPLAYS_NO_RELOAD: "1"
})
const b64 = (s) => Buffer.from(s, "utf8").toString("base64")

function py(...args) {
  const r = cp.spawnSync("python3", [path.join(__dirname, "monitors.py")].concat(args), { env: ENV, encoding: "utf8" })
  try { return JSON.parse(r.stdout) } catch (e) { return { ok: false, raw: r.stdout, stderr: r.stderr } }
}

try {
  // The legacy file shows why the rules exist: both gates fire, and clamshell
  // cannot read the laptop's computed position.
  fs.writeFileSync(LUA, LEGACY)
  check("the legacy file re-arms -scaling", gates(LUA), ["A"])
  ok("clamshell can't read a computed position", !/^[-A-Za-z0-9_.+]+$/.test(clamshell(LUA, "eDP-1", "position")))

  // ------------------------------------------------------------ the gate
  check("the rendered block passes the gate", py("check", "--base64", b64(adoption)).ok, true)
  // What the QML sends: the block as one argv entry, no encoding.
  check("and arrives intact as plain --text", py("check", "--text", adoption).ok, true)
  const refused = {
    "an omarchy_monitor_scale local": adoption.replace("local gdk_scale = 1", "local omarchy_monitor_scale = 1"),
    "a computed position": adoption.replace('position = "5120x0"', 'position = string.format("%dx0", w)'),
    "an exponent scale": adoption.replace('"5120x0", scale = 1', '"5120x0", scale = 1e0'),
    "a literal catch-all scale": adoption.replace("scale = fallback_scale", "scale = 1"),
    "a space before {": adoption.replace('hl.monitor({ output = "eDP-1"', 'hl.monitor ({ output = "eDP-1"'),
    "-- inside a string": adoption.replace('"desc:Lenovo Group Limited T27QD-40 VNACDZ5V"',
                                          '"desc:Lenovo Group Limited T27QD--40 VNACDZ5V"'),
    "a block comment": adoption.replace("-- Anything not named", "--[[ Anything ]] not named"),
    "a literal GDK_SCALE": adoption.replace("tostring(gdk_scale)", '"1"'),
    "a missing catch-all": adoption.replace(/^hl\.monitor\(\{ output = "",.*\n/m, "")
  }
  for (const [what, block] of Object.entries(refused))
    check(`the gate refuses ${what}`, py("check", "--base64", b64(block)).ok, false)

  // --------------------------------------------------------- adoption
  check("write before adoption is refused", py("write", "--base64", b64(adoption)).status, "not-adopted")
  const adopt = py("adopt", "--base64", b64(adoption))
  check("adopt", adopt.status, "adopted")
  ok("with a backup of the old file", adopt.backup && fs.readFileSync(adopt.backup, "utf8") === LEGACY)
  const adoptedText = fs.readFileSync(LUA, "utf8")
  ok("the header is kept", adoptedText.startsWith(LEGACY.split("\n\n")[0] + "\n\n" + L.BEGIN_MARKER))
  ok("the block is in", adoptedText.includes(adoption))
  ok("the computed positions are gone", !adoptedText.includes("string.format"))
  check("the adopted file arms nothing", gates(LUA), [])
  check("clamshell reads the laptop's position", clamshell(LUA, "eDP-1", "position"), "5120x0")
  check("and its scale", clamshell(LUA, "eDP-1", "scale"), "1")
  check("the catch-all resolves through its local", clamshell(LUA, "", "scale"), "auto")
  check("adopting twice is a no-op", py("adopt", "--base64", b64(adoption)).status, "present")
  check("read sees the block", py("read").block, adoption)
  check("and no warnings", py("read").warnings, [])

  // ----------------------------------------------------------- writing
  const before = fs.statSync(LUA).mtimeMs
  sleep(20)
  check("an identical write is a no-op", py("write", "--base64", b64(adoption)).changed, false)
  check("and does not touch the file", fs.statSync(LUA).mtimeMs, before)

  const wider = L.withChange(live, declared, "DP-5", { scale: 1.25 }).block
  check("a real change is written", py("write", "--base64", b64(wider)).changed, true)
  const written = fs.readFileSync(LUA, "utf8")
  check("everything outside the block is untouched",
        written.split(L.BEGIN_MARKER)[0], adoptedText.split(L.BEGIN_MARKER)[0])
  check("clamshell follows the laptop", clamshell(LUA, "eDP-1", "position"), "4608x0")

  // ------------------------------------------- confirm, revert, watchdog
  const rotated = L.withChange(live, declared, "DP-7", { transform: 1 }).block
  check("a confirmable write", py("write", "--base64", b64(rotated), "--confirm-within", "30").changed, true)
  ok("is pending", py("read").pending !== null)
  check("revert", py("revert").status, "reverted")
  check("puts the file back exactly", fs.readFileSync(LUA, "utf8"), written)
  check("and is no longer pending", py("read").pending, null)

  py("write", "--base64", b64(rotated), "--confirm-within", "30")
  check("confirm", py("confirm").status, "confirmed")
  ok("keeps the change", fs.readFileSync(LUA, "utf8").includes(", transform = 1 })"))
  check("confirming twice is harmless", py("confirm").status, "nothing")

  const keptRotated = fs.readFileSync(LUA, "utf8")
  py("write", "--base64", b64(wider), "--confirm-within", "1")
  sleep(3000)
  check("the watchdog reverts an unconfirmed write", fs.readFileSync(LUA, "utf8"), keptRotated)

  py("write", "--base64", b64(wider), "--confirm-within", "30")
  const statePath = ENV.DISPLAYS_STATE_FILE
  const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
  state.deadline = Date.now() / 1000 - 5
  fs.writeFileSync(statePath, JSON.stringify(state))
  // The write's own watchdog is watching the same deadline and may get there
  // first; either way the lapsed write has to be gone.
  ok("recover reverts a lapsed deadline", ["reverted", "nothing"].includes(py("recover").status))
  check("back to the confirmed file", fs.readFileSync(LUA, "utf8"), keptRotated)
  check("and nothing is pending", py("read").pending, null)

  // An edit outside the block during the countdown survives the revert.
  py("write", "--base64", b64(wider), "--confirm-within", "30")
  fs.writeFileSync(LUA, "-- a note\n" + fs.readFileSync(LUA, "utf8"))
  check("a revert after an outside edit", py("revert").how, "block")
  ok("keeps the edit", fs.readFileSync(LUA, "utf8").startsWith("-- a note\n"))
  ok("and restores the block", fs.readFileSync(LUA, "utf8").includes(", transform = 1 })"))
} finally {
  // Give a watchdog still sleeping on the last snapshot a moment to notice
  // it is resolved before its directory goes.
  sleep(1200)
  fs.rmSync(scratch, { recursive: true, force: true })
}

// ------------------------------------------------------------------ report

if (failures.length) {
  for (const f of failures) console.error("  FAIL  " + f)
  console.error(`\n  ${failures.length} of ${checks} checks failed`)
  process.exit(1)
}
console.log(`  ok  ${checks} checks`)
