//! Headless command contracts, CLI parsing, and real command-socket tests.
const std = @import("std");

test {
    _ = @import("command.zig");
    _ = @import("ipc.zig");
    _ = @import("automation_events.zig");
    std.testing.refAllDecls(@import("native_cli.zig"));
}
