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

-- Example of user overriding or adding keys:
-- g.keymap.set("ctrl+t", "new_tab")
-- g.keymap.set("ctrl+w", "close_tab")
-- g.keymap.set("ctrl+tab", "next_tab")
-- g.keymap.set("ctrl+shift+tab", "prev_tab")

