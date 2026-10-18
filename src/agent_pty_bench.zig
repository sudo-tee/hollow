//! Same client loop/clock/workloads for native Linux and dedicated agent PTYs.
//! No GUI, parser, multiplexing, shell integration or deployment qualification.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const Pty = @import("pty/pty.zig").Pty;
const AgentPty = @import("pty/agent.zig").AgentPty;
var a: std.mem.Allocator = std.heap.page_allocator;
const ready = "HOLLOW_READY\n";

const Config = struct {
    allocator: enum { page, smp, debug } = .debug,
    telemetry: bool = false,
    backend: enum { native, agent },
    workload: enum { prompt, output },
    connector_argv: []const []const u8 = &.{},
    samples: usize = 5000,
    bytes: usize = 10 * 1024 * 1024,
    timeout_ms: u32 = 30000,
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

fn receive(pty: *Pty, wake: *Wake, output: []u8, deadline: i128) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        if (clock() >= deadline) return error.Timeout;
        const epoch = wake.epoch.load(.acquire);
        const count = try pty.read(output[offset..]);
        offset += count;
        if (count == 0) {
            if (!pty.isAlive()) return error.EarlyExit;
            try wake.wait(epoch, deadline);
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
    if (cfg.samples == 0 or cfg.samples > 100000 or cfg.bytes == 0 or cfg.bytes > 1024 * 1024 * 1024 or cfg.timeout_ms == 0 or cfg.timeout_ms > 3600000) return error.InvalidArgument;
    const command = switch (cfg.workload) {
        .prompt => "stty raw -echo; printf 'HOLLOW_READY\\n'; while IFS= read -r token; do [ \"$token\" = DONE ] && exit 0; printf '%s\\n' \"$token\"; done",
        .output => try std.fmt.allocPrint(a, "stty raw -echo; printf 'HOLLOW_READY\\n'; read go; head -c {d} /dev/zero", .{cfg.bytes}),
    };
    defer if (cfg.workload == .output) a.free(command);
    var wake: Wake = .{};
    const notification: @import("pty/wake.zig").Wake = .{ .context = &wake, .callback = Wake.signal };
    const spawn_start = clock();
    var pty: Pty = switch (cfg.backend) {
        .agent => .{ .agent = try AgentPty.spawn(a, .{ .connector_argv = cfg.connector_argv, .argv = &.{ "/bin/sh", "-c", command }, .telemetry = cfg.telemetry }, 120, 40, notification) },
        .native => if (builtin.os.tag == .linux) blk: {
            // Native launch-command parser strips one quoting layer. Both
            // backends execute the identical script in /bin/sh -c.
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
    defer pty.deinit();
    const timeout: i128 = @as(i128, cfg.timeout_ms) * std.time.ns_per_ms;
    var greeting: [ready.len]u8 = undefined;
    try receive(&pty, &wake, &greeting, spawn_start + timeout);
    if (!std.mem.eql(u8, &greeting, ready)) return error.InvalidGreeting;
    const ready_ns = clock() - spawn_start;
    var timings: std.ArrayList(u64) = .empty;
    defer timings.deinit(a);
    var elapsed_ns: i128 = 0;
    var digest_hex: ?[64]u8 = null;
    switch (cfg.workload) {
        .prompt => {
            try timings.ensureTotalCapacity(a, cfg.samples);
            // Warmup stays out of recorded samples, but is byte-checked too.
            for (0..cfg.samples + 32) |index| {
                var token_buffer: [64]u8 = undefined;
                const token = try std.fmt.bufPrint(&token_buffer, "HOLLOW_{d:0>8}\n", .{index});
                var echo: [64]u8 = undefined;
                const start = clock();
                try pty.writeAll(token);
                try receive(&pty, &wake, echo[0..token.len], start + timeout);
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
                try receive(&pty, &wake, chunk, start + timeout);
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
    try exited(&pty, &wake, clock() + timeout);
    const result = .{
        .allocator = cfg.allocator,
        .telemetry = if (pty == .agent and cfg.telemetry) pty.agent.connection.metrics() else null,
        .backend = cfg.backend,
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
