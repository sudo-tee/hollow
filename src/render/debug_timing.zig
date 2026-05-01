pub var last_frame_pty_read_ms: f32 = 0;
pub var last_frame_terminal_write_ms: f32 = 0;
pub var last_frame_renderstate_ms: f32 = 0;
pub var last_frame_cleanup_ms: f32 = 0;
pub var last_frame_prune_ms: f32 = 0;
pub var last_frame_events_ms: f32 = 0;
pub var last_frame_htp_ms: f32 = 0;
pub var last_frame_resize_ms: f32 = 0;
pub var last_frame_layout_ms: f32 = 0;
pub var last_frame_tick_panes_ms: f32 = 0;
pub var last_frame_title_ms: f32 = 0;
pub var last_frame_cwd_ms: f32 = 0;
pub var last_frame_scrollbar_ms: f32 = 0;
pub var last_frame_has_pending_ms: f32 = 0;
pub var last_frame_sanitize_ms: f32 = 0;
pub var last_frame_child_alive_ms: f32 = 0;
pub var last_frame_encoder_sync_ms: f32 = 0;
pub var last_frame_pass1_ms: f32 = 0;
pub var last_frame_pass2_ms: f32 = 0;
pub var last_frame_pass2_glyph_ms: f32 = 0;
pub var last_frame_pass2_decoration_ms: f32 = 0;
pub var last_frame_hover_ms: f32 = 0;
pub var last_frame_startup_ms: f32 = 0;

pub fn setTickDetailTimes(pty_read_ms: f32, terminal_write_ms: f32, renderstate_ms: f32) void {
    last_frame_pty_read_ms = pty_read_ms;
    last_frame_terminal_write_ms = terminal_write_ms;
    last_frame_renderstate_ms = renderstate_ms;
}

pub fn setTickPhaseTimes(cleanup_ms: f32, prune_ms: f32, events_ms: f32, htp_ms: f32, resize_ms: f32, layout_ms: f32, tick_panes_ms: f32, hover_ms: f32, startup_ms: f32) void {
    last_frame_cleanup_ms = cleanup_ms;
    last_frame_prune_ms = prune_ms;
    last_frame_events_ms = events_ms;
    last_frame_htp_ms = htp_ms;
    last_frame_resize_ms = resize_ms;
    last_frame_layout_ms = layout_ms;
    last_frame_tick_panes_ms = tick_panes_ms;
    last_frame_hover_ms = hover_ms;
    last_frame_startup_ms = startup_ms;
}

pub fn setTickPaneDetailTimes(title_ms: f32, cwd_ms: f32, scrollbar_ms: f32) void {
    last_frame_title_ms = title_ms;
    last_frame_cwd_ms = cwd_ms;
    last_frame_scrollbar_ms = scrollbar_ms;
}

pub fn setPollPtyDetailTimes(has_pending_ms: f32, sanitize_ms: f32, child_alive_ms: f32, encoder_sync_ms: f32) void {
    last_frame_has_pending_ms = has_pending_ms;
    last_frame_sanitize_ms = sanitize_ms;
    last_frame_child_alive_ms = child_alive_ms;
    last_frame_encoder_sync_ms = encoder_sync_ms;
}

pub fn setRendererQueueDetailTimes(pass1_ms: f32, pass2_ms: f32) void {
    last_frame_pass1_ms = pass1_ms;
    last_frame_pass2_ms = pass2_ms;
}

pub fn setRendererPass2DetailTimes(glyph_ms: f32, decoration_ms: f32) void {
    last_frame_pass2_glyph_ms = glyph_ms;
    last_frame_pass2_decoration_ms = decoration_ms;
}
