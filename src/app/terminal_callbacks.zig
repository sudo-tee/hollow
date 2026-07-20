const std = @import("std");
const ghostty = @import("../term/ghostty.zig");
const Pane = @import("../pane.zig").Pane;
const app_mod = @import("../app.zig");
const App = app_mod.App;

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

fn paneFromUserdata(userdata: ?*anyopaque) ?*Pane {
    return @ptrCast(@alignCast(userdata orelse return null));
}

fn writePtyCallback(_: ?*anyopaque, userdata: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) void {
    if (bytes == null or len == 0) return;
    const bytes_ptr = bytes.?;
    const pane = paneFromUserdata(userdata) orelse return;
    pane.sendText(bytes_ptr[0..len]);
}

fn bellCallback(_: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    if (paneFromUserdata(userdata)) |pane| {
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

fn sizeCallback(_: ?*anyopaque, userdata: ?*anyopaque, out: ?*ghostty.SizeReportSize) callconv(.c) bool {
    if (out == null) return false;
    const out_ptr = out.?;
    const pane = paneFromUserdata(userdata) orelse return false;
    const app: *App = @ptrCast(@alignCast(pane.host_context orelse return false));
    // Report the actual per-pane terminal dimensions rather than the global
    // config values, so each split pane reports its own correct size.
    out_ptr.rows = if (pane.rows > 0) pane.rows else app.config.rows;
    out_ptr.columns = if (pane.cols > 0) pane.cols else app.config.cols;
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
    out_ptr.primary.conformance_level = 1;
    out_ptr.primary.features = [_]u16{ 1, 2, 22 } ++ ([_]u16{0} ** 61);
    out_ptr.primary.num_features = 3;
    out_ptr.secondary.device_type = 1;
    out_ptr.secondary.firmware_version = 1;
    out_ptr.secondary.rom_cartridge = 0;
    out_ptr.tertiary.unit_id = 0;
    return true;
}

fn titleChangedCallback(_: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    if (paneFromUserdata(userdata)) |pane| {
        if (pane.title_is_manual) return;
        pane.title_dirty = true;
    }
}
