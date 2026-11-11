//! Bounded Windows-owned WSL connections. GUI clients borrow pins, never the
//! process/job. Only successful guest empty completion permits idle collection.
const std = @import("std");
const windows = std.os.windows;
const io = @import("../io.zig");
const pipe = @import("session_pipe_windows.zig");
const p = @import("session_protocol.zig");
const Job = @import("../pty/windows_job.zig").Job;

extern "kernel32" fn GetSystemDirectoryW([*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn ResumeThread(windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(windows.HANDLE, *u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateProcess(windows.HANDLE, u32) callconv(.winapi) windows.BOOL;

// 16 client read/write pairs + wake + 8 keeper triples fit the Win32 64-handle
// wait limit. Admission occurs before allocating or executing another child.
pub const max_hosts = 8;
const startup_ms = 30_000;
const write_ms = 5000;

pub const Registry = struct {
    a: std.mem.Allocator,
    fixture: bool,
    entries: [max_hosts]?*Entry = @splat(null),
    stopping: bool = false,
    retiring: bool = false,

    pub fn acquire(self: *Registry, spec: p.WslHold, now: u64) !*Entry {
        try spec.validate(self.fixture);
        var empty: ?usize = null;
        for (&self.entries, 0..) |*slot, index| {
            if (slot.*) |entry| {
                if (sameHost(entry.spec, spec)) {
                    if (entry.empty_confirmed) return error.OwnerRetiring;
                    if (entry.failed) return error.KeepaliveFailed;
                    if (!std.mem.eql(u8, entry.spec.launcher, spec.launcher)) return error.KeepaliveHostConflict;
                    if (entry.pins == 16 or entry.generation == std.math.maxInt(u32)) return error.ResourceExhausted;
                    if (entry.pins == 0) {
                        entry.generation += 1;
                        entry.acknowledged = 0;
                        entry.empty_confirmed = false;
                        entry.ready_deadline = now + startup_ms;
                    }
                    entry.pins += 1;
                    return entry;
                }
            } else if (empty == null) empty = index;
        }
        const index = empty orelse return error.ResourceExhausted;
        const entry = try Entry.create(self.a, spec, now, null);
        entry.draining = self.retiring;
        self.entries[index] = entry;
        return entry;
    }

    pub fn release(_: *Registry, entry: *Entry) void {
        std.debug.assert(entry.pins > 0);
        entry.pins -= 1;
        if (entry.pins == 0) entry.acknowledged = 0;
    }

    pub fn tick(self: *Registry, now: u64) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            if (entry.failed and (entry.ever_ready or entry.draining) and !self.stopping) {
                if (now >= entry.retry_at) self.restart(entry, now) catch {
                    entry.retry_at = now + 1000;
                };
                continue;
            }
            const ended = entry.tick(now) catch |err| blk: {
                std.log.warn("WSL keepalive for {s} failed: {s}", .{ entry.spec.distro, @errorName(err) });
                entry.fail();
                entry.retry_at = now + 1000;
                break :blk false;
            };
            if ((ended or (entry.failed and !entry.ever_ready and !entry.draining)) and entry.pins == 0) {
                entry.destroy(self.a);
                slot.* = null;
            }
        };
    }

    pub fn hasEntries(self: *const Registry) bool {
        for (self.entries) |entry| if (entry != null) return true;
        return false;
    }

    /// Draining ignores idle GUI pins, but retains slot borrows so clients
    /// can still reconnect to live guests. The guest seals empty admission.
    pub fn retire(self: *Registry) void {
        self.retiring = true;
        for (self.entries) |slot| if (slot) |entry| {
            entry.draining = true;
        };
    }

    pub fn drained(self: *const Registry) bool {
        for (self.entries) |slot| if (slot) |entry| {
            if (entry.failed or !entry.draining or !entry.empty_confirmed) return false;
        };
        return true;
    }

    pub fn events(self: *const Registry, out: []windows.HANDLE) usize {
        var count: usize = 0;
        for (self.entries) |slot| if (slot) |entry| {
            if (entry.failed) continue;
            out[count] = entry.child.id.?;
            count += 1;
            if (entry.reading) {
                out[count] = entry.output.event;
                count += 1;
            }
            if (entry.writing) {
                out[count] = entry.input.event;
                count += 1;
            }
        };
        return count;
    }

    pub fn deadline(self: *const Registry) ?u64 {
        var result: ?u64 = null;
        for (self.entries) |slot| if (slot) |entry| {
            if (entry.failed) {
                if (entry.ever_ready and !self.stopping) result = @min(result orelse std.math.maxInt(u64), entry.retry_at);
                continue;
            }
            if (entry.pins > 0 and !entry.ready()) result = @min(result orelse std.math.maxInt(u64), entry.ready_deadline);
            if (entry.writing) result = @min(result orelse std.math.maxInt(u64), entry.write_deadline);
        };
        return result;
    }

    pub fn stop(self: *Registry) void {
        self.stopping = true;
        for (self.entries) |slot| if (slot) |entry| entry.fail();
    }

    pub fn deinit(self: *Registry) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            entry.destroy(self.a);
            slot.* = null;
        };
    }

    fn restart(self: *Registry, entry: *Entry, now: u64) !void {
        if (entry.generation == std.math.maxInt(u32)) return error.ResourceExhausted;
        const replacement = try Entry.create(self.a, entry.spec, now, entry.fixture_argv);
        const pins = entry.pins;
        const draining = entry.draining;
        const generation = entry.generation + 1;
        // No operation is pending in the replacement until its first tick, so
        // move it into the existing heap-stable identity borrowed by clients.
        entry.deinitResources();
        entry.* = replacement.*;
        self.a.destroy(replacement);
        entry.pins = pins;
        entry.draining = draining;
        entry.generation = generation;
        entry.acknowledged = 0;
        entry.ever_ready = true;
    }
};

pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    spec: p.WslHold,
    child: std.process.Child,
    job: Job,
    handle: windows.HANDLE,
    input: pipe.Operation,
    output: pipe.Operation,
    incoming: [5]u8 = undefined,
    received: usize = 0,
    outgoing: [5]u8 = undefined,
    writing: bool = false,
    reading: bool = false,
    failed: bool = false,
    degraded: bool = false,
    output_ended: bool = false,
    empty_confirmed: bool = false,
    ever_ready: bool = false,
    retry_at: u64 = 0,
    fixture_argv: ?[]const []const u8 = null,
    pins: u8 = 1,
    generation: u32 = 1,
    acknowledged: u32 = 0,
    sent_generation: u32 = 1,
    sent_pin: bool = true,
    draining: bool = false,
    sent_drain: bool = false,
    ready_deadline: u64,
    write_deadline: u64 = 0,

    fn create(a: std.mem.Allocator, spec: p.WslHold, now: u64, fixture_argv: ?[]const []const u8) !*Entry {
        const self = try a.create(Entry);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const temp = arena.allocator();
        const owned: p.WslHold = .{
            .distro = try temp.dupe(u8, spec.distro),
            .user = if (spec.user) |value| try temp.dupe(u8, value) else null,
            .launcher = try temp.dupe(u8, spec.launcher),
            .agent = try temp.dupe(u8, spec.agent),
            .session_dir = if (spec.session_dir) |value| try temp.dupe(u8, value) else null,
        };
        var input = try pipe.Operation.init();
        errdefer input.deinit();
        // The operation must already have its final address before submission.
        self.* = .{
            .arena = arena,
            .spec = owned,
            .child = undefined,
            .job = undefined,
            .handle = undefined,
            .input = input,
            .output = undefined,
            .ready_deadline = now + startup_ms,
        };
        if (fixture_argv) |args| {
            const copied = try temp.alloc([]const u8, args.len);
            for (args, copied) |arg, *dest| dest.* = try temp.dupe(u8, arg);
            self.fixture_argv = copied;
        }
        self.output = try pipe.Operation.init();
        errdefer self.output.deinit();
        self.job = try Job.create();
        errdefer self.job.close();
        const argv = fixture_argv orelse try command(temp, owned);
        const process = try @import("session_keepalive_process_windows.zig").spawn(temp, argv);
        self.child = process.child;
        self.handle = process.input;
        errdefer pipe.close(self.handle);
        errdefer self.child.kill(io.get());
        try self.job.assign(self.child.id.?);
        if (ResumeThread(self.child.thread_handle) == 0xffffffff) return error.ResumeFailed;
        // `temp` points at the local arena; capture its final allocation head
        // only after argv/process preparation has finished allocating.
        self.arena = arena;
        return self;
    }

    pub fn ready(self: *const Entry) bool {
        return !self.failed and self.pins > 0 and self.acknowledged == self.generation;
    }

    fn fail(self: *Entry) void {
        if (self.failed) return;
        self.failed = true;
        self.job.close();
        self.input.cancel(self.handle);
        self.output.cancel(self.child.stdout.?.handle);
        self.writing = false;
        self.reading = false;
    }

    fn destroy(self: *Entry, a: std.mem.Allocator) void {
        self.deinitResources();
        a.destroy(self);
    }

    fn deinitResources(self: *Entry) void {
        self.fail();
        self.child.kill(io.get());
        self.input.deinit();
        self.output.deinit();
        pipe.close(self.handle);
        self.arena.deinit();
    }

    fn tick(self: *Entry, now: u64) !bool {
        if (self.failed) return true;
        const exited = WaitForSingleObject(self.child.id.?, 0) == 0;
        if (exited) {
            var status: u32 = 1;
            if (!GetExitCodeProcess(self.child.id.?, &status).toBool()) return error.KeepaliveFailed;
            if (status != 0 or (self.pins > 0 and !self.draining)) {
                std.log.warn("WSL keeper exited with status {d} while pins={d}", .{ status, self.pins });
                return error.KeepaliveFailed;
            }
        }
        if (self.pins > 0 and !self.ready() and now >= self.ready_deadline) return error.Timeout;
        if (self.reading) {
            if (self.output.result(self.child.stdout.?.handle) catch |err| if (err == error.BrokenPipe) @as(?usize, 0) else return err) |n| {
                self.reading = false;
                if (n == 0) self.output_ended = true;
                self.received += n;
                if (self.received == self.incoming.len) {
                    const generation = std.mem.readInt(u32, self.incoming[1..5], .little);
                    switch (self.incoming[0]) {
                        'R', 'P' => if (generation == self.generation and self.pins > 0) {
                            self.acknowledged = generation;
                            self.ever_ready = true;
                        },
                        'F' => {
                            self.degraded = true;
                        }, // Unknown count: guest keeps holding.
                        'E' => if (generation == self.generation and (self.pins == 0 or self.draining)) {
                            self.empty_confirmed = true;
                        },
                        else => return error.InvalidControl,
                    }
                    self.received = 0;
                }
            }
        }
        if (self.empty_confirmed and self.draining) {
            // Confirmation is valid only while the helper retains the guest
            // admission barrier. A dead helper is unknown, even after E.
            if (exited) return error.KeepaliveFailed;
            return false;
        }
        if (self.empty_confirmed and self.pins == 0) {
            self.fail();
            return true;
        }
        if (exited) {
            // Drain the final control even after process exit. Status 0 alone
            // could mean parent-stdin EOF, not an authoritative empty list.
            if (self.output_ended) return error.KeepaliveFailed;
        }
        if (!self.reading and !self.output_ended) {
            try self.output.read(self.child.stdout.?.handle, self.incoming[self.received..]);
            self.reading = true;
        }
        if (self.writing) {
            if (try self.input.result(self.handle)) |n| {
                if (n != self.outgoing.len) return error.WriteFailed;
                self.writing = false;
            } else if (now >= self.write_deadline) return error.Timeout;
        }
        const pin = self.pins > 0;
        if (!self.writing and (self.sent_pin != pin or self.sent_generation != self.generation or self.sent_drain != self.draining)) {
            self.outgoing[0] = if (self.draining) 'D' else if (pin) 'P' else 'U';
            std.mem.writeInt(u32, self.outgoing[1..5], self.generation, .little);
            try self.input.write(self.handle, &self.outgoing);
            self.writing = true;
            self.write_deadline = now + write_ms;
            self.sent_pin = pin;
            self.sent_drain = self.draining;
            self.sent_generation = self.generation;
        }
        return false;
    }
};

fn sameHost(first: p.WslHold, second: p.WslHold) bool {
    return std.ascii.eqlIgnoreCase(first.distro, second.distro) and optionalEqual(first.user, second.user) and optionalEqual(first.session_dir, second.session_dir);
}

fn optionalEqual(first: ?[]const u8, second: ?[]const u8) bool {
    if (first == null or second == null) return first == null and second == null;
    return std.mem.eql(u8, first.?, second.?);
}

fn command(a: std.mem.Allocator, spec: p.WslHold) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const launcher = if (std.ascii.eqlIgnoreCase(spec.launcher, "wsl.exe")) blk: {
        var buffer: [32 * 1024]u16 = undefined;
        const len = GetSystemDirectoryW(&buffer, buffer.len);
        if (len == 0 or len >= buffer.len) return error.InvalidArgument;
        const root = try std.unicode.utf16LeToUtf8Alloc(a, buffer[0..len]);
        break :blk try std.fs.path.join(a, &.{ root, "wsl.exe" });
    } else spec.launcher;
    try argv.appendSlice(a, &.{ launcher, "--distribution", spec.distro });
    if (spec.user) |user| try argv.appendSlice(a, &.{ "--user", user });
    try argv.appendSlice(a, &.{ "--cd", "/", "--exec" });
    if (spec.session_dir) |dir| try argv.appendSlice(a, &.{ "/usr/bin/env", try std.fmt.allocPrint(a, "HOLLOW_SESSION_DIR={s}", .{dir}) });
    try argv.appendSlice(a, &.{ spec.agent, "session", "wait", "--hold" });
    return argv.toOwnedSlice(a);
}

const fixture_script =
    \\$o=[Console]::OpenStandardOutput();$i=[Console]::OpenStandardInput();
    \\$o.Write([byte[]](82,1,0,0,0),0,5);$o.Flush();$b=New-Object byte[] 5;
    \\while($true){$n=0;while($n -lt 5){$r=$i.Read($b,$n,5-$n);if($r -eq 0){exit 0};$n+=$r};
    \\if($b[0] -eq 80){$o.Write($b,0,5);$o.Flush()}
    \\elseif($b[0] -eq 85){$o.Write([byte[]](70,0,0,0,0),0,5);$o.Flush()}}
;

test "Windows keeper coalesces host pins and fences repin with a generation ACK" {
    const a = std.testing.allocator;
    var registry: Registry = .{ .a = a, .fixture = true };
    defer registry.deinit();
    var buffer: [32 * 1024]u16 = undefined;
    const length = GetSystemDirectoryW(&buffer, buffer.len);
    try std.testing.expect(length > 0 and length < buffer.len);
    const root = try std.unicode.utf16LeToUtf8Alloc(a, buffer[0..length]);
    defer a.free(root);
    const powershell = try std.fs.path.join(a, &.{ root, "WindowsPowerShell", "v1.0", "powershell.exe" });
    defer a.free(powershell);
    const spec: p.WslHold = .{ .distro = "Fixture Distro", .user = "alice", .agent = "/private/agent" };
    const entry = try Entry.create(a, spec, @intCast(io.milliTimestamp()), &.{ powershell, "-NoLogo", "-NoProfile", "-Command", fixture_script });
    registry.entries[0] = entry;
    try awaitReady(&registry, entry);
    const original = entry.child.id.?;
    const borrowed = try registry.acquire(spec, @intCast(io.milliTimestamp()));
    try std.testing.expectEqual(entry, borrowed);
    try std.testing.expectEqual(@as(u8, 2), entry.pins);
    registry.release(entry);
    registry.release(entry);
    registry.tick(@intCast(io.milliTimestamp())); // Start unpin write.
    try std.testing.expect(!entry.ready());
    try std.testing.expectEqual(entry, try registry.acquire(spec, @intCast(io.milliTimestamp())));
    try std.testing.expectEqual(@as(u32, 2), entry.generation);
    try std.testing.expect(!entry.ready()); // Old ready/ACK cannot admit work.
    try awaitReady(&registry, entry);
    try std.testing.expectEqual(original, entry.child.id.?);
    try std.testing.expect(entry.degraded); // F means unknown, not empty/exit.
    try std.testing.expect(registry.hasEntries());
    // Losing a helper after admission is also unknown, not authoritative empty.
    // Repair only the read-only watcher, retaining the registry/borrow identity.
    registry.release(entry);
    try std.testing.expect(TerminateProcess(original, 0).toBool());
    try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(original, 5000));
    const failure_time: u64 = @intCast(io.milliTimestamp());
    registry.tick(failure_time);
    try std.testing.expect(entry.failed);
    try std.testing.expectEqual(entry, registry.entries[0].?);
    registry.tick(failure_time + 1001);
    try std.testing.expect(!entry.failed);
    try std.testing.expectEqual(entry, try registry.acquire(spec, failure_time + 1001));
    try awaitReady(&registry, entry);
    const repaired = entry.child.id.?;
    try std.testing.expect(repaired != original);
    // Retirement must preserve an unknown guest after a helper dies, even
    // though GUI pins have been released. Repair retains drain mode.
    registry.release(entry);
    registry.retire();
    try std.testing.expect(TerminateProcess(repaired, 0).toBool());
    try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(repaired, 5000));
    const drain_failure: u64 = @intCast(io.milliTimestamp());
    registry.tick(drain_failure);
    try std.testing.expect(registry.hasEntries());
    try std.testing.expect(entry.failed);
    registry.tick(drain_failure + 1001);
    try std.testing.expect(!entry.failed);
    try std.testing.expect(entry.draining);
    try std.testing.expectEqual(@as(u8, 0), entry.pins);
    registry.stop();
    try std.testing.expect(entry.failed);
    try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(entry.child.id.?, 5000));
}

test "Windows keeper capacity and pin generation reject before process launch" {
    var fake: Entry = undefined;
    fake.spec = .{ .distro = "held", .agent = "/agent" };
    fake.pins = 1;
    fake.generation = 1;
    fake.failed = false;
    var registry: Registry = .{ .a = std.testing.allocator, .fixture = false, .entries = @splat(&fake) };
    try std.testing.expectError(error.ResourceExhausted, registry.acquire(.{ .distro = "another", .agent = "/agent" }, 0));
    fake.generation = std.math.maxInt(u32);
    try std.testing.expectError(error.ResourceExhausted, registry.acquire(fake.spec, 0));
    fake.generation = 1;
    fake.pins = 16;
    try std.testing.expectError(error.ResourceExhausted, registry.acquire(fake.spec, 0));
    try std.testing.expectError(error.InvalidArgument, registry.acquire(.{ .distro = "held", .agent = "/agent", .session_dir = "/private" }, 0));
}

test "Windows keeper collects only an explicit generation-matching empty control" {
    try collectConfirmed(false);
}

test "Windows keeper retirement drains an idle GUI pin and fences new pins" {
    try collectConfirmed(true);
}

fn collectConfirmed(retiring: bool) !void {
    const a = std.testing.allocator;
    var registry: Registry = .{ .a = a, .fixture = true };
    defer registry.deinit();
    var buffer: [32 * 1024]u16 = undefined;
    const length = GetSystemDirectoryW(&buffer, buffer.len);
    try std.testing.expect(length > 0 and length < buffer.len);
    const root = try std.unicode.utf16LeToUtf8Alloc(a, buffer[0..length]);
    defer a.free(root);
    const powershell = try std.fs.path.join(a, &.{ root, "WindowsPowerShell", "v1.0", "powershell.exe" });
    defer a.free(powershell);
    const body =
        \\$o=[Console]::OpenStandardOutput();$i=[Console]::OpenStandardInput();
        \\$o.Write([byte[]](82,1,0,0,0),0,5);$o.Flush();$b=New-Object byte[] 5;
        \\$n=0;while($n -lt 5){$r=$i.Read($b,$n,5-$n);if($r -eq 0){exit 1};$n+=$r};
        \\if($b[0] -ne $expected){exit 2};$b[0]=69;$o.Write($b,0,5);$o.Flush();
        \\if($expected -eq 68){while($i.ReadByte() -ne -1){}};exit 0
    ;
    const script = try std.fmt.allocPrint(a, "$expected={d};{s}", .{ @as(u8, if (retiring) 'D' else 'U'), body });
    defer a.free(script);
    const entry = try Entry.create(a, .{ .distro = "empty-fixture", .agent = "/private/agent" }, @intCast(io.milliTimestamp()), &.{ powershell, "-NoLogo", "-NoProfile", "-Command", script });
    registry.entries[0] = entry;
    try awaitReady(&registry, entry);
    if (retiring) {
        registry.retire();
        try std.testing.expect(registry.hasEntries());
    } else registry.release(entry);
    const deadline = io.milliTimestamp() + 5000;
    while ((if (retiring) !registry.drained() else registry.hasEntries()) and io.milliTimestamp() < deadline) {
        registry.tick(@intCast(io.milliTimestamp()));
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    if (retiring) {
        try std.testing.expect(registry.drained());
        try std.testing.expectEqual(@as(u8, 1), entry.pins);
        try std.testing.expectError(error.OwnerRetiring, registry.acquire(entry.spec, @intCast(io.milliTimestamp())));
        try std.testing.expect(TerminateProcess(entry.child.id.?, 0).toBool());
        try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(entry.child.id.?, 5000));
        registry.tick(@intCast(io.milliTimestamp()));
        try std.testing.expect(!registry.drained());
        try std.testing.expect(registry.hasEntries());
    } else try std.testing.expect(!registry.hasEntries());
}

test "Windows keeper argv preserves literal distro user and guest fixture path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec: p.WslHold = .{ .distro = "Distro & name", .user = "user's-name", .agent = "/agent dir/hollow-agent", .session_dir = "/private path" };
    try spec.validate(true);
    const argv = try command(arena.allocator(), spec);
    try std.testing.expect(std.fs.path.isAbsolute(argv[0]));
    try std.testing.expectEqualStrings(spec.distro, argv[2]);
    try std.testing.expectEqualStrings(spec.user.?, argv[4]);
    try std.testing.expectEqualStrings("HOLLOW_SESSION_DIR=/private path", argv[9]);
    try std.testing.expectEqualStrings(spec.agent, argv[10]);
    try std.testing.expectEqualStrings("--hold", argv[13]);
}

fn awaitReady(registry: *Registry, entry: *Entry) !void {
    const deadline = io.milliTimestamp() + 10_000;
    while (io.milliTimestamp() < deadline) {
        registry.tick(@intCast(io.milliTimestamp()));
        if (entry.ready()) return;
        if (entry.failed) return error.KeepaliveFailed;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}
