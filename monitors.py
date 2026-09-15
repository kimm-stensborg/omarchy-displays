#!/usr/bin/env python3
"""Managed-block writer for the io.github.kimm-stensborg.displays shell plugin.

The plugin owns one region of ~/.config/hypr/monitors.lua and nothing else in
the file:

    -- >>> displays managed -- do not edit by hand
    ...
    -- <<< displays managed

Writing that region *is* how a change is applied. Hyprland reloads its config
when the file is saved and applies all of it at once, so a change that has
been written cannot be undone by the reload. That is the failure the built-in
panel has: it applies live and then persists, and the reload its own write
triggers puts the old declared value straight back.

Layout.js builds the block; this only checks it and puts it in place. Every
subcommand speaks JSON on stdout:

  read                                the block, and the state around it
  check   --text|--base64 <block>     validate a block, write nothing
  adopt   --text|--base64 <block>     take over a file with no block (once)
  write   --text|--base64 <block> [--confirm-within SECONDS]
  confirm                             keep what the last confirmable write did
  revert                              undo it now
  recover                             undo it if its deadline passed unconfirmed
  menu                                add "Displays" to the Omarchy menu, once
  retire                              disable the old omarchy-monitor-scale-persist unit
  supersede --stock in|out            answer, once, whether to take Omarchy's
                                      own Display widget off the bar
  bind                                point SUPER + / at this plugin, once
"""

import base64
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

PLUGIN_ID = "io.github.kimm-stensborg.displays"
HOME = os.path.expanduser("~")


def _env_dir(name, fallback):
    value = os.environ.get(name, "")
    return value if os.path.isabs(value) else fallback


# Overridable so test.js can run every path against a scratch directory.
MONITORS_LUA = os.environ.get("DISPLAYS_MONITORS_LUA") or os.path.join(
    HOME, ".config", "hypr", "monitors.lua"
)
STATE_FILE = os.environ.get("DISPLAYS_STATE_FILE") or os.path.join(
    _env_dir("XDG_STATE_HOME", os.path.join(HOME, ".local", "state")), "omarchy", "displays.json"
)
NO_RELOAD = os.environ.get("DISPLAYS_NO_RELOAD") == "1"

# Same strings as Layout.js's BEGIN_MARKER / END_MARKER, matched as whole lines.
BEGIN = "-- >>> displays managed -- do not edit by hand"
END = "-- <<< displays managed"

# ------------------------------------------------------------------ the gate
#
# Every rule below exists because of something else that reads this file.
# omarchy-hyprland-monitor-clamshell is the only real parser of it, and it is
# line-oriented sed; omarchy-hyprland-monitor-scaling decides whether to sed
# the file by pattern-matching it. The block has to stay legible to the first
# and invisible to the second.

RULE = re.compile(r"^hl\.monitor\(\{ (.*) \}\)$")
FIELD = re.compile(r'([A-Za-z_]+) = ("[^"]*"|[^,\s]+)')
NUMBER = re.compile(r"^[0-9]+([.][0-9]+)?$")  # clamshell's valid_scale
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
POSITION = re.compile(r"^-?[0-9]+x-?[0-9]+$")
MODE = re.compile(r"^([0-9]+x[0-9]+(@[0-9]+([.][0-9]+)?)?|preferred|highres|highrr)$")
CONNECTOR = re.compile(r"^[A-Za-z0-9._-]+$")
GDK_ENV = 'hl.env("GDK_SCALE", tostring(gdk_scale))'

# omarchy-hyprland-monitor-scaling's persistence gates and its GDK sed,
# verbatim. Anything in the block matching one would have that script rewrite
# the file behind the plugin's back -- and arm the reload that reverts it.
SCALING_GATE_A = re.compile(r"^local omarchy_monitor_scale = ", re.M)
SCALING_GATE_B = re.compile(
    r'^hl\.monitor\(\{ output = "", mode = "preferred", position = "auto", scale = ("auto"|[0-9.]+) \}\)',
    re.M,
)
GDK_SED = re.compile(r'^hl\.env\("GDK_SCALE", ".*"\)', re.M)
COLUMN0_RULE = re.compile(r"^hl\.monitor\(", re.M)


def check_rule(line):
    match = RULE.match(line)
    if not match:
        return ["a rule is one line starting `hl.monitor({ ` at column 0"]
    content = match.group(1)
    tokens = FIELD.findall(content)
    # Everything between the braces has to be `key = value` pairs and nothing
    # else, or clamshell's one-key-at-a-time sed reads something other than
    # what Hyprland's Lua does.
    if ", ".join("%s = %s" % token for token in tokens) != content:
        return ["cannot read the rule as plain key = value pairs"]
    fields = dict(tokens)
    if len(fields) != len(tokens):
        return ["a key appears twice"]

    errors = []
    for _, value in tokens:
        # clamshell strips `--.*$` before it knows where strings are.
        if value.startswith('"') and "--" in value:
            errors.append("`--` inside a string cuts the rule in half for clamshell")

    output = fields.get("output")
    if output is None or not output.startswith('"'):
        return errors + ["output must be a quoted string"]
    name = output[1:-1]

    if name == "":
        # A literal here byte-matches -scaling's second gate.
        if not IDENT.match(fields.get("scale", "")):
            errors.append("the catch-all's scale must be a name, never a number or \"auto\"")
        return errors

    if not (name.startswith("desc:") or CONNECTOR.match(name)):
        errors.append("output is neither desc:<description> nor a connector name")

    if fields.get("disabled") == "true":
        if set(fields) != {"output", "disabled"}:
            errors.append("a disabled rule carries only output and disabled")
        return errors

    extra = set(fields) - {"output", "mode", "position", "scale", "transform", "mirror"}
    if extra:
        errors.append("unexpected keys: %s" % ", ".join(sorted(extra)))
    position = fields.get("position", "")
    if not (position.startswith('"') and POSITION.match(position[1:-1])):
        errors.append('position must be a literal string such as "2560x0"')
    scale = fields.get("scale", "")
    if not (NUMBER.match(scale) or IDENT.match(scale)):
        errors.append("scale must be a plain number or a name")
    mode = fields.get("mode", "")
    if not (mode.startswith('"') and MODE.match(mode[1:-1])):
        errors.append("mode must be a quoted WIDTHxHEIGHT@RATE")
    transform = fields.get("transform")
    if transform is not None and not re.match(r"^[0-7]$", transform):
        errors.append("transform must be 0-7")
    # A mirror names its target by connector, as Hyprland's mirror key takes it.
    mirror = fields.get("mirror")
    if mirror is not None and not (mirror.startswith('"') and CONNECTOR.match(mirror[1:-1])):
        errors.append("mirror must be a quoted connector name")
    return errors


def check_block(block):
    lines = block.split("\n")
    if len(lines) < 2 or lines[0] != BEGIN or lines[-1] != END:
        return ["the block must start and end with the managed markers"]

    errors = []
    catch_all = 0
    gdk_env = 0
    for number, line in enumerate(lines[1:-1], 2):
        where = "line %d: " % number
        if line in (BEGIN, END):
            errors.append(where + "a marker inside the block")
        elif line == "":
            continue
        elif line.startswith("--"):
            # clamshell only strips `--[[ ]]` when it closes on the same line.
            if line.startswith("--[["):
                errors.append(where + "block comments are not stripped by clamshell")
        elif line.startswith("local "):
            match = re.match(r"^local ([A-Za-z_][A-Za-z0-9_]*) = (.+)$", line)
            if not match:
                errors.append(where + "unreadable local")
                continue
            name, value = match.groups()
            if name in ("omarchy_monitor_scale", "omarchy_gdk_scale"):
                errors.append(where + "%s re-arms omarchy-hyprland-monitor-scaling" % name)
            elif name == "gdk_scale" and re.match(r"^[0-9]+$", value):
                pass
            elif name == "fallback_scale" and (value == '"auto"' or NUMBER.match(value)):
                pass
            else:
                errors.append(where + "unexpected local %s" % name)
        elif line == GDK_ENV:
            gdk_env += 1
        elif line.startswith("hl.monitor"):
            errors.extend(where + error for error in check_rule(line))
            if 'output = ""' in line:
                catch_all += 1
        else:
            errors.append(where + "unexpected line")

    if gdk_env != 1:
        errors.append("the block sets GDK_SCALE exactly once, with tostring(gdk_scale)")
    if catch_all != 1:
        errors.append("the block has exactly one catch-all rule")
    if SCALING_GATE_A.search(block) or SCALING_GATE_B.search(block):
        errors.append("the block matches omarchy-hyprland-monitor-scaling's persistence gate")
    if GDK_SED.search(block):
        errors.append("the block matches omarchy-hyprland-monitor-scaling's GDK_SCALE sed")
    return errors


# ------------------------------------------------------------------- the file


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def find_block(text):
    lines = text.split("\n")
    begin = None
    for index, line in enumerate(lines):
        if begin is None and line == BEGIN:
            begin = index
        elif begin is not None and line == END:
            return lines, begin, index
    return None


def current_block(text):
    found = find_block(text or "")
    if not found:
        return ""
    lines, begin, end = found
    return "\n".join(lines[begin : end + 1])


def splice(text, block):
    lines, begin, end = find_block(text)
    return "\n".join(lines[:begin] + block.split("\n") + lines[end + 1 :])


def outside(text):
    found = find_block(text)
    if not found:
        return text
    lines, begin, end = found
    return "\n".join(lines[:begin] + lines[end + 1 :])


def adopted(text, block):
    """The file as it is after the one-time takeover.

    Kept: the comment header it opens with, a `local monitors = { ... }`
    table and the trailing `return monitors` if it has them (a workspaces
    config may consume that return value). Everything else -- the scale
    locals, helpers, computed positions and hand-written rules -- is what the
    block replaces, and stays readable in the .bak file."""
    lines = (text or "").split("\n")
    header = []
    for line in lines:
        if line.startswith("--") and not line.startswith("--[["):
            header.append(line)
        else:
            break

    table = []
    for index, line in enumerate(lines):
        if re.match(r"^local monitors = \{", line):
            for end in range(index, len(lines)):
                table.append(lines[end])
                if lines[end] == "}" or (end == index and line.rstrip().endswith("}")):
                    break
            break

    significant = [line for line in lines if line.strip() and not line.lstrip().startswith("--")]
    tail = []
    if significant and re.match(r"^return\b", significant[-1]):
        tail = ["", significant[-1]]

    out = list(header)
    for part in (table, block.split("\n")):
        if out and part:
            out.append("")
        out.extend(part)
    out.extend(tail)
    return "\n".join(out) + "\n"


def atomic_write(path, text):
    """Write beside the real file (behind any dotfile symlink), fsync, then
    rename over it, so Hyprland never reads half a config."""
    target = os.path.realpath(path)
    directory = os.path.dirname(target)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(target) + ".", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        if os.path.exists(target):
            shutil.copymode(target, tmp)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        dfd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def autoreload_on():
    try:
        done = subprocess.run(
            ["hyprctl", "getoption", "misc:disable_autoreload", "-j"],
            capture_output=True, text=True, timeout=3,
        )
        data = json.loads(done.stdout)
        return not bool(data.get("bool", data.get("int", 0)))
    except (OSError, ValueError, subprocess.TimeoutExpired, AttributeError):
        return True


def reload_if_needed():
    """Saving the file is the apply step; only a session that turned autoreload
    off needs telling."""
    if NO_RELOAD or autoreload_on():
        return False
    try:
        subprocess.run(["hyprctl", "reload"], capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return True


# ------------------------------------------------------------------ snapshot
#
# ~/.local/state/omarchy/displays.json holds the file as it was before the last
# confirmable write. It is on disk rather than in the shell so that a crash in
# the middle of the countdown still leaves something to go back to, and the
# watchdog that enforces the deadline is a separate process for the same
# reason.


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and data.get("version") == 1 else None


def save_state(state):
    atomic_write(STATE_FILE, json.dumps(state, indent=2) + "\n")


def pending(state):
    return bool(state) and state.get("status") == "pending"


@contextmanager
def locked():
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE + ".lock", "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def do_revert(state):
    path = state.get("path") or os.path.realpath(MONITORS_LUA)
    text = read_text(path) or ""
    if sha256(text) == state.get("applied_sha256"):
        # Nothing else touched the file since: put it back exactly.
        restored, how = state.get("previous", text), "file"
    else:
        # Someone edited outside the block in the meantime; keep their edit
        # and put back only the block.
        previous_block = current_block(state.get("previous", ""))
        if previous_block and find_block(text):
            restored, how = splice(text, previous_block), "block"
        else:
            restored, how = None, "conflict"
    if restored is not None and restored != text:
        atomic_write(path, restored)
        reload_if_needed()
    state["status"] = "reverted" if restored is not None else "conflict"
    state["resolved"] = time.time()
    save_state(state)
    return how


def spawn_watchdog(token):
    # A new session, so neither the shell's process group nor the shell
    # crashing takes the deadline down with it.
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "watchdog", token],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, close_fds=True,
    )


# ------------------------------------------------------------------ commands


def reply(ok=True, **fields):
    fields["ok"] = ok
    json.dump(fields, sys.stdout, ensure_ascii=False)
    print()
    return 0 if ok else 1


def block_arg(argv):
    # --text is what the QML uses: Process hands argv over without a shell, so
    # the block needs no encoding. --base64 is for typing at a terminal.
    if "--text" in argv:
        index = argv.index("--text")
        if index + 1 >= len(argv):
            raise ValueError("--text <block> is missing its block")
        return argv[index + 1]
    if "--base64" not in argv:
        raise ValueError("--text <block> or --base64 <block> is required")
    index = argv.index("--base64")
    try:
        return base64.b64decode(argv[index + 1]).decode("utf-8")
    except (IndexError, ValueError) as err:
        raise ValueError("unreadable --base64 block: %s" % err)


def warnings_for(text):
    """Things outside the block that fight it. Never fixed from here --
    outside the markers belongs to whoever wrote it -- only reported."""
    rest = outside(text)
    out = []
    if SCALING_GATE_A.search(rest) or SCALING_GATE_B.search(rest):
        out.append("monitors.lua still matches omarchy-hyprland-monitor-scaling's persistence gate")
    if COLUMN0_RULE.search(rest):
        out.append("monitors.lua has hl.monitor rules outside the managed block")
    return out


def cmd_read(argv):
    text = read_text(MONITORS_LUA)
    state = load_state()
    try:
        age = max(0.0, time.time() - os.stat(MONITORS_LUA).st_mtime)
    except OSError:
        age = None
    return reply(
        True,
        path=MONITORS_LUA,
        exists=text is not None,
        adopted=bool(text is not None and find_block(text)),
        block=current_block(text),
        age=age,
        autoreload=autoreload_on(),
        pending=(
            {"deadline": state["deadline"], "remaining": max(0.0, state["deadline"] - time.time())}
            if pending(state) else None
        ),
        warnings=warnings_for(text or ""),
    )


def cmd_check(argv):
    try:
        block = block_arg(argv)
    except ValueError as err:
        return reply(False, status="usage", error=str(err))
    errors = check_block(block)
    return reply(not errors, status="valid" if not errors else "invalid", errors=errors)


def cmd_adopt(argv):
    try:
        block = block_arg(argv)
    except ValueError as err:
        return reply(False, status="usage", error=str(err))
    text = read_text(MONITORS_LUA)
    if text is not None and find_block(text):
        return reply(True, status="present", changed=False)
    errors = check_block(block)
    if errors:
        return reply(False, status="invalid", errors=errors)

    backup = None
    try:
        if text is not None:
            target = os.path.realpath(MONITORS_LUA)
            backup = "%s.bak.%d" % (target, int(time.time()))
            shutil.copy2(target, backup)
        atomic_write(MONITORS_LUA, adopted(text, block))
    except OSError as err:
        return reply(False, status="error", error=str(err))
    reload_if_needed()
    return reply(True, status="adopted", changed=True, backup=backup)


def cmd_write(argv):
    try:
        block = block_arg(argv)
        within = 0.0
        if "--confirm-within" in argv:
            within = float(argv[argv.index("--confirm-within") + 1])
    except (ValueError, IndexError) as err:
        return reply(False, status="usage", error=str(err))

    errors = check_block(block)
    if errors:
        return reply(False, status="invalid", errors=errors)

    with locked():
        text = read_text(MONITORS_LUA)
        if text is None or not find_block(text):
            return reply(False, status="not-adopted", error="monitors.lua has no managed block yet")
        updated = splice(text, block)
        # Every write reloads Hyprland, and clamshell polls every two seconds;
        # a write that changes nothing has to be recognisably nothing.
        if updated == text:
            return reply(True, status="unchanged", changed=False)

        token = sha256(updated)
        deadline = None
        try:
            if within > 0:
                state = load_state()
                target = os.path.realpath(MONITORS_LUA)
                # A second Apply inside the countdown still reverts to the last
                # state someone actually confirmed.
                previous = state["previous"] if pending(state) and state.get("path") == target else text
                deadline = time.time() + within
                save_state({
                    "version": 1,
                    "status": "pending",
                    "path": target,
                    "previous": previous,
                    "applied_sha256": token,
                    "created": time.time(),
                    "deadline": deadline,
                })
            atomic_write(MONITORS_LUA, updated)
        except OSError as err:
            return reply(False, status="error", error=str(err))

    reload_if_needed()
    if deadline is not None:
        spawn_watchdog(token)
    return reply(True, status="written", changed=True, deadline=deadline)


def cmd_confirm(argv):
    with locked():
        state = load_state()
        if not pending(state):
            return reply(True, status="nothing")
        state["status"] = "confirmed"
        state["resolved"] = time.time()
        save_state(state)
    return reply(True, status="confirmed")


def cmd_revert(argv):
    with locked():
        state = load_state()
        if not pending(state):
            return reply(True, status="nothing")
        how = do_revert(state)
    return reply(how != "conflict", status="reverted" if how != "conflict" else "conflict", how=how)


def cmd_recover(argv):
    with locked():
        state = load_state()
        if not pending(state):
            return reply(True, status="nothing")
        remaining = state["deadline"] - time.time()
        if remaining > 0:
            token = state.get("applied_sha256", "")
        else:
            how = do_revert(state)
            return reply(True, status="reverted", how=how)
    # Still inside its countdown (the shell restarted mid-apply): make sure
    # something is still watching the deadline.
    spawn_watchdog(token)
    return reply(True, status="pending", remaining=remaining)


def cmd_watchdog(argv):
    token = argv[0] if argv else ""
    while True:
        with locked():
            state = load_state()
            if not pending(state) or state.get("applied_sha256") != token:
                return 0
            remaining = state["deadline"] - time.time()
            if remaining <= 0:
                do_revert(state)
                return 0
        time.sleep(min(max(remaining, 0.05), 1.0))


# ---------------------------------------------------------------------- menu
#
# The same approach as Default Applications' scan.py: one row, added once on
# the plugin's first start, and only when adding it changes nothing else.

MENU_ID = "setup.displays"
MENU_MARKER = "  // ── Displays (%s)" % PLUGIN_ID
MENU_ENTRY = {
    "icon": "󰍺",
    "label": "Displays",
    "description": "Set up displays: arrangement, scale, resolution, refresh rate and rotation",
    "aliases": ["displays", "monitors", "arrange-displays"],
    # Hides the row once `omarchy plugin remove` has deleted the folder.
    "when": "[[ -d ~/.config/omarchy/plugins/%s ]]" % PLUGIN_ID,
    "action": "omarchy-shell shell summon %s '{}'" % PLUGIN_ID,
}
LINE_COMMENT = re.compile(r"^\s*//[^\n]*(\n|$)", re.M)


def menu_path():
    # The exact path Omarchy's Menu.qml reads; it does not honour XDG_CONFIG_HOME.
    return os.path.join(HOME, ".config", "omarchy", "extensions", "omarchy-menu.jsonc")


def menu_state_path():
    return os.path.join(
        _env_dir("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy-displays", "menu-entry"
    )


def parse_menu(text):
    """The menu file as Omarchy's MenuModel.js reads it: whole-line //
    comments and trailing commas go, and no other JSONC is understood."""
    stripped = LINE_COMMENT.sub("", text)
    stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
    if not stripped.strip():
        return {}
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _significant(line):
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("//")


def insert_menu_row(text, row):
    lines = text.split("\n")
    close = next((i for i in reversed(range(len(lines))) if _significant(lines[i])), None)
    if close is None or not lines[close].rstrip().endswith("}"):
        return None
    last = lines[close].rstrip()
    head = lines[:close]
    if last[:-1].strip():
        head.append(last[:-1].rstrip())
    prev = next((i for i in reversed(range(len(head))) if _significant(head[i])), None)
    if prev is not None and not head[prev].rstrip().endswith((",", "{")):
        head[prev] = head[prev].rstrip() + ","
    if head and _significant(head[-1]) and not head[-1].rstrip().endswith("{"):
        head.append("")
    return "\n".join(head + [MENU_MARKER, row, "}"] + lines[close + 1 :])


def remember(path):
    """A file that exists means the question was asked once. Its line is when,
    for whoever finds it."""
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(time.strftime("%Y-%m-%dT%H:%M:%S%z") + "\n")


def cmd_menu(argv):
    path = menu_path()
    state = menu_state_path()
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        existed = True
    except FileNotFoundError:
        text, existed = "", False
    except (OSError, UnicodeDecodeError) as err:
        return reply(False, status="unreadable", error=str(err))

    current = parse_menu(text)
    if current is None:
        return reply(False, status="unreadable", error="the Omarchy menu cannot parse %s" % path)
    if MENU_ID in current or PLUGIN_ID in text:
        try:
            remember(state)
        except OSError:
            pass
        return reply(True, status="present")
    # Deleted by hand after an earlier run added it: that is an answer.
    if os.path.exists(state):
        return reply(True, status="declined")
    if isinstance(current.get("items"), dict):
        return reply(False, status="unsupported", error='rows in %s are nested under "items"' % path)

    if not LINE_COMMENT.sub("", text).strip():
        text += ("" if not text or text.endswith("\n") else "\n") + "{\n}\n"
    row = "  %s:%s," % (
        json.dumps(MENU_ID),
        json.dumps(MENU_ENTRY, ensure_ascii=False, separators=(",", ":")),
    )
    updated = insert_menu_row(text, row)
    if updated is None or parse_menu(updated) != dict(current, **{MENU_ID: MENU_ENTRY}):
        return reply(False, status="unsupported", error="cannot add a row to %s without changing the rest" % path)

    target = os.path.realpath(path)
    try:
        if existed:
            shutil.copy2(target, "%s.bak.%d" % (target, int(time.time())))
        atomic_write(path, updated)
        remember(state)
    except OSError as err:
        return reply(False, status="error", error=str(err))
    return reply(True, status="added")


# ------------------------------------------------------------------ retiring

LEGACY_UNIT = "omarchy-monitor-scale-persist.service"


def cmd_retire(argv):
    """The bespoke daemon this plugin supersedes recorded out-of-band scale
    changes too; two recorders would fight. Absent is the common case."""
    try:
        probe = subprocess.run(
            ["systemctl", "--user", "cat", LEGACY_UNIT], capture_output=True, text=True, timeout=5
        )
        if probe.returncode != 0:
            return reply(True, status="absent")
        done = subprocess.run(
            ["systemctl", "--user", "disable", "--now", LEGACY_UNIT],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        return reply(False, status="error", error=str(err))
    ok = done.returncode == 0
    return reply(ok, status="disabled" if ok else "error", error=done.stderr.strip())


# --------------------------------------------------- superseding the widget
#
# Omarchy's own Display widget does the same job on the bar, and its scale
# control shells out to omarchy-hyprland-monitor-scaling, which applies live
# and cannot write into a managed block -- so the next reconcile undoes it.
# Two controls, one of which silently loses. `omarchy plugin add` runs no
# install hook, so the README used to ask for it to be taken off by hand.
#
# Taking it off is a removal from bar.layout and nothing else: shell.json
# records no "off" for a bar widget. So afterwards the bar cannot say whether
# it was never there or was taken off, and a user who put it back would lose
# it at every restart. This file is the difference: once it exists, the
# question has been answered and the bar is theirs.
#
# The bar is not touched from here. shell.json is written by the running
# shell, whole, from its own copy in memory; an edit from outside would be
# lost the next time anything else changed. The QML makes the call through the
# registry it was handed. This only decides and remembers.


def stock_state_path():
    return os.path.join(
        _env_dir("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy-displays", "stock-widget"
    )


def cmd_supersede(argv):
    """--stock in|out is what the shell says about omarchy.monitor's place on
    the bar. Answers `proceed` at most once."""
    stock = argv[1] if len(argv) > 1 and argv[0] == "--stock" else ""
    if stock not in ("in", "out"):
        return reply(False, status="usage", error="supersede --stock in|out")

    state = stock_state_path()
    decided = os.path.exists(state)
    try:
        remember(state)
    except OSError as err:
        # Nothing decided, so the next start asks again.
        return reply(False, status="error", error=str(err))

    if stock == "out":
        return reply(True, status="absent")
    # Put back by hand after an earlier run took it off: that is an answer.
    if decided:
        return reply(True, status="declined")
    return reply(True, status="proceed")


# ------------------------------------------------------------------ binding
#
# SUPER + / used to reach omarchy-hyprland-monitor-scaling, which applied the
# scale live and then sed'd it into monitors.lua. It cannot sed a managed
# block, so it stopped writing anything -- and on the laptop panel
# omarchy-hyprland-monitor-clamshell reads the internal rule's scale out of
# that same file and puts the panel back within a second. Pointing the two
# bindings at the plugin writes the block first, and clamshell then reads it
# and agrees. Same keys, same job, and it sticks again.

BIND_MARKER = "-- Displays scale steps (%s)" % PLUGIN_ID
BIND_CALL = "omarchy-shell shell call %s scaleStep" % PLUGIN_ID
BIND_ROWS = """%s
hl.unbind("SUPER + SLASH")
hl.unbind("SUPER + ALT + SLASH")
o.bind("SUPER + SLASH", "Monitor scaling up", "%s up")
o.bind("SUPER + ALT + SLASH", "Monitor scaling down", "%s down")
""" % (BIND_MARKER, BIND_CALL, BIND_CALL)

BINDINGS_LUA = os.environ.get("DISPLAYS_BINDINGS_LUA") or os.path.join(
    HOME, ".config", "hypr", "bindings.lua"
)


def bind_state_path():
    return os.path.join(
        _env_dir("XDG_STATE_HOME", HOME + "/.local/state"), "omarchy-displays", "scale-binds"
    )


def cmd_bind(argv):
    state = bind_state_path()
    try:
        with open(BINDINGS_LUA, "r", encoding="utf-8") as fh:
            text = fh.read()
        existed = True
    except FileNotFoundError:
        text, existed = "", False
    except (OSError, UnicodeDecodeError) as err:
        return reply(False, status="unreadable", error=str(err))

    if BIND_MARKER in text or BIND_CALL in text:
        try:
            remember(state)
        except OSError:
            pass
        return reply(True, status="present")
    # Taken out by hand after an earlier run added them: that is an answer.
    if os.path.exists(state):
        return reply(True, status="declined")

    updated = text
    if updated and not updated.endswith("\n"):
        updated += "\n"
    if updated:
        updated += "\n"
    updated += BIND_ROWS
    try:
        if existed:
            shutil.copy2(BINDINGS_LUA, "%s.bak.%d" % (BINDINGS_LUA, int(time.time())))
        atomic_write(BINDINGS_LUA, updated)
        remember(state)
    except OSError as err:
        return reply(False, status="error", error=str(err))
    return reply(True, status="added")


COMMANDS = {
    "read": cmd_read,
    "check": cmd_check,
    "adopt": cmd_adopt,
    "write": cmd_write,
    "confirm": cmd_confirm,
    "revert": cmd_revert,
    "recover": cmd_recover,
    "watchdog": cmd_watchdog,
    "menu": cmd_menu,
    "retire": cmd_retire,
    "supersede": cmd_supersede,
    "bind": cmd_bind,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print("usage: monitors.py {%s} ..." % "|".join(sorted(COMMANDS)), file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
