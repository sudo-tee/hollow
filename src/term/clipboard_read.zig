const std = @import("std");
const ghostty = @import("ghostty.zig");

pub const max_bytes = 48 * 1024;
pub const lifetime_ns = 30 * std.time.ns_per_s;
const text_mime = ghostty.String{ .ptr = "text/plain", .len = "text/plain".len };

/// One-shot approval shares a bounded snapshot, never a future clipboard value.
/// Stored inside TerminalPane, not in Ghostty's password/session grant table.
pub const State = struct {
    text: ?[]u8 = null,
    expires_ns: i128 = 0,
    last_notice_ns: ?i128 = null,
    prompt_pending: bool = false,
    prompt_outstanding: bool = false,
    prompt_generation: usize = 0,

    pub fn revoke(self: *State, allocator: std.mem.Allocator) void {
        if (self.text) |text| {
            std.crypto.secureZero(u8, text);
            allocator.free(text);
        }
        self.text = null;
        self.expires_ns = 0;
        self.prompt_pending = false;
        self.prompt_outstanding = false;
        self.prompt_generation +%= 1;
    }

    pub fn approve(self: *State, allocator: std.mem.Allocator, text: []const u8, now_ns: i128) !void {
        self.revoke(allocator);
        if (text.len > max_bytes) return error.ClipboardTooLarge;
        self.text = try allocator.dupe(u8, text);
        self.expires_ns = now_ns + lifetime_ns;
    }

    pub fn expire(self: *State, allocator: std.mem.Allocator, now_ns: i128) void {
        if (self.text != null and now_ns >= self.expires_ns) self.revoke(allocator);
    }

    /// Replies before returning. False means no clipboard data was disclosed.
    /// Native `granted` flags are intentionally not blanket OS-clipboard grants.
    pub fn reply(self: *State, allocator: std.mem.Allocator, request: *const ghostty.ClipboardRead, now_ns: i128, focused: bool) bool {
        if (request.size < @sizeOf(ghostty.ClipboardRead)) return false;
        self.expire(allocator, now_ns);
        if (!focused) self.revoke(allocator);
        var response: ghostty.ClipboardReadReply = .{ .result = 1 };
        // Sokol only exposes the ordinary text clipboard, not primary selection.
        if (request.location != 0) {
            response.result = 2;
            request.reply(request, &response);
            return false;
        }
        const available = [_]ghostty.String{text_mime};
        if (request.list) {
            response.available = &available;
            response.available_len = available.len;
        }
        // A static text-target listing discloses no clipboard data and must not
        // consume the one-shot permission for the subsequent data request.
        if (request.list and request.mimes_len == 0) {
            response.result = 0;
            request.reply(request, &response);
            return true;
        }
        const text = self.text orelse {
            request.reply(request, &response);
            return false;
        };
        defer self.revoke(allocator);
        var supported = false;
        if (request.mimes) |mimes| {
            if (request.mimes_len <= 64) {
                for (mimes[0..request.mimes_len]) |mime| {
                    if (std.mem.eql(u8, mime.slice(), "text/plain")) supported = true;
                }
            }
        }
        if (!supported) {
            response.result = 2;
            request.reply(request, &response);
            return false;
        }
        const contents = [_]ghostty.ClipboardContent{.{ .mime = text_mime, .data = .{ .ptr = text.ptr, .len = text.len } }};
        response.result = 0;
        response.contents = &contents;
        response.contents_len = contents.len;
        request.reply(request, &response);
        return true;
    }

    pub fn shouldNotify(self: *State, now_ns: i128) bool {
        if (self.last_notice_ns) |last| if (now_ns - last < 5 * std.time.ns_per_s) return false;
        self.last_notice_ns = now_ns;
        return true;
    }

    pub fn requestPrompt(self: *State, request: *const ghostty.ClipboardRead, now_ns: i128) void {
        if (self.prompt_outstanding or request.size < @sizeOf(ghostty.ClipboardRead) or request.location != 0 or
            request.mimes_len == 0 or request.mimes_len > 64) return;
        const mimes = request.mimes orelse return;
        var supported = false;
        for (mimes[0..request.mimes_len]) |mime| {
            if (std.mem.eql(u8, mime.slice(), "text/plain")) supported = true;
        }
        if (!supported or !self.shouldNotify(now_ns)) return;
        self.prompt_generation +%= 1;
        self.prompt_pending = true;
        self.prompt_outstanding = true;
    }

    /// Only value metadata leaves the parser callback; never the request itself.
    pub fn takePrompt(self: *State) ?usize {
        if (!self.prompt_pending) return null;
        self.prompt_pending = false;
        return self.prompt_generation;
    }

    pub fn matchesPrompt(self: *const State, generation: usize) bool {
        return self.prompt_outstanding and self.prompt_generation == generation;
    }
};

test "clipboard read approval is bounded one-shot and expires" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.revoke(allocator);
    try state.approve(allocator, "secret", 100);
    try std.testing.expectEqualStrings("secret", state.text.?);
    state.expire(allocator, 100 + lifetime_ns);
    try std.testing.expect(state.text == null);
    try state.approve(allocator, "", 200);
    try std.testing.expect(state.text != null);
    state.revoke(allocator);
    const oversized = try allocator.alloc(u8, max_bytes + 1);
    defer allocator.free(oversized);
    try std.testing.expectError(error.ClipboardTooLarge, state.approve(allocator, oversized, 0));
    try std.testing.expect(state.text == null);
}

const Recorder = struct {
    result: c_int = -1,
    bytes: [128]u8 = @splat(0),
    len: usize = 0,
    available: usize = 0,
    remember: bool = true,

    fn reply(req: *const ghostty.ClipboardRead, response: *const ghostty.ClipboardReadReply) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(@constCast(req.ctx.?)));
        self.result = response.result;
        self.available = response.available_len;
        self.remember = response.remember;
        self.len = 0;
        if (response.contents) |contents| {
            if (response.contents_len > 0) {
                const data = contents[0].data.slice();
                self.len = @min(data.len, self.bytes.len);
                @memcpy(self.bytes[0..self.len], data[0..self.len]);
            }
        }
    }

    fn request(self: *Recorder) ghostty.ClipboardRead {
        return .{
            .size = @sizeOf(ghostty.ClipboardRead),
            .location = 0,
            .mimes = @ptrCast(&text_mime),
            .mimes_len = 1,
            .list = false,
            .name = .{ .ptr = null, .len = 0 },
            .granted = false,
            .can_remember = true,
            .ctx = self,
            .reply = reply,
        };
    }
};

test "clipboard read denies by default and consumes only an explicit one-shot snapshot" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.revoke(allocator);
    var record: Recorder = .{};
    var request = record.request();
    request.granted = true; // Never trust a generic grant as OS clipboard access.
    try std.testing.expect(!state.reply(allocator, &request, 10, true));
    try std.testing.expectEqual(@as(c_int, 1), record.result);
    try std.testing.expectEqual(@as(usize, 0), record.len);
    try state.approve(allocator, "secret", 20);
    try std.testing.expect(state.reply(allocator, &request, 21, true));
    try std.testing.expectEqualStrings("secret", record.bytes[0..record.len]);
    try std.testing.expect(!record.remember and state.text == null);
    try std.testing.expect(!state.reply(allocator, &request, 22, true));
    try std.testing.expectEqual(@as(c_int, 1), record.result);
    try state.approve(allocator, "secret", 30);
    try std.testing.expect(!state.reply(allocator, &request, 31, false));
    try std.testing.expect(state.text == null);
    try state.approve(allocator, "secret", 40);
    try std.testing.expect(!state.reply(allocator, &request, 40 + lifetime_ns, true));
    try std.testing.expectEqual(@as(usize, 0), record.len);
}

test "clipboard read listing preserves approval and unsupported MIME cannot expose text" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.revoke(allocator);
    var record: Recorder = .{};
    var request = record.request();
    try state.approve(allocator, "secret", 0);
    request.list = true;
    request.mimes_len = 0;
    try std.testing.expect(state.reply(allocator, &request, 1, true));
    try std.testing.expectEqual(@as(usize, 1), record.available);
    try std.testing.expectEqual(@as(usize, 0), record.len);
    try std.testing.expect(state.text != null);
    const mime = ghostty.String{ .ptr = "image/png", .len = "image/png".len };
    request.mimes = @ptrCast(&mime);
    request.mimes_len = 1;
    try std.testing.expect(!state.reply(allocator, &request, 2, true));
    try std.testing.expectEqual(@as(c_int, 2), record.result);
    try std.testing.expect(state.text == null and record.len == 0);
}

test "clipboard prompts are coalesced throttled and invalidated on revoke" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.revoke(allocator);
    var record: Recorder = .{};
    var request = record.request();
    state.requestPrompt(&request, 0);
    const first = state.takePrompt().?;
    try std.testing.expect(state.matchesPrompt(first));
    try std.testing.expect(state.text == null and record.result == -1);
    try std.testing.expect(state.takePrompt() == null);
    // Even after the cooldown, an outstanding dialog cannot be replaced.
    state.requestPrompt(&request, 10 * std.time.ns_per_s);
    try std.testing.expect(state.takePrompt() == null);
    state.revoke(allocator);
    try std.testing.expect(!state.matchesPrompt(first));
    state.requestPrompt(&request, 1 * std.time.ns_per_s);
    try std.testing.expect(state.takePrompt() == null);
    state.requestPrompt(&request, 5 * std.time.ns_per_s);
    const second = state.takePrompt().?;
    try std.testing.expect(first != second and state.matchesPrompt(second));
    state.revoke(allocator); // Focus loss/reset/reload must drop pending events.
    try std.testing.expect(state.takePrompt() == null);
    request.location = 1;
    state.requestPrompt(&request, 20 * std.time.ns_per_s);
    try std.testing.expect(state.takePrompt() == null);
    request.location = 0;
    request.mimes_len = 0;
    state.requestPrompt(&request, 20 * std.time.ns_per_s);
    try std.testing.expect(state.takePrompt() == null);
}
