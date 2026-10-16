const std = @import("std");
const ghostty = @import("../term/ghostty.zig");
const Pane = @import("../pane.zig").Pane;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = @import("sokol_c");

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
        .render_hold = renderHoldCallback,
        .pwd_changed = pwdChangedCallback,
        .clipboard_write = clipboardWriteCallback,
        .program_status = programStatusCallback,
        .semantic_prompt = semanticPromptCallback,
        .reset = resetCallback,
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
        pane.bell_flash_color = null;
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

fn colorSchemeCallback(_: ?*anyopaque, userdata: ?*anyopaque, out: ?*ghostty.ColorScheme) callconv(.c) bool {
    const out_ptr = out orelse return false;
    const pane = paneFromUserdata(userdata) orelse return false;
    const app: *App = @ptrCast(@alignCast(pane.host_context orelse return false));
    out_ptr.* = colorSchemeForBackground(app.config.terminal_theme.background);
    return true;
}

fn colorSchemeForBackground(background: ghostty.ColorRgb) ghostty.ColorScheme {
    const brightness: u32 = @as(u32, background.r) * 299 +
        @as(u32, background.g) * 587 +
        @as(u32, background.b) * 114;
    return if (brightness > 128_000) .light else .dark;
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

fn renderHoldCallback(terminal: ?*anyopaque, userdata: ?*anyopaque, held: bool) callconv(.c) void {
    const pane = paneFromUserdata(userdata) orelse return;
    if (!pane.synchronized_output_enabled) return;
    if (held) {
        const runtime = pane.terminal_runtime orelse return;
        if (pane.render_state) |state| {
            // Runs at the exact stream boundary, before any held bytes.
            runtime.updateRenderState(state, terminal) catch return;
            pane.render_state_fresh = true;
            pane.render_dirty = .full;
        }
        pane.synchronized_output_started_ns = @import("../io.zig").nanoTimestamp();
    } else {
        pane.synchronized_output_started_ns = 0;
        pane.render_dirty = .full;
        pane.render_state_fresh = false;
    }
    pane.synchronized_output_active = held;
}

fn programStatusCallback(_: ?*anyopaque, userdata: ?*anyopaque, report: *const ghostty.ProgramStatus) callconv(.c) void {
    const pane = paneFromUserdata(userdata) orelse return;
    pane.program_status.apply(pane.allocator, report) catch |err| {
        std.log.warn("program status rejected: {s}", .{@errorName(err)});
    };
}

fn semanticPromptCallback(_: ?*anyopaque, userdata: ?*anyopaque, event: *const ghostty.SemanticPrompt) callconv(.c) void {
    const pane = paneFromUserdata(userdata) orelse return;
    // Only a primary prompt ends a command, not RPROMPT/continuations.
    if (event.kind == 1 and event.prompt_kind == 0) pane.program_status.endCommand(pane.allocator);
}

fn resetCallback(terminal: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    const pane = paneFromUserdata(userdata) orelse return;
    pane.title_dirty = !pane.title_is_manual;
    pwdChangedCallback(terminal, userdata);
}

fn pwdChangedCallback(terminal: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    const pane = paneFromUserdata(userdata) orelse return;
    const runtime = pane.terminal_runtime orelse return;
    var pwd: ghostty.String = .{ .ptr = null, .len = 0 };
    if (runtime.terminal_get(terminal, @intFromEnum(ghostty.TerminalData.pwd), &pwd) != ghostty.success) return;
    var path = pwd.slice();
    if (std.mem.startsWith(u8, path, "cwd;")) path = path[4..];
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path[7..];
        if (std.mem.indexOfScalar(u8, path, '/')) |idx| path = path[idx..];
    }
    const owned = pane.allocator.dupe(u8, path) catch return;
    if (pane.pending_cwd) |old| pane.allocator.free(old);
    pane.pending_cwd = owned;
    pane.cwd_dirty = true;
}

fn clipboardWriteCallback(_: ?*anyopaque, userdata: ?*anyopaque, request: *const ghostty.ClipboardWrite) callconv(.c) void {
    const pane = paneFromUserdata(userdata) orelse return;
    // Preserve text-only writes; never install a clipboard-read callback.
    if (request.size < @sizeOf(ghostty.ClipboardWrite)) return;
    const reply: ghostty.ClipboardWriteReply = .{ .result = commitClipboardWrite(pane.allocator, request, struct {
        fn commit(text: [:0]const u8) void {
            c.sapp_set_clipboard_string(text);
        }
    }.commit) };
    request.reply(request, &reply);
}

fn commitClipboardWrite(allocator: std.mem.Allocator, request: *const ghostty.ClipboardWrite, commit: *const fn ([:0]const u8) void) c_int {
    if (request.contents_len == 0) {
        commit("");
        return 0;
    }
    const contents = request.contents orelse return 2;
    // Sokol cannot atomically store multiple MIME representations.
    if (request.contents_len != 1 or !std.mem.eql(u8, contents[0].mime.slice(), "text/plain")) return 2;
    const text = contents[0].data.slice();
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    const owned = allocator.dupeZ(u8, text[0..end]) catch return 5;
    defer allocator.free(owned);
    commit(owned);
    return 0;
}

test "color scheme follows configured terminal background" {
    try std.testing.expectEqual(
        ghostty.ColorScheme.dark,
        colorSchemeForBackground(.{ .r = 25, .g = 26, .b = 28 }),
    );
    try std.testing.expectEqual(
        ghostty.ColorScheme.light,
        colorSchemeForBackground(.{ .r = 240, .g = 240, .b = 240 }),
    );
}

test "render hold captures each exact boundary including end and restart in one write" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var pane = Pane.init(std.testing.allocator);
    pane.terminal_runtime = &runtime;
    pane.terminal = try runtime.createTerminal(80, 24, 0);
    defer pane.deinit(&runtime);
    pane.render_state = try runtime.createRenderState();
    runtime.setTerminalUserdata(pane.terminal, &pane);
    runtime.registerCallbacks(pane.terminal, terminalCallbacks());

    runtime.terminalWrite(pane.terminal, "A\x1b[?2026hBBBB");
    try std.testing.expect(pane.synchronized_output_active);
    try std.testing.expectEqual(@as(u16, 1), runtime.cursorPos(pane.render_state).?.x);
    const started = pane.synchronized_output_started_ns;
    runtime.terminalWrite(pane.terminal, "C\x1b[?2026h");
    try std.testing.expectEqual(started, pane.synchronized_output_started_ns);
    runtime.terminalWrite(pane.terminal, "\x1b[?2026lD\x1b[?2026hEEEE");
    try std.testing.expectEqual(@as(u16, 7), runtime.cursorPos(pane.render_state).?.x);
    runtime.resizeTerminal(pane.terminal, 81, 24, 8, 16);
    try std.testing.expect(!pane.synchronized_output_active);
    runtime.terminalWrite(pane.terminal, "\x1b[?2026h");
    const deadline = pane.synchronized_output_started_ns + std.time.ns_per_s;
    try std.testing.expect(!pane.expireRenderHold(&runtime, deadline - 1, std.time.ns_per_s));
    runtime.terminalWrite(pane.terminal, "still busy\x1b[?2026h");
    try std.testing.expect(pane.expireRenderHold(&runtime, deadline, std.time.ns_per_s));
    try std.testing.expect(!runtime.terminalMode(pane.terminal, .synchronized_output));
}

test "semantic prompt and full reset clear the appropriate program status" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var pane = Pane.init(std.testing.allocator);
    pane.terminal_runtime = &runtime;
    pane.terminal = try runtime.createTerminal(80, 24, 0);
    defer pane.deinit(&runtime);
    runtime.setTerminalUserdata(pane.terminal, &pane);
    runtime.registerCallbacks(pane.terminal, terminalCallbacks());

    runtime.terminalWrite(pane.terminal, "\x1b]7501;state=working:app=build\x1b\\");
    runtime.terminalWrite(pane.terminal, "\x1b]7501;state=done:id=tests\x1b\\");
    runtime.terminalWrite(pane.terminal, "\x1b]7501;state=blocked:kind=permission:id=approval\x07");
    runtime.terminalWrite(pane.terminal, "\x1b]7501;state=error:id=failed\x07");
    try std.testing.expectEqual(@as(usize, 4), pane.program_status.records.items.len);
    try std.testing.expectEqualStrings("build", pane.program_status.records.items[0].app);
    runtime.terminalWrite(pane.terminal, "\x1b]133;A\x07");
    try std.testing.expectEqual(@as(usize, 3), pane.program_status.records.items.len);
    try std.testing.expectEqualStrings("blocked", pane.program_status.records.items[1].stateName());
    try std.testing.expectEqualStrings("error", pane.program_status.records.items[2].stateName());
    runtime.terminalWrite(pane.terminal, "\x1bc");
    try std.testing.expectEqual(@as(usize, 0), pane.program_status.records.items.len);
    try std.testing.expect(pane.title_dirty);
    try std.testing.expect(pane.cwd_dirty);
}

test "cwd callbacks handle split, cancelled and legacy OSC 7 without changing old cwd early" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var pane = Pane.init(std.testing.allocator);
    pane.terminal_runtime = &runtime;
    pane.terminal = try runtime.createTerminal(80, 24, 0);
    defer pane.deinit(&runtime);
    runtime.setTerminalUserdata(pane.terminal, &pane);
    runtime.registerCallbacks(pane.terminal, terminalCallbacks());
    pane.setCwd("/old");
    runtime.terminalWrite(pane.terminal, "\x1b]7;file://host/");
    try std.testing.expect(!pane.cwd_dirty);
    runtime.terminalWrite(pane.terminal, "new\x1b\\");
    try std.testing.expectEqualStrings("/old", pane.cwd);
    try std.testing.expect(pane.refreshCwd());
    try std.testing.expectEqualStrings("/new", pane.cwd);
    runtime.terminalWrite(pane.terminal, "\x1b]7;file:///cancelled\x18");
    try std.testing.expect(!pane.cwd_dirty);
    runtime.terminalWrite(pane.terminal, "\x1b]7;cwd;/legacy\x07");
    try std.testing.expect(pane.refreshCwd());
    try std.testing.expectEqualStrings("/legacy", pane.cwd);
}

test "cwd callbacks confirm an unchanged launch cwd for workspace bootstrap" {
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var pane = Pane.init(std.testing.allocator);
    pane.terminal_runtime = &runtime;
    pane.terminal = try runtime.createTerminal(80, 24, 0);
    defer pane.deinit(&runtime);
    runtime.setTerminalUserdata(pane.terminal, &pane);
    runtime.registerCallbacks(pane.terminal, terminalCallbacks());
    pane.setCwd("/project");

    runtime.terminalWrite(pane.terminal, "\x1b]7;file://host/project\x1b\\");
    try std.testing.expect(pane.cwd_dirty);
    try std.testing.expect(pane.refreshCwd());
    try std.testing.expectEqualStrings("/project", pane.cwd);
    try std.testing.expect(!pane.cwd_dirty);
    try std.testing.expect(pane.pending_cwd == null);
    try std.testing.expect(!pane.refreshCwd());
}

test "clipboard writes decode once across chunks, ignore cancellation and never serve reads" {
    const Sink = struct {
        var bytes: [128]u8 = undefined;
        var len: usize = 0;
        var count: usize = 0;
        fn commit(text: [:0]const u8) void {
            @memcpy(bytes[0..text.len], text);
            len = text.len;
            count += 1;
        }
        fn onWrite(_: ?*anyopaque, _: ?*anyopaque, request: *const ghostty.ClipboardWrite) callconv(.c) void {
            const reply: ghostty.ClipboardWriteReply = .{ .result = commitClipboardWrite(std.testing.allocator, request, commit) };
            request.reply(request, &reply);
        }
    };
    Sink.count = 0;
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);
    var callbacks = terminalCallbacks();
    callbacks.clipboard_write = Sink.onWrite;
    runtime.registerCallbacks(terminal, callbacks);
    runtime.terminalWrite(terminal, "\x1b]52;c;aGVs");
    try std.testing.expectEqual(@as(usize, 0), Sink.count);
    runtime.terminalWrite(terminal, "bG8=\x07");
    try std.testing.expectEqualStrings("hello", Sink.bytes[0..Sink.len]);
    try std.testing.expectEqual(@as(usize, 1), Sink.count);
    runtime.terminalWrite(terminal, "\x1b]52;c;YmFk\x18\x1b]52;c;?\x07");
    try std.testing.expectEqual(@as(usize, 1), Sink.count);
}
