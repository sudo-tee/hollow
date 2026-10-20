//! Native pane-adapter diagnostic, without VT parsing/rendering. Positional CLI:
//! AGENT pty|mux PANES BYTES_PER_PANE FRAME_US CONNECTOR_DELAY_MS [connector argv...]
//! Sequential ready markers measure connection reuse; frame turns drain only
//! each queue's initial snapshot, never wait within a frame for more bytes.
//! Python driver sets HOLLOW_PANE_BENCH_READ_CHUNK, _ECHO_SAMPLES and _DRAIN_BYTES
//! to select chunk sizes or focused echoes with quota-limited background drains.
const std = @import("std");
const io = @import("io.zig");
const agent = @import("pty/agent.zig");
const mux = @import("pty/agent_mux.zig");
const a = std.heap.smp_allocator;

fn number(args: *std.process.Args.Iterator) !usize {
    return std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
}

fn sleep(ns: u64) !void {
    try std.Io.sleep(io.get(), .fromNanoseconds(ns), .awake);
}

fn envNumber(name: []const u8, fallback: usize) !usize {
    const text = io.getEnvVarOwned(a, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return fallback,
        else => return err,
    };
    defer a.free(text);
    return std.fmt.parseInt(usize, text, 10);
}

fn printResult(value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(json);
    try std.Io.File.stdout().writeStreamingAll(io.get(), json);
    try std.Io.File.stdout().writeStreamingAll(io.get(), "\n");
}

fn mixed(panes: []agent.AgentPty, mode: []const u8, startup_ms: []const f64, connections: usize, frame_us: usize, chunk: usize, quota: usize, samples: usize, delay_ms: usize) !void {
    const focused = &panes[panes.len - 1];
    const floods = panes[0 .. panes.len - 1];
    focused.setFocused(true);
    for (floods) |*pane| try pane.writeAll("g");
    const counts = try a.alloc(usize, floods.len);
    defer a.free(counts);
    @memset(counts, 0);
    const echoes = try a.alloc(f64, samples);
    defer a.free(echoes);
    const begin = io.nanoTimestamp();
    const deadline = begin + 120 * std.time.ns_per_s;
    var next_frame = begin;
    var next_send = begin + 100 * std.time.ns_per_ms;
    var sent: ?i128 = null;
    var token: [1]u8 = undefined;
    var completed: usize = 0;
    var queue_high: usize = 0;
    var turns: usize = 0;
    var buffer: [384 * 1024]u8 = undefined;
    while (completed < samples) {
        const now = io.nanoTimestamp();
        if (now > deadline) return error.EchoTimeout;
        if (sent == null and now >= next_send) {
            token[0] = @truncate(completed);
            sent = io.nanoTimestamp();
            try focused.writeAll(&token);
        }
        const n = try focused.read(buffer[0..1]);
        if (n > 0) {
            if (sent == null or buffer[0] != token[0]) return error.InvalidEcho;
            const end = io.nanoTimestamp();
            echoes[completed] = @as(f64, @floatFromInt(end - sent.?)) / std.time.ns_per_ms;
            completed += 1;
            sent = null;
            next_send = end + 5 * std.time.ns_per_ms;
        }
        if (!focused.isAlive()) return error.EndOfStream;
        if (now >= next_frame) {
            next_frame = now + @as(i128, frame_us) * std.time.ns_per_us;
            for (floods, counts) |*pane, *count| {
                const snapshot = pane.pendingOutputBytes();
                queue_high = @max(queue_high, snapshot);
                var pending = @min(snapshot, quota);
                while (pending > 0) {
                    const got = try pane.read(buffer[0..@min(chunk, pending)]);
                    if (got == 0) return error.InvalidPending;
                    for (buffer[0..got]) |byte| if (byte != 'x') return error.InvalidOutput;
                    pending -= got;
                    count.* += got;
                }
                if (!pane.isAlive()) return error.EndOfStream;
            }
            turns += 1;
        }
        // Focused reads are polled independently of background frame cadence.
        // This is adapter/driver latency, not full GUI event/render latency.
        try sleep(100_000);
    }
    const seconds = @as(f64, @floatFromInt(io.nanoTimestamp() - begin)) / std.time.ns_per_s;
    var total: usize = 0;
    var reader_copy: u64 = 0;
    var consumer_copy: u64 = 0;
    var empty_reads: u64 = 0;
    for (counts) |count| {
        if (count == 0) return error.StarvedFlood;
        total += count;
    }
    for (panes) |*pane| {
        pane.session.mutex.lock();
        reader_copy += pane.session.reader_compacted_bytes;
        consumer_copy += pane.session.consumer_compacted_bytes;
        empty_reads += pane.session.empty_reads;
        pane.session.mutex.unlock();
    }
    var reserved_high: usize = 0;
    var notifications: u64 = 0;
    var owner_turns: u64 = 0;
    if (focused.session.mux_connection) |c| {
        c.mutex.lock();
        reserved_high = c.output_high_water;
        notifications = c.ui_notifications;
        owner_turns = c.owner_turns;
        c.mutex.unlock();
    }
    std.mem.sort(f64, echoes, {}, std.sort.asc(f64));
    const tuning = focused.session.host.multiplex;
    try printResult(.{
        .workload = "native adapter focused echo under frame-paced backlogs",
        .mode = mode,
        .panes = panes.len,
        .connections = connections,
        .startup_ms = startup_ms,
        .cols = 80,
        .rows = 24,
        .preinstalled_agent = true,
        .mux_read_workers = if (tuning) |t| t.read_workers else 0,
        .mux_read_batch_jobs = if (tuning) |t| t.batch_jobs else 0,
        .synthetic_connector_delay_ms = delay_ms,
        .frame_us = frame_us,
        .read_chunk = chunk,
        .background_drain_bytes = quota,
        .focused_poll_us = 100,
        .echo_interval_us = 5000,
        .warmup_ms = 100,
        .samples = completed,
        .seconds = seconds,
        .echo_ms = .{ .p50 = echoes[(samples * 50 + 99) / 100 - 1], .p95 = echoes[(samples * 95 + 99) / 100 - 1], .p99 = echoes[(samples * 99 + 99) / 100 - 1], .max = echoes[samples - 1] },
        .flood_bytes = counts,
        .flood_mib_per_second = @as(f64, @floatFromInt(total)) / (1024 * 1024) / seconds,
        .queue_high_water = queue_high,
        .mux_output_reservation_high_water = reserved_high,
        .reader_compacted_bytes = reader_copy,
        .consumer_compacted_bytes = consumer_copy,
        .empty_reads = empty_reads,
        .ui_notifications = notifications,
        .owner_turns = owner_turns,
        .drain_turns = turns,
    });
}

pub fn main(init: std.process.Init) !void {
    io.init(init.io, init.minimal.environ);
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingAgent;
    const mode = args.next() orelse return error.MissingMode;
    const shared = std.mem.eql(u8, mode, "mux");
    if (!shared and !std.mem.eql(u8, mode, "pty")) return error.InvalidMode;
    const count = try number(&args);
    const bytes_per_pane = try number(&args);
    const frame_us = try number(&args);
    const delay_ms = try number(&args);
    const read_chunk = try envNumber("HOLLOW_PANE_BENCH_READ_CHUNK", 65536);
    const samples = try envNumber("HOLLOW_PANE_BENCH_ECHO_SAMPLES", 0);
    const quota = try envNumber("HOLLOW_PANE_BENCH_DRAIN_BYTES", 16384);
    if (samples > 10000 or (samples > 0 and count < 2) or quota == 0 or quota > mux.output_limit) return error.InvalidMixedSettings;
    if (read_chunk == 0 or read_chunk > 384 * 1024) return error.InvalidReadChunk;
    if (count == 0 or count > 32 or bytes_per_pane == 0 or bytes_per_pane > 1024 * 1024 * 1024 or frame_us > 1_000_000 or delay_ms > 60_000) return error.InvalidArgument;
    var connector: std.ArrayList([]const u8) = .empty;
    defer connector.deinit(a);
    while (args.next()) |arg| try connector.append(a, arg);
    var host: agent.Host = .{ .agent = .{ .path = path }, .connector = .{ .argv = connector.items } };
    if (shared) host.multiplex = .{};
    // Synthetic connector startup cost, NOT network latency or SSH qualification.
    const delay = try std.fmt.allocPrint(a, "{d}.{d:0>3}", .{ delay_ms / 1000, delay_ms % 1000 });
    defer a.free(delay);
    if (delay_ms > 0) {
        if (connector.items.len != 0) return error.DelayWithConnector;
        host.connector.argv = &.{ "/bin/sh", "-c", "sleep \"$1\"; shift; exec \"$@\"", "pane-bench-delay", delay };
    }
    const shell = try std.fmt.allocPrintSentinel(a, "wsl.exe --exec python3 -c \"import os,tty;tty.setraw(0);os.write(1,b'R');os.read(0,1);data=b'x'*65536;exec('left={d}\\nwhile left:\\n n=os.write(1,data[:min(left,len(data))]);left-=n');os.read(0,1)\"", .{bytes_per_pane}, 0);
    defer a.free(shell);
    const panes = try a.alloc(agent.AgentPty, count);
    defer a.free(panes);
    var initialized: usize = 0;
    defer mux.shutdown();
    defer for (panes[0..initialized]) |*pane| pane.closeAndJoin();
    const startup_ms = try a.alloc(f64, count);
    defer a.free(startup_ms);
    var buffer: [384 * 1024]u8 = undefined;
    const deadline = io.nanoTimestamp() + 120 * std.time.ns_per_s;
    for (panes, 0..) |*pane, index| {
        const begin = io.nanoTimestamp();
        pane.* = try agent.AgentPty.init(a, .{
            .shell = if (samples == 0) shell else if (index == count - 1)
                "wsl.exe --exec python3 -c \"import os,tty;tty.setraw(0);os.write(1,b'R');exec('while True:\\n data=os.read(0,1)\\n os.write(1,data)')\""
            else
                "wsl.exe --exec python3 -c \"import os,tty;tty.setraw(0);os.write(1,b'R');os.read(0,1);data=b'x'*65536;exec('while True:\\n os.write(1,data)')\"",
            .cols = 80,
            .rows = 24,
            .cwd = "/",
            .env_block = null,
            .launch_command = null,
            .host = host,
        }, .{});
        initialized += 1;
        try pane.start();
        while (true) {
            if (io.nanoTimestamp() > deadline) return error.StartupTimeout;
            const n = try pane.read(&buffer);
            if (n > 0) {
                if (n != 1 or buffer[0] != 'R') return error.InvalidReady;
                break;
            }
            if (!pane.isAlive()) return error.EndOfStream;
            try sleep(100_000);
        }
        startup_ms[index] = @as(f64, @floatFromInt(io.nanoTimestamp() - begin)) / std.time.ns_per_ms;
    }
    var connections: usize = 0;
    for (panes, 0..) |pane, index| {
        var seen = false;
        if (shared) for (panes[0..index]) |earlier| {
            if (earlier.session.mux_connection == pane.session.mux_connection) seen = true;
        };
        if (!seen) connections += 1;
    }
    if (samples > 0) return mixed(panes, mode, startup_ms, connections, frame_us, read_chunk, quota, samples, delay_ms);
    const received = try a.alloc(usize, count);
    defer a.free(received);
    @memset(received, 0);
    const begin = io.nanoTimestamp();
    for (panes) |*pane| try pane.writeAll("g");
    var remaining = bytes_per_pane * count;
    var queue_high: usize = 0;
    var aggregate_high: usize = 0;
    var turns: usize = 0;
    var next_frame = begin;
    while (remaining > 0) {
        if (io.nanoTimestamp() > deadline) return error.BulkTimeout;
        if (frame_us > 0) {
            next_frame += @as(i128, frame_us) * std.time.ns_per_us;
            const wait = next_frame - io.nanoTimestamp();
            if (wait > 0) try sleep(@intCast(wait));
        }
        var progress: usize = 0;
        var aggregate: usize = 0;
        for (panes, received) |*pane, *total| {
            var pending = pane.pendingOutputBytes();
            queue_high = @max(queue_high, pending);
            aggregate += pending;
            // Snapshot bounds this synthetic UI turn even if readers refill.
            while (pending > 0) {
                const n = try pane.read(buffer[0..@min(read_chunk, pending)]);
                if (n == 0) return error.InvalidPending;
                for (buffer[0..n]) |byte| if (byte != 'x') return error.InvalidOutput;
                total.* += n;
                if (total.* > bytes_per_pane) return error.ExcessOutput;
                pending -= n;
                remaining -= n;
                progress += n;
            }
            if (total.* < bytes_per_pane and !pane.isAlive()) return error.EndOfStream;
        }
        aggregate_high = @max(aggregate_high, aggregate);
        turns += 1;
        if (frame_us == 0 and progress == 0) try sleep(100_000);
    }
    const seconds = @as(f64, @floatFromInt(io.nanoTimestamp() - begin)) / std.time.ns_per_s;
    var reservation_high: usize = 0;
    var reader_compacted: u64 = 0;
    var consumer_compacted: u64 = 0;
    for (panes) |*pane| {
        const s = pane.session;
        s.mutex.lock();
        reader_compacted += s.reader_compacted_bytes;
        consumer_compacted += s.consumer_compacted_bytes;
        s.mutex.unlock();
    }
    if (shared) {
        const connection = panes[0].session.mux_connection.?;
        connection.mutex.lock();
        reservation_high = connection.output_high_water;
        connection.mutex.unlock();
    }
    const result = try std.json.Stringify.valueAlloc(a, .{
        .workload = "native-pane-adapter",
        .mode = mode,
        .panes = count,
        .bytes_per_pane = bytes_per_pane,
        .frame_us = frame_us,
        .read_chunk = read_chunk,
        .synthetic_connector_delay_ms = delay_ms,
        .preinstalled_agent = true,
        .connections = connections,
        .cols = 80,
        .rows = 24,
        .mux_read_workers = if (shared) host.multiplex.?.read_workers else 0,
        .mux_read_batch_jobs = if (shared) host.multiplex.?.batch_jobs else 0,
        .startup_ms = startup_ms,
        .bulk_seconds = seconds,
        .mib_per_second = @as(f64, @floatFromInt(bytes_per_pane * count)) / (1024 * 1024) / seconds,
        .queue_high_water = queue_high,
        .aggregate_queue_high_water = aggregate_high,
        .mux_output_reservation_high_water = reservation_high,
        .reader_compacted_bytes = reader_compacted,
        .consumer_compacted_bytes = consumer_compacted,
        .drain_turns = turns,
        .received = received,
    }, .{});
    defer a.free(result);
    try std.Io.File.stdout().writeStreamingAll(io.get(), result);
    try std.Io.File.stdout().writeStreamingAll(io.get(), "\n");
}
