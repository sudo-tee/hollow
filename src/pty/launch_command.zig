pub const LaunchCommand = struct {
    command: []const u8,
    close_on_exit: bool = false,
};
