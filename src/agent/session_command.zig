//! Retain shell-reported foreground commands while clients are detached.
//! Observes HTP events only; never executes queries or replays commands.
const std = @import("std");

pub const Command = struct {
    pub const limit = 8192;
    state: enum { ground, escape, osc, osc_escape, discard, discard_escape } = .ground,
    osc: [limit]u8 = undefined,
    osc_len: usize = 0,
    command: [limit]u8 = undefined,
    command_len: usize = 0,

    pub fn value(self: *const Command) []const u8 {
        return self.command[0..self.command_len];
    }

    pub fn feed(self: *Command, allocator: std.mem.Allocator, bytes: []const u8) void {
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            switch (self.state) {
                .ground => {
                    index = std.mem.indexOfScalarPos(u8, bytes, index, 0x1b) orelse return;
                    self.state = .escape;
                },
                .escape => {
                    if (byte == ']') {
                        self.osc_len = 0;
                        self.state = .osc;
                    } else if (byte != 0x1b) self.state = .ground;
                },
                .osc => switch (byte) {
                    0x07 => self.finish(allocator),
                    0x1b => self.state = .osc_escape,
                    else => {
                        if (self.osc_len == self.osc.len) {
                            self.state = .discard;
                        } else {
                            self.osc[self.osc_len] = byte;
                            self.osc_len += 1;
                        }
                    },
                },
                .osc_escape => {
                    if (byte == '\\') self.finish(allocator) else {
                        self.state = if (byte == 0x1b) .escape else .ground;
                    }
                },
                .discard => switch (byte) {
                    0x07 => self.state = .ground,
                    0x1b => self.state = .discard_escape,
                    else => {},
                },
                .discard_escape => {
                    self.state = if (byte == '\\') .ground else if (byte == 0x1b) .discard_escape else .discard;
                },
            }
        }
    }

    fn finish(self: *Command, allocator: std.mem.Allocator) void {
        self.state = .ground;
        const prefix = "1337;Hollow;";
        const bytes = self.osc[0..self.osc_len];
        if (!std.mem.startsWith(u8, bytes, prefix)) return;
        const Event = struct {
            kind: []const u8,
            name: []const u8,
            payload: struct { command: ?[]const u8 = null } = .{},
        };
        const parsed = std.json.parseFromSlice(Event, allocator, bytes[prefix.len..], .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const event = parsed.value;
        if (!std.mem.eql(u8, event.kind, "event")) return;
        if (std.mem.eql(u8, event.name, "command_started")) {
            const command = event.payload.command orelse return;
            @memcpy(self.command[0..command.len], command);
            self.command_len = command.len;
        } else if (std.mem.eql(u8, event.name, "command_ended") or std.mem.eql(u8, event.name, "prompt_ready")) {
            self.command_len = 0;
        }
    }
};

test "shell command survives chunk boundaries and clears at completion" {
    var command: Command = .{};
    const start = "\x1b]1337;Hollow;{\"kind\":\"event\",\"name\":\"command_started\",\"payload\":{\"command\":\"nvim\",\"cwd\":\"/repo\"}}\x1b\\";
    for (start) |byte| command.feed(std.testing.allocator, &.{byte});
    try std.testing.expectEqualStrings("nvim", command.value());
    command.feed(std.testing.allocator, "\x1b]1337;Hollow;{\"kind\":\"event\",\"name\":\"command_ended\",\"payload\":{\"exit_code\":0}}\x07");
    try std.testing.expectEqualStrings("", command.value());
}

test "oversized and unrelated OSC cannot replace foreground command" {
    var command: Command = .{};
    command.feed(std.testing.allocator, "\x1b]1337;Hollow;");
    command.feed(std.testing.allocator, &(@as([Command.limit + 1]u8, @splat('x'))));
    command.feed(std.testing.allocator, "\x1b\\\x1b]2;title\x07");
    try std.testing.expectEqualStrings("", command.value());
    command.feed(std.testing.allocator, "\x1b]1337;Hollow;{\"kind\":\"event\",\"name\":\"command_started\",\"payload\":{\"command\":\"nvim\"}}\x07");
    try std.testing.expectEqualStrings("nvim", command.value());
    command.feed(std.testing.allocator, "\x1b]1337;Hollow;{\"kind\":\"event\",\"name\":\"prompt_ready\",\"payload\":{}}\x07");
    try std.testing.expectEqualStrings("", command.value());
}
