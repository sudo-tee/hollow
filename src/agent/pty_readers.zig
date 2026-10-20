//! Persistent PTY reader threads for the mux owner. Each attached stream is
//! pinned to one reader, which polls it through its own epoll set and reads
//! straight into a bounded single-producer/single-consumer ring. After a read
//! the reader runs the owner's flush callback, which frames ring bytes onto
//! the transport under its lock, so steady output costs one read and one
//! write with no owner wakeup; the owner only wakes for EOF, detach, or a
//! blocked transport.
//!
//! Bounds: one ring of `ring_size` bytes per attached stream. A reader never
//! reads more than the stream's remaining output credit, and credit plus
//! ringed plus unacknowledged bytes never exceeds the wire window, so a ring
//! cannot overflow. Streams without credit leave their reader's epoll set
//! until the owner grants more.
const std = @import("std");
const p = @import("mux_protocol.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/prctl.h");
});

pub const max_readers = 4;
pub const ring_size = p.window;
const command_key = std.math.maxInt(u64);

comptime {
    std.debug.assert(std.math.isPowerOfTwo(ring_size));
}

/// Stream state shared by its owner and its reader. Fields documented as
/// owner-only or reader-only need no synchronization.
pub const Slot = struct {
    /// Reader owns closing this descriptor while `attached` is set.
    fd: c_int = -1,
    reader: usize = 0,
    ring: ?*[ring_size]u8 = null,
    /// Wire stream ID, set on attach.
    stream_id: u32 = 0,
    /// Producer index (reader writes, consumers read).
    head: std.atomic.Value(u32) = .init(0),
    /// Consumer index, advanced by whichever thread holds the transport lock.
    tail: std.atomic.Value(u32) = .init(0),
    /// Framed bytes not yet credited back by the client.
    uncredited: std.atomic.Value(u32) = .init(0),
    /// Remaining output credit; the owner adds, the reader subtracts.
    credit: std.atomic.Value(u32) = .init(0),
    /// Set by whichever side removed the descriptor from epoll for lack of
    /// credit. Exactly one side re-adds it, whoever clears this flag.
    parked: std.atomic.Value(bool) = .init(false),
    /// Reader observed EOF or a read error and removed the descriptor.
    eof: std.atomic.Value(bool) = .init(false),
    /// Owner requests that the reader close the descriptor and let go.
    detach: std.atomic.Value(bool) = .init(false),
    /// Set by the owner on attach, cleared by the reader once it no longer
    /// touches `fd` or the ring. Flushers check it under the transport lock;
    /// re-attach also takes that lock, so no copy straddles a reuse.
    attached: std.atomic.Value(bool) = .init(false),
    /// Changes on every attach so stale epoll events for a reused slot,
    /// possibly on another reader, are ignored.
    generation: u32 = 0,

    pub fn pending(self: *const Slot) u32 {
        return self.head.load(.acquire) -% self.tail.load(.acquire);
    }
};

pub const Counters = struct {
    reads: u64 = 0,
    read_bytes: u64 = 0,
    read_ns: u64 = 0,
    wakes: u64 = 0,
    parks: u64 = 0,
    owner_wakes: u64 = 0,
};

const Reader = struct {
    set: *Set,
    index: usize,
    thread: ?std.Thread = null,
    epoll_fd: c_int = -1,
    command_fd: c_int = -1,
    streams: std.atomic.Value(usize) = .init(0),
    counters: Counters = .{},
};

pub const Set = struct {
    readers: [max_readers]Reader = undefined,
    count: usize = 0,
    slots: [p.max_streams]Slot = .{Slot{}} ** p.max_streams,
    /// Owner wakeup: written only when the owner announced it is about to
    /// sleep, so a busy owner costs readers no syscalls.
    wake_fd: c_int = -1,
    sleeping: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    focused: std.atomic.Value(u32) = .init(no_focus),
    diagnostics: bool = false,
    /// Run by a reader after it ringed data; returns true when the owner
    /// must wake (blocked or failed transport).
    flush: ?*const fn (ctx: *anyopaque) bool = null,
    flush_ctx: *anyopaque = undefined,
    /// Reader totals, collected after the readers are joined.
    final: Counters = .{},

    pub const no_focus = std.math.maxInt(u32);

    /// Start in place: reader threads retain pointers into this struct.
    pub fn start(self: *Set, count: usize, diagnostics: bool) !void {
        if (count == 0 or count > max_readers) return error.InvalidWorkerCount;
        self.diagnostics = diagnostics;
        self.wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_fd < 0) return error.EventFdFailed;
        errdefer self.deinit();
        for (0..count) |i| {
            const reader = &self.readers[i];
            reader.* = .{ .set = self, .index = i };
            self.count = i + 1;
            reader.epoll_fd = c.epoll_create1(c.EPOLL_CLOEXEC);
            if (reader.epoll_fd < 0) return error.EpollFailed;
            reader.command_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
            if (reader.command_fd < 0) return error.EventFdFailed;
            var event = c.struct_epoll_event{ .events = c.EPOLLIN, .data = .{ .u64 = command_key } };
            if (c.epoll_ctl(reader.epoll_fd, c.EPOLL_CTL_ADD, reader.command_fd, &event) != 0) return error.EpollFailed;
            reader.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, run, .{reader});
        }
    }

    /// Joins every reader, then closes descriptors still held for attached
    /// slots. Returns with no slot attached; rings are freed with `a`.
    pub fn deinit(self: *Set) void {
        self.stopping.store(true, .release);
        for (self.readers[0..self.count]) |*reader| if (reader.command_fd >= 0) notify(reader.command_fd);
        for (self.readers[0..self.count]) |*reader| {
            if (reader.thread) |thread| thread.join();
            reader.thread = null;
            inline for (std.meta.fields(Counters)) |field| @field(self.final, field.name) += @field(reader.counters, field.name);
            if (reader.epoll_fd >= 0) _ = c.close(reader.epoll_fd);
            if (reader.command_fd >= 0) _ = c.close(reader.command_fd);
        }
        for (&self.slots) |*slot| if (slot.attached.raw) {
            if (slot.fd >= 0) _ = c.close(slot.fd);
            slot.fd = -1;
            slot.attached.raw = false;
        };
        if (self.wake_fd >= 0) _ = c.close(self.wake_fd);
        self.wake_fd = -1;
        self.count = 0;
    }

    pub fn freeRings(self: *Set, a: std.mem.Allocator) void {
        for (&self.slots) |*slot| if (slot.ring) |ring| {
            std.debug.assert(!slot.attached.raw);
            a.destroy(ring);
            slot.ring = null;
        };
    }

    /// Hand `fd` to the least loaded reader with `credit` bytes of output
    /// credit. On success the reader owns closing `fd`.
    pub fn attach(self: *Set, a: std.mem.Allocator, index: usize, id: u32, fd: c_int, credit: u32) !void {
        const slot = &self.slots[index];
        std.debug.assert(!slot.attached.raw and credit <= p.window);
        if (slot.ring == null) slot.ring = try a.create([ring_size]u8);
        var reader: usize = 0;
        for (self.readers[0..self.count], 0..) |*entry, i| {
            if (entry.streams.load(.monotonic) < self.readers[reader].streams.load(.monotonic)) reader = i;
        }
        slot.fd = fd;
        slot.stream_id = id;
        slot.uncredited.raw = 0;
        slot.reader = reader;
        slot.generation +%= 1;
        slot.head.raw = 0;
        slot.tail.raw = 0;
        slot.credit.raw = credit;
        slot.parked.raw = credit == 0;
        slot.eof.raw = false;
        slot.detach.raw = false;
        slot.attached.store(true, .release);
        if (credit > 0) {
            var event = c.struct_epoll_event{ .events = c.EPOLLIN, .data = .{ .u64 = key(index, slot.generation) } };
            if (c.epoll_ctl(self.readers[reader].epoll_fd, c.EPOLL_CTL_ADD, fd, &event) != 0) {
                slot.attached.store(false, .release);
                slot.fd = -1;
                return error.EpollFailed;
            }
        }
        _ = self.readers[reader].streams.fetchAdd(1, .monotonic);
    }

    /// Owner: return output credit, waking a parked stream.
    pub fn grant(self: *Set, index: usize, amount: u32) !void {
        const slot = &self.slots[index];
        if (slot.credit.load(.acquire) > p.window - amount) return error.InvalidCredit;
        _ = slot.credit.fetchAdd(amount, .seq_cst);
        if (slot.parked.swap(false, .seq_cst)) self.arm(index);
    }

    /// Owner: ask the reader to close the descriptor and release the slot.
    /// Completion is observed through `released`.
    pub fn requestDetach(self: *Set, index: usize) void {
        const slot = &self.slots[index];
        if (!slot.attached.load(.acquire) or slot.detach.raw) return;
        slot.detach.store(true, .release);
        notify(self.readers[slot.reader].command_fd);
    }

    pub fn released(self: *Set, index: usize) bool {
        return !self.slots[index].attached.load(.acquire);
    }

    /// Transport lock holder: consume `count` ring bytes after copying them.
    pub fn consume(self: *Set, index: usize, count: u32) void {
        const slot = &self.slots[index];
        slot.tail.store(slot.tail.raw +% count, .release);
    }

    /// Transport lock holder: contiguous readable ring bytes, at most `limit`.
    pub fn readable(self: *Set, index: usize, limit: usize) []const u8 {
        const slot = &self.slots[index];
        const available = slot.pending();
        const offset = slot.tail.raw % ring_size;
        const count = @min(@min(available, ring_size - offset), limit);
        return slot.ring.?[offset..][0..count];
    }

    /// Owner: announce an imminent sleep. Returns false (and stays awake)
    /// when readers already published work that the owner must handle.
    pub fn prepareSleep(self: *Set) bool {
        self.sleeping.store(true, .seq_cst);
        // Detach acknowledgements wake the owner themselves and readers flush
        // their own data; only unhandled EOF on live slots keeps it awake.
        for (&self.slots) |*slot| {
            if (!slot.attached.load(.seq_cst) or slot.detach.raw) continue;
            if (slot.eof.load(.seq_cst)) {
                self.sleeping.store(false, .seq_cst);
                return false;
            }
        }
        return true;
    }

    pub fn awake(self: *Set) void {
        self.sleeping.store(false, .seq_cst);
    }

    pub fn drainWake(self: *Set) void {
        var value: u64 = undefined;
        while (c.read(self.wake_fd, &value, @sizeOf(u64)) < 0 and c.__errno_location().* == c.EINTR) {}
    }

    fn arm(self: *Set, index: usize) void {
        const slot = &self.slots[index];
        var event = c.struct_epoll_event{ .events = c.EPOLLIN, .data = .{ .u64 = key(index, slot.generation) } };
        _ = c.epoll_ctl(self.readers[slot.reader].epoll_fd, c.EPOLL_CTL_ADD, slot.fd, &event);
    }

    fn wakeOwner(self: *Set, reader: *Reader) void {
        if (!self.sleeping.swap(false, .seq_cst)) return;
        reader.counters.owner_wakes += 1;
        notify(self.wake_fd);
    }
};

fn key(index: usize, generation: u32) u64 {
    return @as(u64, generation) << 32 | index;
}

fn run(reader: *Reader) void {
    _ = c.prctl(c.PR_SET_NAME, @as(c_ulong, @intFromPtr("hollow-pty-read")), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    const set = reader.set;
    var events: [p.max_streams + 1]c.struct_epoll_event = undefined;
    while (!set.stopping.load(.acquire)) {
        const n = c.epoll_wait(reader.epoll_fd, &events, events.len, -1);
        if (n < 0) continue;
        reader.counters.wakes += 1;
        const ready = events[0..@intCast(n)];
        // Serve a ready focused stream first so an echo never waits behind
        // a round of sibling reads on the same reader.
        const focused = set.focused.load(.monotonic);
        var data = false;
        var owner = false;
        for (ready) |*event| {
            if (event.data.u64 == command_key or (event.data.u64 & 0xffff_ffff) != focused) continue;
            switch (readSlot(reader, event.data.u64)) {
                .none => {},
                .data => data = true,
                .owner => owner = true,
            }
            event.data.u64 = command_key - 1;
        }
        for (ready) |event| switch (event.data.u64) {
            command_key => {
                var value: u64 = undefined;
                _ = c.read(reader.command_fd, &value, @sizeOf(u64));
                owner = detachRequested(reader) or owner;
            },
            command_key - 1 => {},
            else => switch (readSlot(reader, event.data.u64)) {
                .none => {},
                .data => data = true,
                .owner => owner = true,
            },
        };
        if (data) {
            if (set.flush) |flush| {
                if (flush(set.flush_ctx)) owner = true;
            } else owner = true;
        }
        if (owner) set.wakeOwner(reader);
    }
}

const Publish = enum { none, data, owner };

/// One nonblocking read per readiness report. Rotating across ready PTYs
/// instead of draining one is measurably cheaper on Linux PTYs.
fn readSlot(reader: *Reader, event_key: u64) Publish {
    const set = reader.set;
    const index: usize = @intCast(event_key & 0xffff_ffff);
    const slot = &set.slots[index];
    // Only this reader can release a slot it owns, so once attachment and
    // generation match, the slot cannot change underneath this read.
    if (!slot.attached.load(.acquire) or slot.reader != reader.index or slot.generation != @as(u32, @intCast(event_key >> 32))) return .none;
    if (slot.detach.load(.acquire) or slot.eof.raw or slot.parked.load(.acquire)) return .none;
    const credit = slot.credit.load(.acquire);
    if (credit == 0) {
        park(reader, index);
        return .none;
    }
    const head = slot.head.raw;
    const offset = head % ring_size;
    const room = @min(credit, ring_size - offset);
    const before = if (set.diagnostics) nowNs() else 0;
    const n = c.read(slot.fd, slot.ring.?[offset..].ptr, room);
    if (set.diagnostics) reader.counters.read_ns += @intCast(nowNs() - before);
    reader.counters.reads += 1;
    if (n > 0) {
        const count: u32 = @intCast(n);
        reader.counters.read_bytes += count;
        // Reserve credit before publishing bytes: another flusher can send
        // them immediately, and the owner may receive their ACK before this
        // reader resumes. Acquiring head must also observe the debit.
        const exhausted = slot.credit.fetchSub(count, .seq_cst) == count;
        slot.head.store(head +% count, .release);
        if (exhausted) park(reader, index);
        return .data;
    }
    const err = c.__errno_location().*;
    if (n < 0 and (err == c.EAGAIN or err == c.EINTR)) return .none;
    _ = c.epoll_ctl(reader.epoll_fd, c.EPOLL_CTL_DEL, slot.fd, null);
    slot.eof.store(true, .seq_cst);
    return .owner;
}

/// Leave epoll while out of credit; level-triggered readiness would spin.
fn park(reader: *Reader, index: usize) void {
    const set = reader.set;
    const slot = &set.slots[index];
    _ = c.epoll_ctl(reader.epoll_fd, c.EPOLL_CTL_DEL, slot.fd, null);
    reader.counters.parks += 1;
    slot.parked.store(true, .seq_cst);
    // A grant racing this park either sees `parked` and re-arms, or added
    // its credit before this load; then this side reclaims the flag.
    if (slot.credit.load(.seq_cst) > 0 and slot.parked.swap(false, .seq_cst)) set.arm(index);
}

fn detachRequested(reader: *Reader) bool {
    const set = reader.set;
    var any = false;
    for (&set.slots) |*slot| {
        if (!slot.attached.load(.acquire) or slot.reader != reader.index or !slot.detach.load(.acquire)) continue;
        _ = c.epoll_ctl(reader.epoll_fd, c.EPOLL_CTL_DEL, slot.fd, null);
        _ = c.close(slot.fd);
        slot.fd = -1;
        _ = reader.streams.fetchSub(1, .monotonic);
        slot.attached.store(false, .seq_cst);
        any = true;
    }
    return any;
}

/// Futex mutex shared by the owner and reader flushers (Linux only).
pub const Mutex = struct {
    /// 0 unlocked, 1 locked, 2 locked with possible waiters.
    state: std.atomic.Value(u32) = .init(0),

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(0, 1, .seq_cst, .seq_cst) == null;
    }

    pub fn lock(self: *Mutex) void {
        if (self.tryLock()) return;
        while (self.state.swap(2, .seq_cst) != 0) {
            _ = std.os.linux.futex_4arg(&self.state.raw, .{ .cmd = .WAIT, .private = true }, 2, null);
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(0, .seq_cst) == 2) {
            _ = std.os.linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
        }
    }
};

fn notify(fd: c_int) void {
    const value: u64 = 1;
    while (c.write(fd, &value, @sizeOf(u64)) < 0 and c.__errno_location().* == c.EINTR) {}
}

fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

test "published reader bytes can be credited concurrently" {
    const Consumer = struct {
        set: *Set,
        completed: std.atomic.Value(u32) = .init(0),
        stop: std.atomic.Value(bool) = .init(false),
        rejected: bool = false,

        fn run(self: *@This()) void {
            const slot = &self.set.slots[0];
            var next: u32 = 1;
            while (!self.stop.load(.acquire)) {
                if (slot.head.load(.acquire) != next) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                // Model another flusher sending the published byte and the
                // owner immediately handling the client's valid ACK.
                self.set.consume(0, 1);
                _ = slot.uncredited.fetchAdd(1, .release);
                self.set.grant(0, 1) catch {
                    self.rejected = true;
                    self.completed.store(next, .release);
                    return;
                };
                _ = slot.uncredited.fetchSub(1, .release);
                self.completed.store(next, .release);
                next += 1;
            }
        }
    };
    var set: Set = .{};
    var reader: Reader = .{ .set = &set, .index = 0 };
    var ring: [ring_size]u8 = undefined;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    set.slots[0].fd = fds[0];
    set.slots[0].ring = &ring;
    set.slots[0].attached.raw = true;
    set.slots[0].credit.raw = p.window;
    var consumer: Consumer = .{ .set = &set };
    const thread = try std.Thread.spawn(.{}, Consumer.run, .{&consumer});
    defer {
        consumer.stop.store(true, .release);
        thread.join();
    }
    for (1..100_001) |n| {
        try std.testing.expectEqual(@as(isize, 1), c.write(fds[1], "x", 1));
        try std.testing.expectEqual(Publish.data, readSlot(&reader, key(0, 0)));
        while (consumer.completed.load(.acquire) != n) std.atomic.spinLoopHint();
        try std.testing.expect(!consumer.rejected);
        try std.testing.expectEqual(p.window, set.slots[0].credit.load(.acquire));
    }
}
