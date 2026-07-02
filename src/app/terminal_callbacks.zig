const std = @import("std");
const ghostty = @import("../term/ghostty.zig");
const Pane = @import("../pane.zig").Pane;
const Mux = @import("../mux.zig").Mux;
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub var write_bridge: ?*App = null;
pub var size_bridge: ?*App = null;
pub var attrs_bridge: ?*App = null;
pub var title_bridge: ?*App = null;
pub var bell_bridge: ?*App = null;

pub fn terminalCallbacks() ghostty.TerminalCallbacks {
    return .{
        .write_pty = writePtyCallback,
        .bell = bellCallback,
        .enquiry = enquiryCallback,
        .xtversion = xtversionCallback,
        .size = sizeCallback,
        .color_scheme = colorSchemeCallback,
        .device_attributes = deviceAttributesCallback,
        .title_changed = titleChangedCallback,
    };
}

fn getPaneForTerminal(app: *App, term: ?*anyopaque) ?*Pane {
    if (app.mux) |*mux| {
        var panes = mux.paneIterator();
        while (panes.next()) |pane| {
            if (pane.terminal == term) return pane;
        }
    }
    return null;
}

fn writePtyCallback(term: ?*anyopaque, _: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) void {
    if (bytes == null or len == 0) return;
    const bytes_ptr = bytes.?;
    const app = write_bridge orelse return;
    const pane = getPaneForTerminal(app, term) orelse return;
    pane.sendText(bytes_ptr[0..len]);
}

fn bellCallback(term: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const app = bell_bridge orelse return;
    if (getPaneForTerminal(app, term)) |pane| {
        // Mirror the title_changed pattern: just flag a dirty bit; the frame
        // thread drains it inside tickPanes(). Avoids touching Lua state or
        // any rendering data from ghostty's parser thread.
        pane.bell_dirty = true;
    }
}

fn enquiryCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    return .{ .ptr = null, .len = 0 };
}

fn xtversionCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
    // Report "ghostty" so that apps like nvim detect Ghostty via XTVERSION
    // and enable the Kitty keyboard protocol. The real Ghostty terminal reports
    // "ghostty <version>"; we omit the version since hollow doesn't track it.
    const version = "ghostty";
    return .{ .ptr = version.ptr, .len = version.len };
}

fn sizeCallback(term: ?*anyopaque, _: ?*anyopaque, out: ?*ghostty.SizeReportSize) callconv(.c) bool {
    if (out == null) return false;
    const out_ptr = out.?;
    const app = size_bridge orelse return false;
    // Report the actual per-pane terminal dimensions rather than the global
    // config values, so each split pane reports its own correct size.
    if (getPaneForTerminal(app, term)) |pane| {
        out_ptr.rows = if (pane.rows > 0) pane.rows else app.config.rows;
        out_ptr.columns = if (pane.cols > 0) pane.cols else app.config.cols;
        out_ptr.cell_width = app.cell_width_px;
        out_ptr.cell_height = app.cell_height_px;
        return true;
    }
    out_ptr.rows = app.config.rows;
    out_ptr.columns = app.config.cols;
    out_ptr.cell_width = app.cell_width_px;
    out_ptr.cell_height = app.cell_height_px;
    return true;
}

fn colorSchemeCallback(_: ?*anyopaque, _: ?*anyopaque, _: ?*ghostty.ColorScheme) callconv(.c) bool {
    return false;
}

fn deviceAttributesCallback(_: ?*anyopaque, _: ?*anyopaque, out: ?*ghostty.DeviceAttributes) callconv(.c) bool {
    if (out == null) return false;
    const out_ptr = out.?;
    const app = attrs_bridge orelse return false;
    _ = app;
    out_ptr.primary.conformance_level = 1;
    out_ptr.primary.features = [_]u16{ 1, 2, 22 } ++ ([_]u16{0} ** 61);
    out_ptr.primary.num_features = 3;
    out_ptr.secondary.device_type = 1;
    out_ptr.secondary.firmware_version = 1;
    out_ptr.secondary.rom_cartridge = 0;
    out_ptr.tertiary.unit_id = 0;
    return true;
}

fn titleChangedCallback(term: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const app = title_bridge orelse return;
    _ = app;
    if (getPaneForTerminal(title_bridge orelse return, term)) |pane| {
        if (pane.title_is_manual) return;
        pane.title_dirty = true;
    }
}
