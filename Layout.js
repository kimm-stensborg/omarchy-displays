.pragma library

// Everything Displays knows about monitors that is not I/O.
//
// No QML types, no processes, no files: every function here takes plain data
// and returns plain data, so node can test it (`node test.js`) and QML's V4
// engine can run it (`qml6 test.qml`). The panels feed it `hyprctl monitors
// all -j` and the rules parsed out of the managed block; monitors.py only ever
// gets the finished block text back.
//
// Two units run through all of it:
//
//   - Positions and sizes in a layout are logical pixels -- physical size,
//     rotated, divided by scale -- because that is what Hyprland positions
//     monitors in. A 2560-wide panel at 1.25 is 2048 wide here.
//   - Scales are compared in 1/120 steps, the unit Hyprland stores them in.
//     Floats that print differently (1.0666667 vs 1.066667) are one scale.

var UNITS = 120
var MIN_UNITS = 120   // 1x
var MAX_UNITS = 480   // 4x, the same ceiling omarchy-hyprland-monitor-scaling accepts

// The block this plugin owns inside ~/.config/hypr/monitors.lua. monitors.py
// matches these lines exactly, so they are defined once, here.
var BEGIN_MARKER = "-- >>> displays managed -- do not edit by hand"
var END_MARKER = "-- <<< displays managed"

// Omarchy's own test for a laptop panel (omarchy-monitor-state,
// omarchy-hyprland-monitor-laptop). A panel it does not recognise as internal
// is invisible to clamshell, so the same prefix decides it here.
var INTERNAL_PATTERN = /^(eDP|LVDS|DSI)-/
var CONNECTOR_PATTERN = /^[A-Za-z0-9._-]+$/
var POSITION_PATTERN = /^(-?[0-9]+)x(-?[0-9]+)$/

var TRANSFORMS = [
  { value: 0, label: "Normal" },
  { value: 1, label: "90°" },
  { value: 2, label: "180°" },
  { value: 3, label: "270°" },
  { value: 4, label: "Flipped" },
  { value: 5, label: "Flipped 90°" },
  { value: 6, label: "Flipped 180°" },
  { value: 7, label: "Flipped 270°" }
]

// ------------------------------------------------------------------ scale

function gcd(a, b) {
  a = Math.abs(Math.round(a))
  b = Math.abs(Math.round(b))
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

function scaleUnits(scale) {
  var n = Number(scale)
  return isFinite(n) && n > 0 ? Math.round(n * UNITS) : 0
}

// A scale is valid for a mode when the logical size is whole on both axes,
// which in 1/120 units means k divides both 120w and 120h -- so it divides
// their gcd, and every valid scale is a divisor of this one number.
function modeDivisor(width, height) {
  var w = Math.round(Number(width))
  var h = Math.round(Number(height))
  if (!(w > 0) || !(h > 0)) return 0
  return gcd(w * UNITS, h * UNITS)
}

// Clamped to the largest scale the mode allows, then rounded *up* to the next
// divisor -- never down, so asking for more room never gives less. Same rule
// as omarchy-hyprland-monitor-scaling's clean_scale.
function cleanUnits(scale, width, height) {
  var g = modeDivisor(width, height)
  if (!g) return 0
  var k = Math.max(1, scaleUnits(scale))
  if (k > g) k = g
  while (g % k !== 0) k++
  return k
}

function cleanScale(scale, width, height) {
  var k = cleanUnits(scale, width, height)
  return k ? k / UNITS : 0
}

function isValidScale(scale, width, height) {
  var k = scaleUnits(scale)
  var g = modeDivisor(width, height)
  return k > 0 && g > 0 && g % k === 0
}

// Every valid scale from 1x to 4x for this mode. A mode too small to reach 1x
// cleanly still gets the one scale it can do.
function scaleLadder(width, height) {
  var g = modeDivisor(width, height)
  if (!g) return []
  var out = []
  var top = Math.min(MAX_UNITS, g)
  for (var k = MIN_UNITS; k <= top; k++) {
    if (g % k === 0) out.push(k / UNITS)
  }
  if (out.length === 0) out.push(g / UNITS)
  return out
}

// The scales the popup and Arrange offer. All of them are valid at 2560x1440
// and 1920x1200; on a mode where one is not, it is offered as the scale it
// rounds up to, so no button promises something Hyprland would change.
var SCALE_PRESETS = [1, 1.25, 1.6, 2, 2.5, 3.2, 4]

// The presets cleaned for this mode and deduplicated, plus the current scale
// when it is none of them -- set from a terminal, say -- so the row always
// shows which one is active.
function scaleOptions(width, height, current) {
  var seen = {}
  var out = []
  function add(scale) {
    var k = cleanUnits(scale, width, height)
    if (!k || seen[k]) return
    seen[k] = true
    out.push(k / UNITS)
  }
  for (var i = 0; i < SCALE_PRESETS.length; i++) add(SCALE_PRESETS[i])
  if (isValidScale(current, width, height)) add(current)
  out.sort(function(a, b) { return a - b })
  return out
}

function trimNumber(text) {
  text = String(text)
  if (text.indexOf(".") < 0) return text
  return text.replace(/0+$/, "").replace(/\.$/, "")
}

// What goes into the file. Six places are enough for round(s * 120) to land
// on k exactly, and the result always matches clamshell's valid_scale,
// ^[0-9]+([.][0-9]+)?$ -- no exponent, no leading or trailing dot.
function formatScale(scale) {
  var k = scaleUnits(scale)
  if (!k) return "1"
  return trimNumber((k / UNITS).toFixed(6))
}

// What goes on a button: two decimals at most, so 1.0666667 reads 1.07. The
// exact value only ever goes into the file (formatScale).
function scaleLabel(scale) {
  var k = scaleUnits(scale)
  return k ? trimNumber((k / UNITS).toFixed(2)) : ""
}

function sameScale(a, b) {
  var k = scaleUnits(a)
  return k > 0 && k === scaleUnits(b)
}

// GTK only honours whole GDK_SCALE values, and there is one for the whole
// session. Taking it from the lowest-scaled screen keeps GTK apps from being
// oversized on the plain ones; hi-DPI screens upscale them instead.
function gdkScale(layout) {
  var lowest = 0
  for (var i = 0; i < (layout || []).length; i++) {
    var m = layout[i]
    if (!m || !m.enabled) continue
    var k = scaleUnits(m.scale)
    if (k && (!lowest || k < lowest)) lowest = k
  }
  if (!lowest) return 1
  return Math.max(1, Math.floor(lowest / UNITS + 0.5))
}

// ------------------------------------------------------------------ modes

function refreshLabel(refresh) {
  var n = Number(refresh)
  return isFinite(n) && n > 0 ? trimNumber(n.toFixed(2)) : ""
}

// "2560x1440@120", "2560x1440@59.95". Hyprland picks the closest real mode,
// so the two decimals hyprctl prints are all a rule needs.
function modeString(width, height, refresh) {
  var r = refreshLabel(refresh)
  return Math.round(Number(width)) + "x" + Math.round(Number(height)) + (r ? "@" + r : "")
}

function parseMode(text) {
  var m = /^([0-9]+)x([0-9]+)(?:@([0-9]+(?:\.[0-9]+)?)(?:Hz)?)?$/.exec(String(text || "").trim())
  if (!m) return null
  return {
    width: Number(m[1]),
    height: Number(m[2]),
    refresh: m[3] ? Number(refreshLabel(Number(m[3]))) : 0
  }
}

// availableModes, deduplicated (hyprctl lists 60.00Hz twice on some panels)
// and ordered largest first, fastest first.
function parseModes(list) {
  var seen = {}
  var out = []
  for (var i = 0; i < (list || []).length; i++) {
    var mode = parseMode(list[i])
    if (!mode) continue
    var key = modeString(mode.width, mode.height, mode.refresh)
    if (seen[key]) continue
    seen[key] = true
    mode.label = key
    out.push(mode)
  }
  out.sort(function(a, b) {
    return (b.width * b.height - a.width * a.height)
      || (b.width - a.width)
      || (b.refresh - a.refresh)
  })
  return out
}

function resolutions(modes) {
  var seen = {}
  var out = []
  for (var i = 0; i < (modes || []).length; i++) {
    var key = modes[i].width + "x" + modes[i].height
    if (seen[key]) continue
    seen[key] = true
    out.push({ width: modes[i].width, height: modes[i].height, label: key })
  }
  return out
}

function refreshRates(modes, width, height) {
  var out = []
  for (var i = 0; i < (modes || []).length; i++) {
    if (modes[i].width === width && modes[i].height === height) out.push(modes[i].refresh)
  }
  return out
}

function nearestRefresh(modes, width, height, refresh) {
  var rates = refreshRates(modes, width, height)
  if (rates.length === 0) return refresh
  var best = rates[0]
  for (var i = 1; i < rates.length; i++) {
    if (Math.abs(rates[i] - refresh) < Math.abs(best - refresh)) best = rates[i]
  }
  return best
}

// --------------------------------------------------------------- monitors

function isInternal(name) {
  return INTERNAL_PATTERN.test(String(name || ""))
}

// A value that can sit inside a Lua string in the block. clamshell strips
// comments with `s/--.*$//` before it knows where strings are, so `--` inside
// one would cut the rule in half; quotes and backslashes would end or escape
// the string.
function safeString(text) {
  text = String(text || "")
  return text.length > 0
    && text.indexOf('"') < 0
    && text.indexOf("\\") < 0
    && text.indexOf("--") < 0
    && !/[\x00-\x1f]/.test(text)
}

function byPosition(a, b) {
  return (a.x - b.x) || (a.y - b.y) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
}

// `hyprctl monitors all -j`, reduced to what a layout needs.
//
// Externals are named by description, serial included, because identical
// panels trade connector names between boots -- DP-5 today is DP-7 tomorrow.
// The laptop panel is named by connector: every Omarchy helper finds it with
// the (eDP|LVDS|DSI)- prefix, and a desc: rule would be invisible to them. A
// description two connected monitors share (no serial in the EDID) cannot
// tell them apart, so those fall back to the connector too.
function parseMonitors(raw) {
  var list = raw
  if (typeof raw === "string") {
    try { list = JSON.parse(raw) } catch (e) { list = [] }
  }
  if (!Array.isArray(list)) return []

  var descriptions = {}
  for (var i = 0; i < list.length; i++) {
    var d = String((list[i] && list[i].description) || "").trim()
    if (d) descriptions[d] = (descriptions[d] || 0) + 1
  }

  var out = []
  for (var j = 0; j < list.length; j++) {
    var m = list[j]
    if (!m || typeof m.name !== "string" || !m.name) continue
    var description = String(m.description || "").trim()
    var modes = parseModes(m.availableModes || [])
    var width = Number(m.width) || 0
    var height = Number(m.height) || 0
    var refresh = Number(m.refreshRate) || 0
    if ((width <= 0 || height <= 0) && modes.length) {
      width = modes[0].width
      height = modes[0].height
      refresh = modes[0].refresh
    }
    var internal = isInternal(m.name)
    var selector = m.name
    if (!internal && description && descriptions[description] === 1 && safeString("desc:" + description))
      selector = "desc:" + description

    out.push({
      name: m.name,
      description: description,
      make: String(m.make || "").trim(),
      model: String(m.model || "").trim(),
      serial: String(m.serial || "").trim(),
      selector: selector,
      // A name that cannot be written into Lua safely is shown but never declared.
      declarable: safeString(selector) && (selector.indexOf("desc:") === 0 || CONNECTOR_PATTERN.test(selector)),
      internal: internal,
      enabled: m.disabled !== true,
      focused: m.focused === true,
      width: width,
      height: height,
      refresh: Number(refreshLabel(refresh)) || 0,
      scale: Number(m.scale) > 0 ? Number(m.scale) : 1,
      transform: (Number(m.transform) || 0) & 7,
      x: Math.round(Number(m.x) || 0),
      y: Math.round(Number(m.y) || 0),
      mirrorOf: String(m.mirrorOf || "none"),
      modes: modes
    })
  }
  out.sort(byPosition)
  return out
}

function displayName(m) {
  if (!m) return ""
  if (m.internal) return "Built-in display"
  if (m.model) return m.model
  if (m.description) return m.description
  return m.name
}

function transformLabel(value) {
  for (var i = 0; i < TRANSFORMS.length; i++) {
    if (TRANSFORMS[i].value === value) return TRANSFORMS[i].label
  }
  return "Normal"
}

function find(layout, name) {
  for (var i = 0; i < (layout || []).length; i++) {
    if (layout[i].name === name) return layout[i]
  }
  return null
}

function cloneLayout(layout) {
  var out = []
  for (var i = 0; i < (layout || []).length; i++) {
    var copy = {}
    for (var key in layout[i]) copy[key] = layout[i][key]
    out.push(copy)
  }
  return out
}

// --------------------------------------------------------------- geometry

function logicalSize(m) {
  var w = Number(m.width) || 0
  var h = Number(m.height) || 0
  if ((Number(m.transform) || 0) % 2 === 1) {
    var t = w
    w = h
    h = t
  }
  var s = scaleUnits(m.scale) / UNITS || 1
  return { width: Math.round(w / s), height: Math.round(h / s) }
}

function rectOf(m) {
  var size = logicalSize(m)
  return { name: m.name, x: m.x, y: m.y, width: size.width, height: size.height }
}

function enabledRects(layout) {
  var out = []
  for (var i = 0; i < (layout || []).length; i++) {
    if (layout[i].enabled) out.push(rectOf(layout[i]))
  }
  return out
}

function overlaps(a, b) {
  return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
    && a.x < b.x + b.width && b.x < a.x + a.width
    && a.y < b.y + b.height && b.y < a.y + a.height
}

function span(a0, a1, b0, b1) {
  return Math.min(a1, b1) - Math.max(a0, b0)
}

// Sharing an edge along a stretch of positive length. Meeting at a corner is
// not touching: the pointer cannot cross a single point.
function touches(a, b) {
  if (a.x + a.width === b.x || b.x + b.width === a.x)
    return span(a.y, a.y + a.height, b.y, b.y + b.height) > 0
  if (a.y + a.height === b.y || b.y + b.height === a.y)
    return span(a.x, a.x + a.width, b.x, b.x + b.width) > 0
  return false
}

function gapBetween(a, b) {
  var dx = Math.max(0, Math.max(a.x, b.x) - Math.min(a.x + a.width, b.x + b.width))
  var dy = Math.max(0, Math.max(a.y, b.y) - Math.min(a.y + a.height, b.y + b.height))
  return dx + dy
}

// Hyprland accepts overlaps and gaps without complaint, and both leave dead
// zones: a gap is a wall the pointer cannot cross, an overlap is a region two
// screens claim. So a layout is only committed when every enabled display is
// joined to the others edge to edge, and none overlap.
function validate(layout) {
  var rects = enabledRects(layout)
  if (rects.length === 0) return { ok: false, reason: "At least one display has to stay on" }

  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      if (overlaps(rects[i], rects[j]))
        return { ok: false, reason: rects[i].name + " and " + rects[j].name + " overlap" }
    }
  }

  var reached = [0]
  var seen = {}
  seen[0] = true
  for (var q = 0; q < reached.length; q++) {
    for (var k = 0; k < rects.length; k++) {
      if (!seen[k] && touches(rects[reached[q]], rects[k])) {
        seen[k] = true
        reached.push(k)
      }
    }
  }
  for (var n = 0; n < rects.length; n++) {
    if (!seen[n])
      return { ok: false, reason: rects[n].name + " isn't touching the others, so the pointer can't reach it" }
  }
  return { ok: true, reason: "" }
}

// Hyprland is happy with any origin; the file reads better from 0x0.
function normalize(layout) {
  var out = cloneLayout(layout)
  var minX = Infinity
  var minY = Infinity
  for (var i = 0; i < out.length; i++) {
    if (!out[i].enabled) continue
    minX = Math.min(minX, out[i].x)
    minY = Math.min(minY, out[i].y)
  }
  if (!isFinite(minX)) return out
  for (var j = 0; j < out.length; j++) {
    if (!out[j].enabled) continue
    out[j].x -= minX
    out[j].y -= minY
  }
  return out
}

// Pull a dragged rectangle's edges onto nearby edges of the others: flush
// against a side, or lined up with a top, bottom, left or right.
function snap(rect, others, threshold) {
  var x = rect.x
  var y = rect.y
  var bestX = threshold + 1
  var bestY = threshold + 1
  for (var i = 0; i < (others || []).length; i++) {
    var o = others[i]
    var xs = [o.x, o.x + o.width, o.x - rect.width, o.x + o.width - rect.width]
    var ys = [o.y, o.y + o.height, o.y - rect.height, o.y + o.height - rect.height]
    for (var a = 0; a < xs.length; a++) {
      var dx = Math.abs(xs[a] - rect.x)
      if (dx <= threshold && dx < bestX) { bestX = dx; x = xs[a] }
    }
    for (var b = 0; b < ys.length; b++) {
      var dy = Math.abs(ys[b] - rect.y)
      if (dy <= threshold && dy < bestY) { bestY = dy; y = ys[b] }
    }
  }
  return { x: x, y: y }
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

function withPosition(rect, x, y) {
  return { name: rect.name, x: x, y: y, width: rect.width, height: rect.height }
}

function placementValid(rect, others) {
  if (!others.length) return true
  var touching = false
  for (var i = 0; i < others.length; i++) {
    if (overlaps(rect, others[i])) return false
    if (touches(rect, others[i])) touching = true
  }
  return touching
}

// Every spot where rect would sit flush against one of the others without
// overlapping any: each side of each other rectangle, lined up with its start,
// its end, or as close to rect's current offset as still shares an edge.
function attachCandidates(rect, others) {
  var raw = []
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    var ys = [o.y, o.y + o.height - rect.height, clamp(rect.y, o.y - rect.height + 1, o.y + o.height - 1)]
    var xs = [o.x, o.x + o.width - rect.width, clamp(rect.x, o.x - rect.width + 1, o.x + o.width - 1)]
    for (var a = 0; a < ys.length; a++) {
      raw.push({ x: o.x + o.width, y: ys[a] })
      raw.push({ x: o.x - rect.width, y: ys[a] })
    }
    for (var b = 0; b < xs.length; b++) {
      raw.push({ x: xs[b], y: o.y + o.height })
      raw.push({ x: xs[b], y: o.y - rect.height })
    }
  }
  var out = []
  var seen = {}
  for (var c = 0; c < raw.length; c++) {
    var key = raw[c].x + "," + raw[c].y
    if (seen[key]) continue
    seen[key] = true
    var moved = withPosition(rect, raw[c].x, raw[c].y)
    var clear = true
    for (var k = 0; k < others.length; k++) {
      if (overlaps(moved, others[k])) { clear = false; break }
    }
    if (clear) out.push(raw[c])
  }
  return out
}

// Where rect goes when dropped somewhere it cannot stay: the nearest spot
// flush against the others. Vertical travel costs double, because desks are
// rows far more often than stacks, and a monitor let go just off the end of a
// row belongs at the end of it rather than tucked under a corner.
function attach(rect, others) {
  if (placementValid(rect, others)) return { x: rect.x, y: rect.y }
  var candidates = attachCandidates(rect, others)
  var best = null
  var bestCost = Infinity
  for (var i = 0; i < candidates.length; i++) {
    var cost = Math.abs(candidates[i].x - rect.x) + 2 * Math.abs(candidates[i].y - rect.y)
    if (cost < bestCost) { bestCost = cost; best = candidates[i] }
  }
  return best || { x: rect.x, y: rect.y }
}

// Which side of `target` the point (cx, cy) is on: along whichever axis it is
// further from the centre, relative to the target's size.
function sideOf(target, cx, cy) {
  var fx = (cx - (target.x + target.width / 2)) / target.width
  var fy = (cy - (target.y + target.height / 2)) / target.height
  if (Math.abs(fx) >= Math.abs(fy)) return fx >= 0 ? "right" : "left"
  return fy >= 0 ? "below" : "above"
}

// The layout with `name` put beside `target`, and everything further along on
// that side moved over by its size to make room.
function insertBeside(layout, name, size, target, side) {
  var out = cloneLayout(layout)
  for (var i = 0; i < out.length; i++) {
    var n = out[i]
    if (!n.enabled || n.name === name) continue
    if (side === "right" && n.x >= target.x + target.width) n.x += size.width
    else if (side === "left" && n.x >= target.x) n.x += size.width
    else if (side === "below" && n.y >= target.y + target.height) n.y += size.height
    else if (side === "above" && n.y >= target.y) n.y += size.height
  }
  var e = find(out, name)
  e.x = side === "right" ? target.x + target.width : target.x
  e.y = side === "below" ? target.y + target.height : target.y
  return out
}

// A hole the moved display left behind is closed up. The frame is kept --
// nothing is normalised -- so a canvas can draw the result mid-drag without
// the picture jumping.
function settleDrop(layout, name) {
  var out = layout
  if (!validate(out).ok) out = reflow(out, out, true)
  if (!validate(out).ok) return null
  return { layout: out, landing: rectOf(find(out, name)) }
}

// Where a dragged display lands if let go with its top-left at rect.x/y, and
// where everything else goes to make room: { layout, landing }, or null if
// nothing valid can be reached from there.
//
// Over another display, it goes beside that one, on whichever side of it the
// pointer is, pushing what is further along that side over. Over open space,
// it snaps into line and attaches to the nearest free edge. Either way the
// result has no gap and no overlap, so a drop never needs refusing.
function dropPreview(layout, name, rect, threshold) {
  var m = find(layout, name)
  if (!m || !m.enabled) return null
  var size = logicalSize(m)
  var others = enabledRects(layout).filter(function(r) { return r.name !== name })
  var moving = { name: name, x: Math.round(rect.x), y: Math.round(rect.y), width: size.width, height: size.height }
  var cx = moving.x + size.width / 2
  var cy = moving.y + size.height / 2

  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    if (cx >= o.x && cx < o.x + o.width && cy >= o.y && cy < o.y + o.height)
      return settleDrop(insertBeside(layout, name, size, o, sideOf(o, cx, cy)), name)
  }

  var snapped = snap(moving, others, threshold || 0)
  moving.x = snapped.x
  moving.y = snapped.y
  var spot = attach(moving, others)
  var out = cloneLayout(layout)
  var e = find(out, name)
  e.x = spot.x
  e.y = spot.y
  return settleDrop(out, name)
}

// Keyboard move. Toward a neighbour that shares the edge, the display goes
// past it; with nothing on that side, it is dragged one of its own lengths
// that way.
function stepMove(layout, name, dx, dy) {
  var m = find(layout, name)
  if (!m || !m.enabled) return null
  var r = rectOf(m)
  var side = dx > 0 ? "right" : dx < 0 ? "left" : dy > 0 ? "below" : "above"
  var others = enabledRects(layout).filter(function(o) { return o.name !== name })
  var neighbour = null
  var bestCross = Infinity
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    if (!touches(r, o)) continue
    var beside = side === "right" ? o.x === r.x + r.width
      : side === "left" ? o.x + o.width === r.x
      : side === "below" ? o.y === r.y + r.height
      : o.y + o.height === r.y
    if (!beside) continue
    var cross = side === "right" || side === "left" ? Math.abs(o.y - r.y) : Math.abs(o.x - r.x)
    if (cross < bestCross) { bestCross = cross; neighbour = o }
  }
  if (neighbour) return settleDrop(insertBeside(layout, name, { width: r.width, height: r.height }, neighbour, side), name)
  return dropPreview(layout, name, { x: r.x + dx * r.width, y: r.y + dy * r.height }, Math.round(Math.max(r.width, r.height) / 4))
}

// How a child sat against its parent: which side, and how it lined up along
// that side -- flush with the start, flush with the end, centred, or at some
// fraction of the way along.
function relation(parent, child) {
  var side
  if (child.x >= parent.x + parent.width) side = "right"
  else if (child.x + child.width <= parent.x) side = "left"
  else if (child.y >= parent.y + parent.height) side = "below"
  else side = "above"

  var horizontal = side === "right" || side === "left"
  var p0 = horizontal ? parent.y : parent.x
  var pl = horizontal ? parent.height : parent.width
  var c0 = horizontal ? child.y : child.x
  var cl = horizontal ? child.height : child.width

  var align = "ratio"
  if (c0 === p0) align = "start"
  else if (c0 + cl === p0 + pl) align = "end"
  else if (2 * c0 + cl === 2 * p0 + pl) align = "center"
  return { side: side, align: align, ratio: pl > 0 ? (c0 - p0) / pl : 0 }
}

function placeBy(rel, parent, size) {
  var horizontal = rel.side === "right" || rel.side === "left"
  var p0 = horizontal ? parent.y : parent.x
  var pl = horizontal ? parent.height : parent.width
  var cl = horizontal ? size.height : size.width
  var c0 = p0
  // A parent that was switched off has collapsed to a point; line up with
  // where it was rather than with an end it no longer has.
  if (pl > 0) {
    if (rel.align === "end") c0 = p0 + pl - cl
    else if (rel.align === "center") c0 = p0 + Math.round((pl - cl) / 2)
    else if (rel.align === "ratio") c0 = p0 + Math.round(rel.ratio * pl)
  }
  if (rel.side === "right") return { x: parent.x + parent.width, y: c0 }
  if (rel.side === "left") return { x: parent.x - size.width, y: c0 }
  if (rel.side === "below") return { x: c0, y: parent.y + parent.height }
  return { x: c0, y: parent.y - size.height }
}

// Re-derive positions after sizes changed -- a new scale, mode or rotation, a
// display switched off or on -- keeping the arrangement's shape.
//
// `before` is the arrangement as it was, `after` the same displays with their
// new properties and old positions. Each display in `before` hangs off a
// neighbour it touched (breadth first from the top-left one), remembering the
// side and alignment; the new positions are rebuilt from those relations with
// the new sizes. A display switched off collapses to a point, so what hung off
// it closes up the gap. Anything newly switched on, or that ends up
// overlapping, is attached to the nearest free edge.
//
// Three in a row with the middle one going from 1x to 1.25x: 0 / 2560 / 5120
// becomes 0 / 2560 / 4608, instead of Hyprland's `auto` parking it at the end.
//
// keepFrame leaves the result where the top-left display was instead of moving
// it to 0x0, for drawing mid-drag.
function reflow(before, after, keepFrame) {
  var out = cloneLayout(after)
  var byName = {}
  for (var i = 0; i < out.length; i++) byName[out[i].name] = out[i]

  var old = {}
  var names = []
  for (var j = 0; j < (before || []).length; j++) {
    var b = before[j]
    if (!b.enabled || !byName[b.name]) continue
    old[b.name] = rectOf(b)
    names.push(b.name)
  }
  names.sort(function(p, q) { return byPosition(old[p], old[q]) })

  function newSize(name) {
    var m = byName[name]
    return m.enabled ? logicalSize(m) : { width: 0, height: 0 }
  }

  var placed = {}
  var order = []
  var rects = {}
  function put(name, pos) {
    var size = newSize(name)
    rects[name] = { name: name, x: pos.x, y: pos.y, width: size.width, height: size.height }
    placed[name] = true
    order.push(name)
  }

  if (names.length) {
    put(names[0], { x: old[names[0]].x, y: old[names[0]].y })
    var queue = [names[0]]
    while (order.length < names.length) {
      if (queue.length) {
        var parent = queue.shift()
        for (var n = 0; n < names.length; n++) {
          var child = names[n]
          if (placed[child] || !touches(old[parent], old[child])) continue
          put(child, placeBy(relation(old[parent], old[child]), rects[parent], newSize(child)))
          queue.push(child)
        }
      } else {
        // The old arrangement had a gap. Hang the closest stray off its
        // closest placed neighbour and carry on from there.
        var bestPair = null
        var bestGap = Infinity
        for (var p = 0; p < order.length; p++) {
          for (var s = 0; s < names.length; s++) {
            if (placed[names[s]]) continue
            var gap = gapBetween(old[order[p]], old[names[s]])
            if (gap < bestGap) { bestGap = gap; bestPair = [order[p], names[s]] }
          }
        }
        put(bestPair[1], placeBy(relation(old[bestPair[0]], old[bestPair[1]]), rects[bestPair[0]], newSize(bestPair[1])))
        queue.push(bestPair[1])
      }
    }
  }

  var newcomers = out.filter(function(m) { return m.enabled && !placed[m.name] })
  newcomers.sort(byPosition)
  for (var c = 0; c < newcomers.length; c++) put(newcomers[c].name, { x: newcomers[c].x, y: newcomers[c].y })

  var settled = []
  for (var o = 0; o < order.length; o++) {
    var rect = rects[order[o]]
    if (rect.width <= 0 || rect.height <= 0) continue
    if (!placementValid(rect, settled)) {
      var spot = attach(rect, settled)
      rect.x = spot.x
      rect.y = spot.y
    }
    settled.push(rect)
  }

  for (var w = 0; w < out.length; w++) {
    var r = rects[out[w].name]
    if (!r || !out[w].enabled) continue
    out[w].x = r.x
    out[w].y = r.y
  }
  return keepFrame ? out : normalize(out)
}

// ------------------------------------------------------------------ rules

function positionOf(rule) {
  var m = POSITION_PATTERN.exec(String(rule.position || ""))
  return m ? { x: Number(m[1]), y: Number(m[2]) } : { x: 0, y: 0 }
}

// One rule per line, at column 0, `hl.monitor({` with no space: clamshell
// finds rules with ^[[:space:]]*hl\.monitor\(\{ and reads one key at a time
// off the same line. position is a literal string, never an expression --
// clamshell cannot evaluate `a .. "x0"` and would fall back to `auto`.
function renderRule(rule) {
  if (rule.disabled) return 'hl.monitor({ output = "' + rule.output + '", disabled = true })'
  var line = 'hl.monitor({ output = "' + rule.output + '", mode = "' + rule.mode
    + '", position = "' + rule.position + '", scale = ' + rule.scale
  if (rule.transform) line += ", transform = " + rule.transform
  return line + " })"
}

function ruleLabel(rule) {
  var output = String(rule.output || "")
  if (output.indexOf("desc:") === 0) return output.substring(5)
  return isInternal(output) ? output + " (built-in display)" : output
}

// The laptop panel is never written as disabled: clamshell re-enables any
// internal panel whose scale it cannot read back, so switching it off goes
// through Omarchy's own toggle (omarchy-hyprland-monitor-internal), and its
// rule here keeps describing how it looks when it is on.
function ruleFor(m) {
  if (!m.internal && !m.enabled) return { output: m.selector, disabled: true }
  return {
    output: m.selector,
    disabled: false,
    mode: modeString(m.width, m.height, m.refresh),
    position: Math.round(m.x) + "x" + Math.round(m.y),
    scale: formatScale(m.scale),
    transform: (Number(m.transform) || 0) & 7
  }
}

// Enabled rules left to right, then disabled ones by name -- an order that
// depends only on the rules, so rendering what was parsed gives back the same
// bytes, and a write that changes nothing is recognisably a no-op.
function sortRules(rules) {
  var out = rules.slice()
  out.sort(function(a, b) {
    if (!!a.disabled !== !!b.disabled) return a.disabled ? 1 : -1
    if (!a.disabled) {
      var pa = positionOf(a)
      var pb = positionOf(b)
      if (pa.x !== pb.x) return pa.x - pb.x
      if (pa.y !== pb.y) return pa.y - pb.y
    }
    return a.output < b.output ? -1 : a.output > b.output ? 1 : 0
  })
  return out
}

// The whole managed block, markers included.
//
// Every line here is shaped by something else that reads this file:
//   - no `local omarchy_monitor_scale` / `omarchy_gdk_scale` at column 0, and
//     the catch-all's scale is an identifier -- either would match one of
//     omarchy-hyprland-monitor-scaling's persistence gates, whose sed then
//     rewrites the file behind this plugin's back;
//   - GDK_SCALE goes through tostring(): the literal-string form is what that
//     same script's GDK sed looks for;
//   - `--` only ever starts a comment, one per line, never inside a string.
function renderRules(rules, gdk) {
  var lines = [
    BEGIN_MARKER,
    "-- Written by the Displays plugin. Change it from the Displays bar popup or",
    "-- Setup displays; anything between these markers is replaced on the next change.",
    "local gdk_scale = " + Math.max(1, Math.round(Number(gdk) || 1)),
    'local fallback_scale = "auto"',
    'hl.env("GDK_SCALE", tostring(gdk_scale))'
  ]
  var sorted = sortRules(rules)
  for (var i = 0; i < sorted.length; i++) {
    lines.push("-- " + ruleLabel(sorted[i]))
    lines.push(renderRule(sorted[i]))
  }
  lines.push("-- Anything not named above is placed automatically")
  lines.push('hl.monitor({ output = "", mode = "preferred", position = "auto", scale = fallback_scale })')
  lines.push(END_MARKER)
  return lines.join("\n")
}

// A layout as a block. `passthrough` is the declared rules for displays that
// are not connected right now: the office monitor keeps its place in the file
// while the laptop is at home.
function renderBlock(layout, passthrough) {
  var rules = []
  for (var i = 0; i < (layout || []).length; i++) {
    if (layout[i].declarable === false) continue
    rules.push(ruleFor(layout[i]))
  }
  for (var j = 0; j < (passthrough || []).length; j++) rules.push(passthrough[j])
  return renderRules(rules, gdkScale(layout))
}

function extractBlock(text) {
  var lines = String(text || "").split("\n")
  var begin = lines.indexOf(BEGIN_MARKER)
  if (begin < 0) return ""
  for (var i = begin + 1; i < lines.length; i++) {
    if (lines[i] === END_MARKER) return lines.slice(begin, i + 1).join("\n")
  }
  return ""
}

function parseRule(line) {
  var m = /^hl\.monitor\(\{ (.*) \}\)$/.exec(line)
  if (!m) return null
  var fields = {}
  var pattern = /([A-Za-z_]+) = ("[^"]*"|[^,\s]+)/g
  var token
  while ((token = pattern.exec(m[1])) !== null) {
    var value = token[2]
    fields[token[1]] = value.charAt(0) === '"' ? value.substring(1, value.length - 1) : value
  }
  if (typeof fields.output !== "string") return null
  if (fields.disabled === "true") return { output: fields.output, disabled: true }
  return {
    output: fields.output,
    disabled: false,
    mode: fields.mode || "preferred",
    position: fields.position || "auto",
    scale: fields.scale || "1",
    transform: (Number(fields.transform) || 0) & 7
  }
}

// The block read back: this plugin's own rules, minus the catch-all.
function parseBlock(text) {
  var block = extractBlock(text)
  if (!block) return { found: false, gdkScale: 1, rules: [] }
  var lines = block.split("\n")
  var gdk = 1
  var rules = []
  for (var i = 0; i < lines.length; i++) {
    var g = /^local gdk_scale = ([0-9]+)$/.exec(lines[i])
    if (g) { gdk = Number(g[1]); continue }
    var rule = parseRule(lines[i])
    if (rule && rule.output !== "") rules.push(rule)
  }
  return { found: true, gdkScale: gdk, rules: rules }
}

function matchRule(monitor, rules) {
  for (var i = 0; i < (rules || []).length; i++) {
    var r = rules[i]
    if (r.output.indexOf("desc:") === 0) {
      var wanted = r.output.substring(5)
      if (wanted && (monitor.description === wanted || monitor.description.indexOf(wanted) === 0)) return r
    } else if (r.output === monitor.name) {
      return r
    }
  }
  return null
}

// The layout the file declares, laid over what is connected. Declared values
// win -- that is the whole point of persisting first -- except whether the
// laptop panel is on, which belongs to Omarchy's toggle and clamshell.
function layoutFrom(live, rules) {
  var used = []
  var layout = []
  for (var i = 0; i < (live || []).length; i++) {
    var e = cloneLayout([live[i]])[0]
    e.liveEnabled = live[i].enabled
    e.declared = false
    var r = matchRule(live[i], rules)
    if (r) {
      used.push(r)
      e.declared = true
      e.selector = r.output
      e.declarable = true
      if (r.disabled) {
        if (!e.internal) e.enabled = false
      } else {
        var mode = parseMode(r.mode)
        if (mode) {
          e.width = mode.width
          e.height = mode.height
          if (mode.refresh) e.refresh = mode.refresh
        }
        var pos = POSITION_PATTERN.exec(r.position)
        if (pos) {
          e.x = Number(pos[1])
          e.y = Number(pos[2])
        }
        var s = Number(r.scale)
        if (isFinite(s) && s > 0) e.scale = s
        e.transform = r.transform || 0
        if (!e.internal) e.enabled = true
      }
    }
    layout.push(e)
  }
  layout.sort(byPosition)
  var passthrough = (rules || []).filter(function(rule) { return used.indexOf(rule) < 0 })
  return { layout: layout, passthrough: passthrough }
}

// One change to one display, with the arrangement re-derived around it.
// patch is any of { scale, width, height, refresh, transform, enabled }.
function withChange(live, rules, name, patch) {
  var base = layoutFrom(live, rules)
  var after = cloneLayout(base.layout)
  var e = find(after, name)
  if (!e) return null
  for (var key in patch) e[key] = patch[key]
  e.scale = cleanScale(e.scale, e.width, e.height) || 1
  var arranged = reflow(base.layout, after)
  return {
    layout: arranged,
    passthrough: base.passthrough,
    block: renderBlock(arranged, base.passthrough),
    check: validate(arranged)
  }
}

// The first block written into a file that has none: exactly what Hyprland is
// showing right now, so taking the file over changes nothing on screen.
function adoptionBlock(live) {
  var base = layoutFrom(live, [])
  return renderBlock(normalize(base.layout), [])
}

// ------------------------------------------------------------- reconciler

// Displays taking part in a mirror, either side. Omarchy's mirror toggle puts
// them somewhere the block does not say, on purpose, so they are left alone.
function mirrored(live) {
  var names = {}
  for (var i = 0; i < (live || []).length; i++) {
    var target = live[i].mirrorOf
    if (target && target !== "none") {
      names[live[i].name] = true
      names[target] = true
    }
  }
  return names
}

// Displays whose live scale is not the one the block declares. Something
// applied it without writing it down -- omarchy-hyprland-monitor-scaling from
// SUPER+/ or the Omarchy menu, whose sed never matches a managed block.
function divergence(live, rules) {
  var out = []
  var skip = mirrored(live)
  for (var i = 0; i < (live || []).length; i++) {
    var m = live[i]
    if (!m.enabled || skip[m.name]) continue
    var r = matchRule(m, rules)
    if (!r || r.disabled) continue
    var declared = Number(r.scale)
    if (!(declared > 0)) continue
    if (scaleUnits(m.scale) !== scaleUnits(declared))
      out.push({ name: m.name, declared: declared, live: m.scale })
  }
  return out
}

// Displays at the declared scale but not at the declared position. The same
// script does this even when the scale it sets is the one already there: it
// always applies with `position = "auto"`, which parks the display at the end
// of the row. Nothing needs writing down -- the block is right -- so the
// answer is a reload.
function drift(live, rules) {
  var out = []
  var skip = mirrored(live)
  for (var i = 0; i < (live || []).length; i++) {
    var m = live[i]
    if (!m.enabled || skip[m.name]) continue
    var r = matchRule(m, rules)
    if (!r || r.disabled) continue
    var pos = POSITION_PATTERN.exec(String(r.position || ""))
    if (!pos) continue
    if (scaleUnits(m.scale) !== scaleUnits(Number(r.scale))) continue
    if (m.x !== Number(pos[1]) || m.y !== Number(pos[2]))
      out.push({ name: m.name, declared: [Number(pos[1]), Number(pos[2])], live: [m.x, m.y] })
  }
  return out
}

// The block with those scales written down, and the arrangement re-derived
// from the declared one -- not from the live positions, which `auto` has
// already scrambled. null when there is nothing to record.
function reconciled(live, rules) {
  var changes = divergence(live, rules)
  if (!changes.length) return null
  var base = layoutFrom(live, rules)
  var after = cloneLayout(base.layout)
  for (var i = 0; i < changes.length; i++) {
    var e = find(after, changes[i].name)
    if (e) e.scale = cleanScale(changes[i].live, e.width, e.height) || e.scale
  }
  var arranged = reflow(base.layout, after)
  return {
    changes: changes,
    layout: arranged,
    passthrough: base.passthrough,
    block: renderBlock(arranged, base.passthrough)
  }
}

// ------------------------------------------------------------- brightness

function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

function brightnessName(percent) {
  var p = Math.round(percent)
  if (p >= 95) return "Sun blast"
  if (p >= 80) return "Solar flare"
  if (p >= 65) return "Golden hour"
  if (p >= 45) return "Even day"
  if (p >= 30) return "Soft glow"
  if (p >= 20) return "Lamp light"
  if (p >= 10) return "Candlelit"
  return "Night owl"
}
