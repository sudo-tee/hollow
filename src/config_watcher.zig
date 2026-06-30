const std = @import("std");
const nightwatch = @import("nightwatch");

/// OS-native file change watcher for `watch_dirs` trees and individual
/// config files.
///
/// Wraps nightwatch.Default (inotify on Linux, ReadDirectoryChangesW on
/// Windows, kqueue on macOS/BSD). The backend thread calls into `Handler`
/// on every filesystem event; we filter to `.lua` files and set an atomic
/// flag that the main tick drains into a `reload_config` mouse event.
///
/// For individual config files (`base_config_path` / `override_config_path`)
/// we watch the **parent directory** — Windows RDCW cannot watch a single
/// file, only a directory. The `.lua` filter in the handler catches the
/// config file's changes (config files are always `init.lua`).
pub const ConfigWatcher = struct {
    reload_flag: *std.atomic.Value(bool),
    handler: nightwatch.Default.Handler,
    watcher: nightwatch.Default,

    const vtable = nightwatch.Default.Handler.VTable{
        .change = changeCb,
        .rename = renameCb,
    };

    /// `reload_flag` must outlive the watcher. It is set from the backend
    /// thread whenever a `.lua` file under a watched tree changes.
    /// Returns a heap-allocated watcher so the embedded `*Handler` pointer
    /// stays stable for the backend thread.
    pub fn create(allocator: std.mem.Allocator, reload_flag: *std.atomic.Value(bool)) !*ConfigWatcher {
        const self = try allocator.create(ConfigWatcher);
        self.* = .{
            .reload_flag = reload_flag,
            .handler = .{ .vtable = &vtable },
            .watcher = undefined,
        };
        errdefer allocator.destroy(self);
        self.watcher = try nightwatch.Default.init(allocator, &self.handler);
        return self;
    }

    pub fn destroy(self: *ConfigWatcher, allocator: std.mem.Allocator) void {
        self.watcher.deinit();
        allocator.destroy(self);
    }

    /// `path` may be a directory or a file. Relative paths resolve against cwd.
    pub fn watch(self: *ConfigWatcher, path: []const u8) nightwatch.Error!void {
        return self.watcher.watch(path);
    }

    /// Watch an individual file by watching its parent directory.
    /// Used for config files (`init.lua`) since Windows RDCW cannot watch
    /// a single file directly. The `.lua` filter in the handler catches
    /// changes to the target file.
    pub fn watchFile(self: *ConfigWatcher, path: []const u8) nightwatch.Error!void {
        const parent = std.fs.path.dirname(path) orelse return error.WatchFailed;
        return self.watcher.watch(parent);
    }

    fn changeCb(h: *nightwatch.Default.Handler, path: []const u8, _: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *ConfigWatcher = @fieldParentPtr("handler", h);
        if (!std.mem.endsWith(u8, path, ".lua")) return;
        self.reload_flag.store(true, .release);
    }

    fn renameCb(h: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *ConfigWatcher = @fieldParentPtr("handler", h);
        if (std.mem.endsWith(u8, src, ".lua") or std.mem.endsWith(u8, dst, ".lua")) {
            self.reload_flag.store(true, .release);
        }
    }
};
