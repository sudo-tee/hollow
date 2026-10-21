#!/usr/bin/env python3
"""Terminal workload generators dispatched by the bench router.

Writes escape-sequence traffic to stdout so a terminal (Hollow, nvim, any
emulator) can be measured from the outside.

Usage:
    bench.sh MODE [COUNT] [RATE_HZ] [UPDATES_PER_BATCH] [CHUNK_BYTES] [WRITE_DELAY_MS]

Modes: scroll, repaint, keypress, split-scroll, sync-output, chunked,
chunked-raw, codex-flash.
"""

import os
import re
import select
import shutil
import signal
import sys
import termios
import time
import tty

MODE_CHOICES = (
    "scroll",
    "repaint",
    "keypress",
    "split-scroll",
    "sync-output",
    "chunked",
    "chunked-raw",
    "codex-flash",
)

mode = sys.argv[1] if len(sys.argv) > 1 else ""
count = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
rate_arg = int(sys.argv[3]) if len(sys.argv) > 3 else 100
sync_updates_arg = int(sys.argv[4]) if len(sys.argv) > 4 else 4
chunk_bytes = max(1, int(sys.argv[5])) if len(sys.argv) > 5 else 128
write_delay_ms = max(0.0, float(sys.argv[6])) if len(sys.argv) > 6 else 0.0
cols, rows = shutil.get_terminal_size((80, 24))
rows = max(4, rows)
cols = max(20, cols)

CSI = "\x1b["
RESET = CSI + "0m"
HIDE = CSI + "?25l"
SHOW = CSI + "?25h"
ALT_ON = CSI + "?1049h"
ALT_OFF = CSI + "?1049l"
CLEAR = CSI + "2J"
HOME = CSI + "H"
SYNC_ON = CSI + "?2026h"
SYNC_OFF = CSI + "?2026l"

running = True

def cleanup(*_):
    global running
    running = False
    try:
        sys.stdout.write(RESET + SHOW + SYNC_OFF + ALT_OFF)
        sys.stdout.flush()
    except Exception:
        pass

signal.signal(signal.SIGINT, cleanup)
signal.signal(signal.SIGTERM, cleanup)

palette = [f"{CSI}38;5;{i}m" for i in range(16, 256)]

def stat_line(name, elapsed, units, count):
    rate = count / elapsed if elapsed > 0 else 0.0
    singular = units[:-1] if units.endswith("s") else units
    return f"\n{name}: {count} {units} in {elapsed:.2f}s ({rate:.1f}/{singular}/s) size={cols}x{rows}\n"

def wait_for_terminal_drain(timeout=10.0):
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        old_attrs = termios.tcgetattr(fd)
    except termios.error:
        os.close(fd)
        return None
    response = bytearray()
    try:
        tty.setcbreak(fd)
        termios.tcflush(fd, termios.TCIFLUSH)
        started = time.perf_counter()
        os.write(fd, (CSI + "6n").encode())
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], deadline - time.monotonic())
            if not ready:
                break
            response.extend(os.read(fd, 64))
            if re.search(rb"\x1b\[\d+;\d+R", response):
                return time.perf_counter() - started
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old_attrs)
        os.close(fd)
    raise RuntimeError("terminal did not acknowledge repaint drain")

def make_scroll_line(i):
    color = palette[i % len(palette)]
    num = f"{i:07d}"
    body = (" abcdefghijklmnopqrstuvwxyz0123456789" * 8)[: max(0, cols - 12)]
    return f"{color}{num}{RESET}{body}\n"

def run_scroll(lines):
    sys.stdout.write(HIDE)
    sys.stdout.flush()
    start = time.perf_counter()
    written = 0
    for i in range(lines):
        if not running:
            break
        s = make_scroll_line(i)
        sys.stdout.write(s)
        written += len(s)
        if i % 200 == 0:
            sys.stdout.flush()
    sys.stdout.flush()
    elapsed = time.perf_counter() - start
    sys.stdout.write(RESET + SHOW)
    sys.stdout.write(stat_line("scroll", elapsed, "lines", max(1, i + 1 if lines else 0)))
    sys.stdout.write(f"bytes: {written} ({written / elapsed:.0f}/s)\n")

def frame_text(frame, row):
    base = (frame * 7 + row * 13) % len(palette)
    left = palette[base]
    right = palette[(base + 40) % len(palette)]
    label = f" frame={frame:05d} row={row:03d} ".ljust(22, " ")
    fill = ("<>[]{}()##==++--" * 32)[: max(0, cols - len(label))]
    split = max(0, len(fill) // 2)
    return f"{left}{label}{right}{fill[:split]}{left}{fill[split:]}{RESET}"

def run_repaint(frames):
    # DSR acknowledgement includes terminal-to-PTY input latency. Measure that
    # fixed control-path cost before the workload so only excess queue drain is
    # charged to terminal throughput.
    drain_baselines = [wait_for_terminal_drain() for _ in range(3)]
    drain_baselines = [sample for sample in drain_baselines if sample is not None]
    drain_baseline = sorted(drain_baselines)[len(drain_baselines) // 2] if drain_baselines else 0.0
    sys.stdout.write(HIDE + ALT_ON + CLEAR)
    sys.stdout.flush()
    start = time.perf_counter()
    done = 0
    for frame in range(frames):
        if not running:
            break
        parts = [HOME]
        for row in range(rows - 1):
            parts.append(frame_text(frame, row))
            parts.append("\n")
        parts.append(f"{CSI}0mrepaint benchmark  frame={frame:05d}  size={cols}x{rows}  Ctrl-C to stop")
        sys.stdout.write("".join(parts))
        sys.stdout.flush()
        done = frame + 1
    write_elapsed = time.perf_counter() - start
    drain_start = time.perf_counter()
    drain_round_trip = wait_for_terminal_drain()
    drain_elapsed = time.perf_counter() - drain_start
    drain_overhead = min(drain_elapsed, drain_baseline or 0.0)
    effective_drain = drain_elapsed - drain_overhead
    elapsed = write_elapsed + effective_drain
    cleanup()
    sys.stdout.write(stat_line("repaint end-to-end", elapsed, "frames", max(1, done)))
    cell_rate = done * cols * rows / elapsed if elapsed > 0 else 0.0
    sys.stdout.write(f"end-to-end cell throughput: {cell_rate / 1_000_000:.1f} Mcells/s\n")
    write_rate = done / write_elapsed if write_elapsed > 0 else 0.0
    write_cell_rate = done * cols * rows / write_elapsed if write_elapsed > 0 else 0.0
    sys.stdout.write(f"producer write phase: {write_elapsed:.2f}s ({write_rate:.1f} frames/s, {write_cell_rate / 1_000_000:.1f} Mcells/s)\n")
    sys.stdout.write(
        f"drain phase: {effective_drain:.2f}s "
        f"(raw={drain_elapsed:.2f}s, idle DSR RTT={drain_baseline or 0.0:.2f}s)\n"
    )
    if drain_round_trip is None:
        sys.stdout.write("warning: terminal drain acknowledgement unavailable\n")

def make_keypress_line(i, cols):
    """Build a single line of content as nvim would redraw on j/k scroll."""
    color = palette[i % len(palette)]
    num = f"{i:07d}"
    body = (" abcdefghijklmnopqrstuvwxyz0123456789" * 8)[: max(0, cols - len(num) - 1)]
    return f"{color}{num} {body}{RESET}"

def split_pad(text, width):
    plain = text[:width]
    return plain + (" " * max(0, width - len(plain)))

def _h(x):
    """Murmur3-style finalizer — good avalanche so every bit of (i,row) matters."""
    x = ((x >> 16) ^ x) * 0x45d9f3b & 0xffffffff
    x = ((x >> 16) ^ x) * 0x45d9f3b & 0xffffffff
    x = (x >> 16) ^ x
    return x

def _rng(press, row, slot):
    """Independent hash per (press, row, slot) — no shared seed."""
    return _h(press * 0x9e3779b9 ^ row * 0x6b43a9b5 ^ slot * 0xd2a98b26)

def make_split_left_line(row, width):
    """Static left pane: looks like a file-explorer / diagnostics panel."""
    h = lambda slot: _rng(0, row, slot)

    dirs  = ["src", "lib", "tests", "docs", "pkg", "internal", "cmd", "api"]
    files = [
        "main.rs", "lib.rs", "mod.rs", "util.go", "server.ts", "index.js",
        "parser.c", "render.zig", "schema.sql", "config.toml", "Makefile",
        "README.md", "*.test.ts", "bench_test.go", "setup.cfg",
    ]
    tags   = ["M ", "A ", "D ", "R ", "  ", "??", "!!"]
    hints  = ["", "", "", "// TODO", "// FIXME", "// PERF", "// UNSAFE"]
    sizes  = [h(9) % 9999]

    tag  = tags[h(1) % len(tags)]
    d    = dirs[h(2)  % len(dirs)]
    f    = files[h(3) % len(files)]
    hint = hints[h(4) % len(hints)]

    depth = h(5) % 4
    if depth == 0:
        path = f[0]                       # just filename initial — very short
    elif depth == 1:
        path = f                          # bare filename
    elif depth == 2:
        path = f"{d}/{f}"
    else:
        sub = dirs[h(6) % len(dirs)]
        path = f"{d}/{sub}/{f}"

    sz   = h(7) % 9999
    tail = f"  {hint}" if hint else f"  {sz}b"
    label = f"{tag}{path}{tail}"

    body = split_pad(label, width)
    colors = [110, 108, 114, 150, 179, 167, 245]
    col = colors[h(8) % len(colors)]
    return f"{CSI}38;5;{col}m{body}{RESET}"

def make_split_right_line(press, row, width):
    """Scrolling right pane: looks like a live code buffer — varied structure."""
    h = lambda slot: _rng(press, row, slot)

    # Rich vocabularies so adjacent lines rarely share the same tokens
    indents  = ["", "  ", "    ", "      ", "        ", "\t", "\t\t"]
    keywords = ["let", "const", "var", "fn", "pub fn", "async fn", "impl",
                "return", "match", "if", "else", "for", "while", "type",
                "struct", "enum", "trait", "use", "mod", "extern"]
    types    = ["i32", "u64", "f32", "bool", "String", "Vec<u8>", "Option<T>",
                "Result<(), E>", "Arc<Mutex<T>>", "Box<dyn Fn()>", "&str",
                "usize", "c_int", "void*", "[]u8"]
    names    = ["buf", "idx", "cur", "ret", "err", "val", "ptr", "out",
                "len", "cap", "n", "x", "y", "pos", "off", "flag",
                "handle", "ctx", "cfg", "self", "state", "data", "key"]
    ops      = ["=", "+=", "-=", "*=", "|=", "&=", "^=", "??=", "||="]
    hexs     = [f"0x{h(20+k) & 0xffff:04x}" for k in range(8)]
    nums     = [str(h(30+k) % 1024)         for k in range(8)]
    strs     = [
        '"hello"', '"world"', '"error: {}"', '"\\n"',
        '"/usr/local/bin"', '"config.toml"', '"unexpected token"',
        '"data"', '"status"', '"ok"', '"failed"',
        f'"frame={press}"', f'"row={row}"',
    ]
    comments = [
        "// TODO: fix this",  "// FIXME: off-by-one", "// PERF: hot path",
        "// SAFETY: checked", "// HACK:", "/* legacy */",
        f"// line {row}", "",  "",  "",   # blanks so comments aren't too frequent
    ]

    color = palette[(h(0) % len(palette))]
    indent = indents[h(1) % len(indents)]
    tpl    = h(2) % 13
    kw     = keywords[h(3) % len(keywords)]
    ty     = types[h(4)    % len(types)]
    nm     = names[h(5)    % len(names)]
    nm2    = names[h(6)    % len(names)]
    op     = ops[h(7)      % len(ops)]
    lit    = hexs[h(8)     % len(hexs)] if h(9) % 2 else nums[h(10) % len(nums)]
    s      = strs[h(11)    % len(strs)]
    cmt    = comments[h(12) % len(comments)]

    if tpl == 0:
        # blank / very short
        code = ""
    elif tpl == 1:
        # simple assignment
        code = f"{kw} {nm}: {ty} {op} {lit};"
    elif tpl == 2:
        # short assignment, no type
        code = f"{nm} {op} {lit};"
    elif tpl == 3:
        # function signature (no body)
        args = ", ".join(f"{names[h(40+k) % len(names)]}: {types[h(50+k) % len(types)]}"
                        for k in range(h(13) % 4))
        code = f"{kw}({args}) -> {ty} {{"
    elif tpl == 4:
        # closing brace, maybe with comment
        code = "}" + (f"  {cmt}" if cmt else "")
    elif tpl == 5:
        # return statement
        code = f"return {nm};"
    elif tpl == 6:
        # if condition
        op2 = ["==", "!=", "<", ">", "<=", ">="][h(14) % 6]
        code = f"if {nm} {op2} {lit} {{"
    elif tpl == 7:
        # string log / print
        code = f"eprintln!({s}, {nm});" if h(15) % 2 else f"console.log({s} + {nm});"
    elif tpl == 8:
        # chained method call — long line
        methods = ["map", "filter", "collect", "unwrap", "ok()", "await", "clone"]
        chain = ".".join(methods[h(60+k) % len(methods)] for k in range(h(16) % 5 + 2))
        code = f"{nm}.{chain};"
    elif tpl == 9:
        # struct literal / object
        fields = ", ".join(f"{names[h(70+k) % len(names)]}: {lit}"
                          for k in range(h(17) % 4 + 1))
        code = f"{ty} {{ {fields} }}"
    elif tpl == 10:
        # inline comment only
        code = cmt if cmt else f"// {nm} = {lit}"
    elif tpl == 11:
        # match arm
        code = f"{lit} => {nm2},"
    else:
        # multi-assignment
        code = f"({nm}, {nm2}) = ({lit}, {s});"

    cmt_sfx = f"  {cmt}" if cmt and tpl not in (4, 10) else ""
    line = f"{indent}{code}{cmt_sfx}"

    label = f"{press:07d}:{row:03d} "
    body = split_pad(label + line, width)
    return f"{color}{body}{RESET}"

def run_split_scroll(presses, rate_hz=100):
    """
    Approximate a vim vertical split where the left pane stays static and the
    right pane scrolls. Each 'keypress' rewrites only the right half of the
    screen, which is useful for measuring how much work the renderer still does
    for rows whose left-side cells are unchanged.
    """
    interval = 1.0 / rate_hz
    content_rows = rows - 1
    split_col = max(12, cols // 2)
    left_w = max(8, split_col - 1)
    right_x = split_col + 1
    right_w = max(8, cols - right_x + 1)

    sys.stdout.write(HIDE + ALT_ON + CLEAR + HOME)
    for row in range(content_rows):
        left = make_split_left_line(row, left_w)
        right = make_split_right_line(row, row, right_w)
        sys.stdout.write(f"{CSI}{row + 1};1H{left}{CSI}38;5;240m│{RESET}{right}")
    sys.stdout.write(
        f"{CSI}{rows};1H{CSI}0m"
        f"split-scroll bench  panes=2  active=right  size={cols}x{rows}  rate={rate_hz}hz"
    )
    sys.stdout.flush()

    frame_times = []
    done = 0
    last_t = time.perf_counter()
    start = last_t

    for press in range(presses):
        if not running:
            break

        for row in range(content_rows):
            line_no = press + row + 1
            sys.stdout.write(
                f"{CSI}{row + 1};{right_x}H"
                + make_split_right_line(line_no, row, right_w)
            )

        sys.stdout.write(
            f"{CSI}{rows};1H{CSI}0m"
            f"split-scroll bench  press={press + 1:05d}/{presses}"
            f"  panes=2  active=right  size={cols}x{rows}  rate={rate_hz}hz"
        )
        sys.stdout.flush()

        now = time.perf_counter()
        elapsed_this = now - last_t
        frame_times.append(elapsed_this)
        last_t = now
        done += 1

        sleep_for = interval - elapsed_this
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    cleanup()

    if frame_times:
        avg_ms = (sum(frame_times) / len(frame_times)) * 1000
        min_ms = min(frame_times) * 1000
        max_ms = max(frame_times) * 1000
        p99_ms = sorted(frame_times)[int(len(frame_times) * 0.99)] * 1000
    else:
        avg_ms = min_ms = max_ms = p99_ms = 0.0

    sys.stdout.write(stat_line("split-scroll", elapsed, "presses", max(1, done)))
    sys.stdout.write(
        f"inter-press gap (ms):  avg={avg_ms:.2f}  min={min_ms:.2f}  "
        f"max={max_ms:.2f}  p99={p99_ms:.2f}\n"
    )
    sys.stdout.write(
        f"layout: left pane static, right pane rewritten each press, split_col={split_col}\n"
    )

def run_sync_output(batches, rate_hz=100, updates_per_batch=4):
    """Rewrite the viewport in several updates enclosed by DEC mode 2026."""
    interval = 1.0 / rate_hz
    content_rows = rows - 1
    updates_per_batch = max(1, updates_per_batch)

    sys.stdout.write(HIDE + ALT_ON + CLEAR + HOME)
    for row in range(content_rows):
        sys.stdout.write(f"{CSI}{row + 1};1H{frame_text(0, row)}")
    sys.stdout.write(
        f"{CSI}{rows};1H{CSI}0msync-output bench  batches={batches}"
        f"  updates={updates_per_batch}  size={cols}x{rows}  rate={rate_hz}hz"
    )
    sys.stdout.flush()

    batch_times = []
    written = 0
    done = 0
    start = time.perf_counter()

    for batch in range(batches):
        if not running:
            break

        batch_start = time.perf_counter()
        sys.stdout.write(SYNC_ON)
        for update in range(updates_per_batch):
            frame = batch * updates_per_batch + update + 1
            parts = []
            for row in range(content_rows):
                parts.append(f"{CSI}{row + 1};1H{frame_text(frame, row)}")
            parts.append(
                f"{CSI}{rows};1H{CSI}0msync-output bench  batch={batch + 1:05d}/{batches}"
                f"  update={update + 1}/{updates_per_batch}  size={cols}x{rows}"
            )
            payload = "".join(parts)
            sys.stdout.write(payload)
            written += len(payload)
            sys.stdout.flush()
            if update + 1 < updates_per_batch:
                time.sleep(interval / updates_per_batch)
        sys.stdout.write(SYNC_OFF)
        sys.stdout.flush()

        batch_times.append(time.perf_counter() - batch_start)
        done += 1
        sleep_for = interval - batch_times[-1]
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    cleanup()

    if batch_times:
        avg_ms = (sum(batch_times) / len(batch_times)) * 1000
        min_ms = min(batch_times) * 1000
        max_ms = max(batch_times) * 1000
        p99_ms = sorted(batch_times)[int(len(batch_times) * 0.99)] * 1000
    else:
        avg_ms = min_ms = max_ms = p99_ms = 0.0

    sys.stdout.write(stat_line("sync-output", elapsed, "batches", max(1, done)))
    sys.stdout.write(
        f"bytes: {written} ({written / max(elapsed, 1e-9):.0f}/s)\n"
        f"batch duration (ms):  avg={avg_ms:.2f}  min={min_ms:.2f}  "
        f"max={max_ms:.2f}  p99={p99_ms:.2f}\n"
        f"mode: CSI ?2026h/l  updates_per_batch={updates_per_batch}\n"
    )

def chunked_frame_text(frame, row):
    red = (frame * 17 + row * 11) % 200 + 30
    green = (frame * 7 + row * 19) % 200 + 30
    blue = (frame * 23 + row * 5) % 200 + 30
    label = f" frame={frame:05d} row={row:03d} "
    body = (label + (" <>[]{}()##==++--" * 32))[:cols].ljust(cols)
    return (
        f"{CSI}{row + 1};1H{CSI}2K"
        f"{CSI}48;2;{red};{green};{blue}m{CSI}38;2;240;240;240m"
        f"{body}{RESET}"
    )

def run_chunked(frames, rate_hz=100, updates_per_frame=4, write_chunk_bytes=128, synchronized=True, write_delay_ms=0.0):
    """Split alternate-screen redraws into small PTY writes."""
    interval = 1.0 / rate_hz
    updates_per_frame = max(1, updates_per_frame)
    write_chunk_bytes = max(1, write_chunk_bytes)
    write_delay_s = write_delay_ms / 1000.0

    sys.stdout.write(HIDE + ALT_ON + CLEAR + HOME)
    sys.stdout.flush()
    frame_times = []
    written = 0
    done = 0
    start = time.perf_counter()

    for frame in range(frames):
        if not running:
            break
        batch_start = time.perf_counter()
        if synchronized:
            sys.stdout.write(SYNC_ON)
            sys.stdout.flush()
        for update in range(updates_per_frame):
            logical_frame = frame * updates_per_frame + update
            for row in range(rows - 1):
                data = chunked_frame_text(logical_frame, row).encode()
                for offset in range(0, len(data), write_chunk_bytes):
                    chunk = data[offset:offset + write_chunk_bytes]
                    os.write(sys.stdout.fileno(), chunk)
                    written += len(chunk)
                if write_delay_s > 0:
                    time.sleep(write_delay_s)
            status = f"{CSI}{rows};1H{CSI}0mchunked bench frame={logical_frame:05d} size={cols}x{rows}"
            status_bytes = status.encode()
            for offset in range(0, len(status_bytes), write_chunk_bytes):
                chunk = status_bytes[offset:offset + write_chunk_bytes]
                os.write(sys.stdout.fileno(), chunk)
                written += len(chunk)
            if update + 1 < updates_per_frame:
                time.sleep(interval / updates_per_frame)
        if synchronized:
            sys.stdout.write(SYNC_OFF)
            sys.stdout.flush()

        frame_times.append(time.perf_counter() - batch_start)
        done += 1
        sleep_for = interval - frame_times[-1]
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    cleanup()
    if frame_times:
        avg_ms = sum(frame_times) / len(frame_times) * 1000
        min_ms = min(frame_times) * 1000
        max_ms = max(frame_times) * 1000
        p99_ms = sorted(frame_times)[int(len(frame_times) * 0.99)] * 1000
    else:
        avg_ms = min_ms = max_ms = p99_ms = 0.0

    sys.stdout.write(stat_line("chunked", elapsed, "frames", max(1, done)))
    sys.stdout.write(
        f"bytes: {written} ({written / max(elapsed, 1e-9):.0f}/s)\n"
        f"frame duration (ms):  avg={avg_ms:.2f}  min={min_ms:.2f} "
        f"max={max_ms:.2f}  p99={p99_ms:.2f}\n"
        f"mode: {'CSI ?2026h/l' if synchronized else 'raw'}  "
        f"updates_per_frame={updates_per_frame} write_chunk_bytes={write_chunk_bytes} "
        f"write_delay_ms={write_delay_ms:.1f}\n"
    )

def codex_flash_row(row, frame, star, width):
    if row == 1:
        text = f"  Thinking {star}  pass={frame:05d}"
        red, green, blue = (44, 42, 58) if frame % 2 == 0 else (30, 34, 40)
    else:
        text = f"  {star} task update"
        red, green, blue = (33, 62, 43) if frame % 2 == 0 else (52, 38, 34)
    body = text[:width].ljust(width)
    return (
        f"{CSI}{row + 1};1H{CSI}2K"
        f"{CSI}48;2;{red};{green};{blue}m{CSI}38;2;235;240;245m"
        f"{body}{RESET}"
    )

def run_codex_flash(frames, rate_hz=100, updates_per_frame=1, write_chunk_bytes=128, write_delay_ms=0.0):
    """Model Codex live status: stable diff UI plus timer-driven star rows."""
    interval = 1.0 / max(1, rate_hz)
    updates_per_frame = max(1, updates_per_frame)
    write_chunk_bytes = max(1, write_chunk_bytes)
    write_delay_s = max(0.0, write_delay_ms / 1000.0)
    content_rows = max(1, rows - 1)

    sys.stdout.write(HIDE + ALT_ON + CLEAR + HOME + SYNC_ON)
    for row in range(content_rows):
        if row == 0:
            text = "  Codex  reviewing changes"
        elif row == 1:
            text = "  renderer reconciliation"
        else:
            text = f"  file_{row}.lua  unchanged"
        red, green, blue = (28, 54, 38) if row % 4 == 0 else (24, 32, 34)
        body = text[:cols].ljust(cols)
        sys.stdout.write(
            f"{CSI}{row + 1};1H{CSI}2K"
            f"{CSI}48;2;{red};{green};{blue}m{CSI}38;2;220;225;235m"
            f"{body}{RESET}"
        )
    sys.stdout.write(SYNC_OFF)
    sys.stdout.flush()

    start = time.perf_counter()
    frame_times = []
    written = 0
    done = 0
    for frame in range(frames):
        if not running:
            break
        tick_start = time.perf_counter()
        star = ("*", "+", ".", "+")[frame % 4]
        sys.stdout.write(SYNC_ON)
        for update in range(updates_per_frame):
            logical_frame = frame * updates_per_frame + update
            row = 1 + (logical_frame % max(1, content_rows - 1))
            payload = codex_flash_row(row, logical_frame, star, cols).encode()
            for offset in range(0, len(payload), write_chunk_bytes):
                chunk = payload[offset:offset + write_chunk_bytes]
                os.write(sys.stdout.fileno(), chunk)
                written += len(chunk)
                if write_delay_s > 0:
                    time.sleep(write_delay_s)
            if update + 1 < updates_per_frame:
                time.sleep(interval / updates_per_frame)
        sys.stdout.write(SYNC_OFF)
        sys.stdout.flush()
        frame_times.append(time.perf_counter() - tick_start)
        done += 1
        sleep_for = interval - frame_times[-1]
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    cleanup()
    if frame_times:
        avg_ms = sum(frame_times) / len(frame_times) * 1000
        min_ms = min(frame_times) * 1000
        max_ms = max(frame_times) * 1000
        p99_ms = sorted(frame_times)[int(len(frame_times) * 0.99)] * 1000
    else:
        avg_ms = min_ms = max_ms = p99_ms = 0.0
    sys.stdout.write(stat_line("codex-flash", elapsed, "frames", max(1, done)))
    sys.stdout.write(
        f"bytes: {written} ({written / max(elapsed, 1e-9):.0f}/s)\n"
        f"frame duration (ms):  avg={avg_ms:.2f}  min={min_ms:.2f} "
        f"max={max_ms:.2f}  p99={p99_ms:.2f}\n"
        f"mode: CSI ?2026h/l  updates_per_frame={updates_per_frame} "
        f"write_chunk_bytes={write_chunk_bytes} write_delay_ms={write_delay_ms:.1f}\n"
    )

def run_keypress(presses, rate_hz=100):
    """
    Simulate rapid j/k scrolling in nvim:
      - Enter alt screen, hide cursor
      - Fill viewport with initial content
      - Each 'keypress': scroll viewport up 1 line (CSI S), position cursor
        on the last content row, write the new line that scrolled into view
      - Sleep between keypresses to match rate_hz
      - Report: total keypresses, elapsed time, average and min/max inter-frame gap
    """
    interval = 1.0 / rate_hz  # target time between keypresses

    sys.stdout.write(HIDE + ALT_ON + CLEAR + HOME)
    # Fill the viewport with initial content (rows-1 lines of data, last line = status)
    content_rows = rows - 1
    for r in range(content_rows):
        sys.stdout.write(make_keypress_line(r, cols) + "\n")
    sys.stdout.flush()

    line_counter = content_rows  # next line number to write
    frame_times = []
    done = 0
    last_t = time.perf_counter()
    start = last_t

    for _ in range(presses):
        if not running:
            break

        # Scroll viewport up 1 line and write the new bottom line
        # CSI 1 S  → scroll up 1 (top line disappears, blank appears at bottom)
        # CSI <rows>;1 H → move to first column of last content row (1-indexed)
        sys.stdout.write(
            f"{CSI}1S"
            f"{CSI}{content_rows};1H"
            + make_keypress_line(line_counter, cols)
        )
        # Update status bar on final row
        sys.stdout.write(
            f"{CSI}{rows};1H"
            f"{CSI}0m"
            f"keypress bench  press={line_counter - content_rows + 1:05d}/{presses}"
            f"  size={cols}x{rows}  rate={rate_hz}hz  Ctrl-C to stop"
        )
        sys.stdout.flush()

        line_counter += 1
        now = time.perf_counter()
        elapsed_this = now - last_t
        frame_times.append(elapsed_this)
        last_t = now
        done += 1

        # pace to target rate: sleep whatever is left of the interval
        sleep_for = interval - elapsed_this
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    cleanup()

    if frame_times:
        avg_ms = (sum(frame_times) / len(frame_times)) * 1000
        min_ms = min(frame_times) * 1000
        max_ms = max(frame_times) * 1000
        p99_ms = sorted(frame_times)[int(len(frame_times) * 0.99)] * 1000
    else:
        avg_ms = min_ms = max_ms = p99_ms = 0.0

    sys.stdout.write(stat_line("keypress", elapsed, "presses", max(1, done)))
    sys.stdout.write(
        f"inter-press gap (ms):  avg={avg_ms:.2f}  min={min_ms:.2f}  "
        f"max={max_ms:.2f}  p99={p99_ms:.2f}\n"
    )
    sys.stdout.write(
        f"target rate: {rate_hz}hz  ({interval*1000:.1f}ms/press)\n"
    )

if mode == "scroll":
    run_scroll(count)
elif mode == "repaint":
    run_repaint(count)
elif mode == "keypress":
    run_keypress(count, rate_hz=rate_arg)
elif mode == "split-scroll":
    run_split_scroll(count, rate_hz=rate_arg)
elif mode == "sync-output":
    run_sync_output(count, rate_hz=rate_arg, updates_per_batch=sync_updates_arg)
elif mode == "chunked":
    run_chunked(count, rate_hz=rate_arg, updates_per_frame=sync_updates_arg, write_chunk_bytes=chunk_bytes, write_delay_ms=write_delay_ms)
elif mode == "chunked-raw":
    run_chunked(count, rate_hz=rate_arg, updates_per_frame=sync_updates_arg, write_chunk_bytes=chunk_bytes, synchronized=False, write_delay_ms=write_delay_ms)
elif mode == "codex-flash":
    run_codex_flash(count, rate_hz=rate_arg, updates_per_frame=sync_updates_arg, write_chunk_bytes=chunk_bytes, write_delay_ms=write_delay_ms)
else:
    prog = os.environ.get("HOLLOW_BENCH_PROG", "bench.sh")
    sys.stderr.write(
        "usage: %s [%s] [COUNT] [RATE_HZ] [UPDATES_PER_BATCH]"
        " [CHUNK_BYTES] [WRITE_DELAY_MS]\n" % (prog, "|".join(MODE_CHOICES))
    )
    sys.exit(2)