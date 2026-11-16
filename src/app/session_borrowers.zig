//! Session borrower cleanup hook and deferred transaction flush.
//!
//! Terminal replacement swaps out the underlying Ghostty virtual terminal.
//! Native search engines (find, copy mode) borrow references to the old VT
//! and must be deinited immediately before the old VT is destroyed.
//! However, standard close/exit/cancel/clear helpers emit Lua events.
//! To avoid Lua reentrancy during the replacement transaction, beforeReplace
//! only deinits the borrowed native search handles and records pending
//! identity-aware targets (pane pointer, pane ID, session, generation, epoch).
//! Once the frame's pane tick completes, flush() safely runs standard helpers
//! matching the exact captured activations, validating pane existence to
//! prevent stale pointer dereferences, and preserving new/unrelated selections.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;
const ghostty = @import("../term/ghostty.zig");
const terminal_find = @import("terminal_find.zig");
const copy_mode = @import("copy_mode.zig");
const quick_select = @import("quick_select.zig");
const selection_mod = @import("selection.zig");

pub const PendingBorrowers = struct {
    find: ?Find = null,
    copy_mode: ?CopyMode = null,
    quick_select: ?QuickSelect = null,
    selection: ?Selection = null,

    pub const Find = struct {
        pane_id: usize,
        session: usize,
    };

    pub const CopyMode = struct {
        pane: *Pane,
        pane_id: usize,
        epoch: usize,
    };

    pub const QuickSelect = struct {
        pane: *Pane,
        pane_id: usize,
        epoch: usize,
    };

    pub const Selection = struct {
        pane: *Pane,
        pane_id: usize,
        generation: u64,
    };

    pub fn hasAny(self: PendingBorrowers) bool {
        return self.find != null or self.copy_mode != null or self.quick_select != null or self.selection != null;
    }
};

pub const Flags = PendingBorrowers;

/// Invoked synchronously immediately before an existing terminal VT is freed.
/// Must NOT reenter Lua or run high-level close/exit/cancel mutations.
pub fn beforeReplace(node: *Pane) void {
    const app: *App = @ptrCast(@alignCast(node.host_context orelse return));
    var matched = false;

    if (app.find.pane_id) |find_pane_id| {
        if (find_pane_id == node.id) {
            app.find.engine.deinit(app.allocator);
            app.pending_session_borrowers.find = .{
                .pane_id = node.id,
                .session = app.find.session,
            };
            matched = true;
        }
    }

    if (app.copy_mode_pane == node) {
        app.copy_mode_search.deinit(app.allocator);
        app.pending_session_borrowers.copy_mode = .{
            .pane = node,
            .pane_id = node.id,
            .epoch = app.copy_mode_epoch,
        };
        matched = true;
    }

    if (app.quick_select_pane == node) {
        app.pending_session_borrowers.quick_select = .{
            .pane = node,
            .pane_id = node.id,
            .epoch = app.quick_select_epoch,
        };
        matched = true;
    }

    if (app.selection_pane == node) {
        app.pending_session_borrowers.selection = .{
            .pane = node,
            .pane_id = node.id,
            .generation = app.selection_generation,
        };
        matched = true;
    }

    if (matched) {
        node.render_dirty = .full;
        if (app.renderer) |*renderer| renderer.invalidatePaneCache(node);
    }
}

/// Flushes pending borrower teardown deferred by beforeReplace.
/// Called immediately after tickPanes and before search/find/select ticks.
/// Only resets matching activations and validates pane liveness before helpers.
pub fn flush(app: *App) void {
    if (!app.pending_session_borrowers.hasAny()) return;
    const pending = app.pending_session_borrowers;
    app.pending_session_borrowers = .{};

    // 1. Copy mode
    if (pending.copy_mode) |captured| {
        if (app.copy_mode_active and app.copy_mode_epoch == captured.epoch and app.copy_mode_pane == captured.pane) {
            const live_pane = app.findPaneById(captured.pane_id);
            if (live_pane == null or live_pane != captured.pane) {
                app.copy_mode_pane = null;
            }

            // Flush passes clear_selection = true only if selection is the same captured activation
            const clear_selection = if (pending.selection) |sel_cap|
                (app.selection_pane == sel_cap.pane and app.selection_generation == sel_cap.generation)
            else
                false;

            if (clear_selection) {
                const live_sel_pane = app.findPaneById(pending.selection.?.pane_id);
                if (live_sel_pane == null or live_sel_pane != pending.selection.?.pane) {
                    app.selection_pane = null;
                }
            }

            copy_mode.exitCopyModeWithOptions(app, clear_selection);
        }
    }

    // 2. Selection
    if (pending.selection) |captured| {
        if (app.selection_pane == captured.pane and app.selection_generation == captured.generation) {
            const live_pane = app.findPaneById(captured.pane_id);
            if (live_pane == null or live_pane != captured.pane) {
                app.selection_pane = null;
            }
            selection_mod.clearSelection(app);
        }
    }

    // 3. Terminal find
    if (pending.find) |captured| {
        if (app.find.pane_id) |curr_pane_id| {
            if (curr_pane_id == captured.pane_id and app.find.session == captured.session) {
                terminal_find.close(app);
            }
        }
    }

    // 4. Quick select
    if (pending.quick_select) |captured| {
        if (app.quick_select_active and app.quick_select_epoch == captured.epoch and
            app.quick_select_pane == captured.pane)
        {
            const live_pane = app.findPaneById(captured.pane_id);
            if (live_pane == null or live_pane != captured.pane) {
                app.quick_select_pane = null;
            }
            quick_select.cancel(app);
        }
    }
}

test "session borrowers beforeReplace releases real ghostty search handles and deferred flush cleans up" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();

    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);

    var pane = Pane.init(a);
    pane.id = 100;
    pane.host_context = app;

    // Set up find state with real search handle
    app.find.pane_id = 100;
    app.find.session = 1;
    try app.find.engine.setNeedle(a, terminal, "find_me");
    try std.testing.expect(app.find.engine.handle != null);

    // Set up copy mode with real search handle
    app.copy_mode_pane = &pane;
    app.copy_mode_active = true;
    app.copy_mode_epoch = 1;
    try app.copy_mode_search.setNeedle(a, terminal, "copy_me");
    try std.testing.expect(app.copy_mode_search.handle != null);

    // Set up quick select
    app.quick_select_pane = &pane;
    app.quick_select_active = true;
    app.quick_select_epoch = 1;

    // Set up selection
    app.selection_pane = &pane;
    app.selection_generation = 42;

    // Execute hook
    beforeReplace(&pane);

    // Verify search handles released immediately before old VT freed
    try std.testing.expect(app.find.engine.handle == null);
    try std.testing.expect(app.copy_mode_search.handle == null);

    // Verify pending captured identities
    try std.testing.expect(app.pending_session_borrowers.hasAny());
    try std.testing.expectEqual(@as(usize, 100), app.pending_session_borrowers.find.?.pane_id);
    try std.testing.expectEqual(@as(usize, 1), app.pending_session_borrowers.find.?.session);
    try std.testing.expectEqual(&pane, app.pending_session_borrowers.copy_mode.?.pane);
    try std.testing.expectEqual(@as(usize, 100), app.pending_session_borrowers.copy_mode.?.pane_id);
    try std.testing.expectEqual(@as(usize, 1), app.pending_session_borrowers.copy_mode.?.epoch);
    try std.testing.expectEqual(&pane, app.pending_session_borrowers.quick_select.?.pane);
    try std.testing.expectEqual(@as(usize, 100), app.pending_session_borrowers.quick_select.?.pane_id);
    try std.testing.expectEqual(@as(usize, 1), app.pending_session_borrowers.quick_select.?.epoch);
    try std.testing.expectEqual(&pane, app.pending_session_borrowers.selection.?.pane);
    try std.testing.expectEqual(@as(usize, 100), app.pending_session_borrowers.selection.?.pane_id);
    try std.testing.expectEqual(@as(u64, 42), app.pending_session_borrowers.selection.?.generation);

    // Verify render_dirty set
    try std.testing.expectEqual(ghostty.RenderStateDirty.full, pane.render_dirty);

    // Verify that App states were NOT cleared prematurely in the hook (no Lua reentrancy)
    try std.testing.expectEqual(@as(?usize, 100), app.find.pane_id);
    try std.testing.expectEqual(&pane, app.copy_mode_pane);
    try std.testing.expectEqual(&pane, app.quick_select_pane);
    try std.testing.expectEqual(&pane, app.selection_pane);

    // Flush deferred teardown
    flush(app);

    // Flags must be cleared
    try std.testing.expect(!app.pending_session_borrowers.hasAny());

    // Standard helpers must have cleaned up
    try std.testing.expect(app.find.pane_id == null);
    try std.testing.expect(!app.copy_mode_active);
    try std.testing.expect(app.copy_mode_pane == null);
    try std.testing.expect(!app.quick_select_active);
    try std.testing.expect(app.quick_select_pane == null);
    try std.testing.expect(app.selection_pane == null);
}

test "session borrowers flush does not clobber new find or selection opened after beforeReplace" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();

    var pane1 = Pane.init(a);
    pane1.id = 100;
    pane1.host_context = app;

    var pane2 = Pane.init(a);
    pane2.id = 200;
    pane2.host_context = app;

    // Pane 1 initial states
    app.find.pane_id = 100;
    app.find.session = 1;
    app.copy_mode_pane = &pane1;
    app.copy_mode_active = true;
    app.copy_mode_epoch = 1;
    app.selection_pane = &pane1;
    app.selection_generation = 10;

    beforeReplace(&pane1);

    // Simulate synchronous Lua action opening new find & selection on pane 2 before flush
    app.find.pane_id = 200;
    app.find.session = 2;

    app.selection_pane = &pane2;
    app.selection_generation = 11;

    // Flush should tear down pane 1 copy mode without clobbering new find/selection on pane 2
    flush(app);

    try std.testing.expect(!app.copy_mode_active);
    try std.testing.expectEqual(@as(?usize, 200), app.find.pane_id);
    try std.testing.expectEqual(@as(usize, 2), app.find.session);
    try std.testing.expectEqual(&pane2, app.selection_pane);
    try std.testing.expectEqual(@as(u64, 11), app.selection_generation);
}

test "session borrowers flush safely handles freed heap-pane" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();

    const pane = try a.create(Pane);
    pane.* = Pane.init(a);
    pane.id = 100;
    pane.host_context = app;

    app.find.pane_id = 100;
    app.find.session = 1;
    app.copy_mode_pane = pane;
    app.copy_mode_active = true;
    app.copy_mode_epoch = 1;
    app.quick_select_pane = pane;
    app.quick_select_active = true;
    app.quick_select_epoch = 1;
    app.selection_pane = pane;
    app.selection_generation = 5;

    beforeReplace(pane);

    // Destroy the pane from heap so the pointers on app point to freed memory
    a.destroy(pane);

    // Pane 100 is now dead, app.findPaneById(100) returns null
    try std.testing.expect(app.findPaneById(100) == null);

    // Flush must safely clear state without dereferencing the freed pane pointer
    flush(app);

    try std.testing.expect(!app.pending_session_borrowers.hasAny());
    try std.testing.expect(app.find.pane_id == null);
    try std.testing.expect(!app.copy_mode_active);
    try std.testing.expect(app.copy_mode_pane == null);
    try std.testing.expect(!app.quick_select_active);
    try std.testing.expect(app.quick_select_pane == null);
    try std.testing.expect(app.selection_pane == null);
}

test "session borrowers beforeReplace ignores non-matching pane" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();

    var target_pane = Pane.init(a);
    target_pane.id = 100;
    target_pane.host_context = app;

    var other_pane = Pane.init(a);
    other_pane.id = 200;
    other_pane.host_context = app;

    app.find.pane_id = 100;
    app.copy_mode_pane = &target_pane;
    app.quick_select_pane = &target_pane;
    app.selection_pane = &target_pane;

    beforeReplace(&other_pane);

    try std.testing.expect(!app.pending_session_borrowers.hasAny());
    try std.testing.expect(other_pane.render_dirty != .full);
    try std.testing.expectEqual(@as(?usize, 100), app.find.pane_id);
    try std.testing.expectEqual(&target_pane, app.copy_mode_pane);
    try std.testing.expectEqual(&target_pane, app.quick_select_pane);
    try std.testing.expectEqual(&target_pane, app.selection_pane);
}
