//! Keep the owner module rooted in src so platform backends can share runtime helpers.
pub const main = @import("agent/session_main_windows.zig").main;
pub const std_options: @import("std").Options = .{ .log_level = .info, .logFn = @import("agent/diagnostics.zig").stderrLog };
