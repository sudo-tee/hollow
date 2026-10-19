//! Thin, GUI-independent host runtime. Workspace and discovery policy stay Lua.
pub const Manager = @import("host/manager.zig").Manager;
pub const Handle = @import("host/manager.zig").Handle;
pub const Ticket = @import("host/manager.zig").Ticket;
pub const max_hosts = @import("host/manager.zig").max_hosts;
pub const operations = @import("host/operations.zig");
pub const transport = @import("host/transport.zig");
pub const deploy = @import("host/deploy.zig");

test {
    _ = @import("host/manager.zig");
    _ = operations;
    _ = deploy;
}
