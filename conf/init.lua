local g = hollow

g.log("loading native rewrite config")

g.set_config({
	backend = "sokol",
	font_size = 14.5,
	font_padding_x = 0,
	font_padding_y = 0,
	font_coverage_boost = 1.0,
	font_coverage_add = 0,
	font_lcd = false,
	font_embolden = 0.3,
	cols = 120,
	rows = 34,
	scrollback = 20000,
	window_title = "hollow",
	window_width = 1440,
	window_height = 900,
	top_bar_show = true,
	top_bar_show_when_single_tab = true,
	top_bar_height = 32,
	top_bar_bg = "#2b2d37",
	top_bar_draw_tabs = true,
	top_bar_draw_status = true,
})

if g.platform.is_windows then
	g.set_config({
		shell = "wsl.exe",
		ghostty_library = "ghostty-vt.dll",
		luajit_library = "luajit-5.1.dll",
	})
else
	g.set_config({
		shell = g.platform.default_shell,
		ghostty_library = "ghostty-vt.so",
	})
end

hollow.status.set(function(side, active_tab_index, tab_count)
	if side == "left" then
		return {
			{ text = " default ", fg = "#1f2335", bg = "#7aa2f7", bold = true },
			{ text = " | " .. tostring(tab_count) .. " ", fg = "#c0caf5", bg = "#3b4261" },
		}
	end

	if side == "right" then
		return {
			{ text = hollow.strftime("%B %e, %H:%M"), fg = "#7aa2f7", bg = "#1f2335" },
		}
	end

	return nil
end)
hollow.top_bar.format_tab_title(function(index, is_active, hover_close, fallback_title)
	if is_active then
		return "  nvim  " .. fallback_title
	end
	return fallback_title
end)

-- Example of user overriding or adding keys:
-- g.keymap.set("ctrl+t", "new_tab")
-- g.keymap.set("ctrl+w", "close_tab")
-- g.keymap.set("ctrl+tab", "next_tab")
-- g.keymap.set("ctrl+shift+tab", "prev_tab")
