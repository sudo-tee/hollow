//! Same client loop/clock/workloads for native, dedicated and shared agent PTYs.
//! No GUI, parser, focus hints, shell integration or deployment qualification.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const Pty = @import("pty/pty.zig").Pty;
const AgentPty = @import("pty/agent.zig").AgentPty;
const SharedConnection = @import("pty/agent.zig").SharedConnection;
const bulk_module = @import("agent_pty_bench_bulk.zig");
var a: std.mem.Allocator = std.heap.page_allocator;
const ready = "HOLLOW_READY\n";

const Config = struct {
    allocator: enum { page, smp, debug } = .debug,
    telemetry: bool = false,
    backend: enum { native, agent, shared },
    sessions: usize = 1,
    load: enum { idle, noisy, stalled } = .idle,
    bulk: bulk_module.Mode = .off,
    bulk_path: ?[]const u8 = null,
    bulk_exec_bytes: u32 = 524288,
    resize_every: u32 = 0,
    workload: enum { prompt, output },
    connector_argv: []const []const u8 = &.{},
    samples: usize = 5000,
    bytes: usize = 10 * 1024 * 1024,
    timeout_ms: u32 = 30000,
};

fn spawn(cfg: Config, command: []const u8, notification: @import("pty/wake.zig").Wake, owner: ?*SharedConnection) !Pty {
    const config: @import("pty/agent.zig").Config = .{ .connector_argv = cfg.connector_argv, .argv = &.{ "/bin/sh", "-c", command }, .telemetry = cfg.telemetry };
    return switch (cfg.backend) {
        .shared => .{ .agent = try AgentPty.spawnShared(a, owner.?, config, 120, 40) },
        .agent => .{ .agent = try AgentPty.spawn(a, config, 120, 40, notification) },
        .native => if (builtin.os.tag == .linux) blk: {
            var launch: std.Io.Writer.Allocating = .init(a);
            defer launch.deinit();
            try launch.writer.writeAll("/bin/sh -c '");
            for (command) |byte| {
                if (byte == '\'') try launch.writer.writeAll("'\\''") else try launch.writer.writeByte(byte);
            }
            try launch.writer.writeAll("'");
            break :blk .{ .native = try @import("pty/pty_posix.zig").PosixPty.spawn(a, "/bin/sh", 120, 40, null, null, .{ .command = launch.written() }, notification) };
        } else return error.NativeBenchmarkRequiresLinux,
    };
}

/// Identical bounded owner scheduling for all backends: foreground first, then
/// one 16 KiB read per background. Not a simulation of GUI focus/render policy.
const Backgrounds = struct {
    config: Config,
    ptys: [15]Pty = undefined,
    count: usize = 0,
    bytes: [15]u64 = @splat(0),
    max_gap_ns: [15]u64 = @splat(0),
    last_progress: [15]i128 = @splat(0),
    started: i128 = 0,
    bulk: ?*bulk_module.Bulk = null,
    fn reset(self: *Backgrounds) void {
        self.started = clock();
        self.bytes = @splat(0);
        self.max_gap_ns = @splat(0);
        self.last_progress = @splat(self.started);
    }
    fn service(self: *Backgrounds) !bool {
        if (self.started == 0) return false;
        var progress = if (self.bulk) |bulk| try bulk.service() else false;
        for (self.ptys[0..self.count], 0..) |*pty, index| {
            if (self.config.load == .stalled and index == 0) continue;
            var buffer: [16384]u8 = undefined;
            const count = try pty.read(&buffer);
            progress = progress or count > 0;
            for (buffer[0..count]) |byte| if (byte != 'A' + @as(u8, @intCast(index))) return error.CorruptBackground;
            self.bytes[index] += count;
            const now = clock();
            self.max_gap_ns[index] = @max(self.max_gap_ns[index], @as(u64, @intCast(now - self.last_progress[index])));
            if (count > 0) self.last_progress[index] = now;
            if (!pty.isAlive()) return error.BackgroundExited;
            if (pty.* == .agent and pty.pendingOutputBytes() > 65536) return error.UnboundedBackground;
        }
        return progress;
    }
    fn deinit(self: *Backgrounds) void {
        for (self.ptys[0..self.count]) |*pty| pty.deinit();
    }
};

const Wake = struct {
    epoch: std.atomic.Value(u32) = .init(0),
    fn signal(context: *anyopaque) void {
        const self: *Wake = @ptrCast(@alignCast(context));
        _ = self.epoch.fetchAdd(1, .release);
        io.get().futexWake(u32, &self.epoch.raw, 1);
    }
    fn wait(self: *Wake, previous: u32, deadline: i128) !void {
        const left = deadline - clock();
        if (left <= 0) return error.Timeout;
        // Native waitpid can become ready after the reader's final wake. This
        // heartbeat only bounds reaping; output timing ends before exit waits.
        try io.get().futexWaitTimeout(u32, &self.epoch.raw, previous, .{
            .duration = .{ .clock = .awake, .raw = .fromNanoseconds(@intCast(@min(left, 10 * std.time.ns_per_ms))) },
        });
    }
};

fn clock() i128 {
    return std.Io.Clock.awake.now(io.get()).toNanoseconds();
}

fn receive(pty: *Pty, wake: *Wake, backgrounds: *Backgrounds, output: []u8, deadline: i128) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        if (clock() >= deadline) return error.Timeout;
        const epoch = wake.epoch.load(.acquire);
        const count = try pty.read(output[offset..]);
        offset += count;
        const background_progress = try backgrounds.service();
        if (count == 0) {
            // POSIX waitpid can observe exit before the reader has copied the
            // last kernel bytes. Expected-byte deadline, not child liveness,
            // governs completion of this checked receive.
            if (!pty.isAlive() and pty.* == .agent) return error.EarlyExit;
            if (!background_progress) try wake.wait(epoch, deadline);
        }
    }
}

fn exited(pty: *Pty, wake: *Wake, deadline: i128) !void {
    while (true) {
        const epoch = wake.epoch.load(.acquire);
        var unexpected: [1]u8 = undefined;
        if (try pty.read(&unexpected) != 0) return error.ExtraOutput;
        if (!pty.isAlive()) break;
        try wake.wait(epoch, deadline);
    }
    if (pty.exitStatus() != 0) return error.BadExitStatus;
}

pub fn main(init: std.process.Init) !void {
    io.init(init.io, init.minimal.environ);
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedJsonConfiguration;
    const parsed = try std.json.parseFromSlice(Config, a, args[1], .{});
    defer parsed.deinit();
    const cfg = parsed.value;
    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = debug_allocator.deinit();
    a = switch (cfg.allocator) {
        .page => std.heap.page_allocator,
        .smp => std.heap.smp_allocator,
        .debug => debug_allocator.allocator(),
    };
    if (cfg.samples == 0 or cfg.samples > 100000 or cfg.bytes == 0 or cfg.bytes > 1024 * 1024 * 1024 or cfg.timeout_ms == 0 or cfg.timeout_ms > 3600000 or cfg.sessions == 0 or cfg.sessions > 16 or (cfg.load != .idle and cfg.sessions == 1)) return error.InvalidArgument;
    const bulk_jobs: usize = switch (cfg.bulk) {
        .off => 0,
        .mixed => 2,
        else => 1,
    };
    if (cfg.backend == .shared and cfg.sessions + bulk_jobs > SharedConnection.max_sessions) return error.InvalidArgument;
    const command = switch (cfg.workload) {
        .prompt => "stty raw -echo; printf 'HOLLOW_READY\\n'; while IFS= read -r token; do [ \"$token\" = DONE ] && exit 0; printf '%s\\n' \"$token\"; done",
        .output => try std.fmt.allocPrint(a, "stty raw -echo; printf 'HOLLOW_READY\\n'; read go; head -c {d} /dev/zero", .{cfg.bytes}),
    };
    defer if (cfg.workload == .output) a.free(command);
    var wake: Wake = .{};
    const notification: @import("pty/wake.zig").Wake = .{ .context = &wake, .callback = Wake.signal };
    const owner = if (cfg.backend == .shared) try SharedConnection.createWithTelemetry(a, cfg.connector_argv, notification, cfg.telemetry) else null;
    defer if (owner) |shared| shared.destroy();
    var backgrounds: Backgrounds = .{ .config = cfg };
    defer backgrounds.deinit();
    const spawn_start = clock();
    var pty = try spawn(cfg, command, notification, owner);
    defer pty.deinit();
    const timeout: i128 = @as(i128, cfg.timeout_ms) * std.time.ns_per_ms;
    var greeting: [ready.len]u8 = undefined;
    try receive(&pty, &wake, &backgrounds, &greeting, spawn_start + timeout);
    if (!std.mem.eql(u8, &greeting, ready)) return error.InvalidGreeting;
    const ready_ns = clock() - spawn_start;
    for (0..cfg.sessions - 1) |index| {
        const background_command = if (cfg.load == .idle)
            try a.dupe(u8, "stty raw -echo; printf 'HOLLOW_READY\\n'; read go; sleep 600")
        else
            try std.fmt.allocPrint(a, "stty raw -echo; printf 'HOLLOW_READY\\n'; read go; head -c 1073741824 /dev/zero | tr '\\000' '{c}'; sleep 600", .{'A' + @as(u8, @intCast(index))});
        defer a.free(background_command);
        backgrounds.ptys[index] = try spawn(cfg, background_command, notification, owner);
        backgrounds.count += 1;
        try receive(&backgrounds.ptys[index], &wake, &backgrounds, &greeting, clock() + timeout);
        if (!std.mem.eql(u8, &greeting, ready)) return error.InvalidGreeting;
    }
    var bulk = try bulk_module.Bulk.init(a, io.get(), cfg.bulk, cfg.bulk_path, cfg.bulk_exec_bytes, cfg.connector_argv, .{ .context = &wake, .notify = Wake.signal, .telemetry = cfg.telemetry }, if (owner) |shared| shared.connection else null);
    defer bulk.deinit();
    // Warm exactly one checked RPC of each enabled kind before starting load.
    // No cold separate-agent HELLO is compared with an already-warm shared one.
    bulk.priming = true;
    const prime_deadline = clock() + timeout;
    while (true) {
        const epoch = wake.epoch.load(.acquire);
        _ = try bulk.service();
        bulk.requireProgress() catch {
            try wake.wait(epoch, prime_deadline);
            continue;
        };
        break;
    }
    bulk.priming = false;
    bulk.stats = .{};
    for (backgrounds.ptys[0..backgrounds.count]) |*background| try background.writeAll("GO\n");
    backgrounds.bulk = &bulk;
    backgrounds.reset();
    var timings: std.ArrayList(u64) = .empty;
    defer timings.deinit(a);
    var elapsed_ns: i128 = 0;
    var digest_hex: ?[64]u8 = null;
    var resizes_issued: usize = 0;
    switch (cfg.workload) {
        .prompt => {
            try timings.ensureTotalCapacity(a, cfg.samples);
            // Warmup stays out of recorded samples, but is byte-checked too.
            for (0..cfg.samples + 32) |index| {
                var token_buffer: [64]u8 = undefined;
                const token = try std.fmt.bufPrint(&token_buffer, "HOLLOW_{d:0>8}\n", .{index});
                var echo: [64]u8 = undefined;
                const start = clock();
                if (cfg.resize_every != 0 and index % cfg.resize_every == 0) {
                    pty.resize(@intCast(120 + resizes_issued % 2), 40);
                    resizes_issued += 1;
                }
                try pty.writeAll(token);
                try receive(&pty, &wake, &backgrounds, echo[0..token.len], start + timeout);
                const duration: u64 = @intCast(clock() - start);
                if (!std.mem.eql(u8, token, echo[0..token.len])) return error.CorruptEcho;
                if (index >= 32) timings.appendAssumeCapacity(duration);
            }
            try pty.writeAll("DONE\n");
        },
        .output => {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var remaining = cfg.bytes;
            const start = clock();
            try pty.writeAll("GO\n");
            while (remaining > 0) {
                var buffer: [16384]u8 = undefined;
                const chunk = buffer[0..@min(buffer.len, remaining)];
                try receive(&pty, &wake, &backgrounds, chunk, start + timeout);
                for (chunk) |byte| if (byte != 0) return error.CorruptOutput;
                hash.update(chunk);
                remaining -= chunk.len;
            }
            elapsed_ns = clock() - start;
            var digest: [32]u8 = undefined;
            hash.final(&digest);
            digest_hex = std.fmt.bytesToHex(digest, .lower);
        },
    }
    const background_elapsed_ns = clock() - backgrounds.started;
    try bulk.requireProgress();
    const stalled_buffered = if (cfg.load == .stalled) backgrounds.ptys[0].pendingOutputBytes() else 0;
    for (backgrounds.bytes[0..backgrounds.count], 0..) |bytes, index| {
        if (cfg.load != .idle and !(cfg.load == .stalled and index == 0) and bytes == 0) return error.BackgroundStarved;
    }
    try exited(&pty, &wake, clock() + timeout);
    const result = .{
        .allocator = cfg.allocator,
        .telemetry = if (pty == .agent and cfg.telemetry) pty.agent.connection.metrics() else null,
        .backend = cfg.backend,
        .sessions = cfg.sessions,
        .load = cfg.load,
        .bulk = cfg.bulk,
        .bulk_lane = if (cfg.bulk == .off) "off" else if (cfg.backend == .shared) "shared" else "separate_agent",
        .bulk_stats = bulk.stats,
        .bulk_telemetry = if (cfg.telemetry and bulk.connection != null) bulk.connection.?.metrics() else null,
        .resize_every = cfg.resize_every,
        .resizes_issued = resizes_issued,
        .background_bytes = backgrounds.bytes[0..backgrounds.count],
        .background_max_gap_ns = backgrounds.max_gap_ns[0..backgrounds.count],
        .background_elapsed_ns = background_elapsed_ns,
        .stalled_buffered = stalled_buffered,
        .build_mode = builtin.mode,
        .zig_version = builtin.zig_version_string,
        .cols = 120,
        .rows = 40,
        .prompt_warmups = 32,
        .workload = cfg.workload,
        .spawn_to_ready_ns = ready_ns,
        .samples_ns = timings.items,
        .bytes = if (cfg.workload == .output) cfg.bytes else 0,
        .elapsed_ns = elapsed_ns,
        .sha256 = if (digest_hex) |*hex| hex[0..] else null,
        .exit_code = pty.exitStatus(),
        .wait_mode = "wake_with_10ms_reap_heartbeat",
        .qualification = false,
    };
    const json = try std.json.Stringify.valueAlloc(a, result, .{});
    defer a.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
