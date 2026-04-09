local g = hollow
local theme = {
	tab_bar = {
		background = "#2A2A37",
		active_tab = {
			bg = "#1F1F28",
			fg = "#e0af68",
		},
		inactive_tab = {
			bg = "#2A2A37",
			fg = "#dcd7ba",
		},
		hover_close_bg = "#5a2d35",
	},
	foreground = "#dcd7ba",
	background = "#1F1F28",

	cursor_bg = "#c8c093",
	cursor_fg = "#0d0c0c",
	cursor_border = "#c8c093",

	selection_fg = "#c8c093",
	selection_bg = "#0d0c0c",

	scrollbar = {
		track = "#1b1d25",
		thumb = "#5f667a",
		thumb_hover = "#7a839b",
		thumb_active = "#9fb8e8",
		border = "#2d3140",
	},
	split = "#766b90",
	accent = "#7e9cd8",
	warm = "#e0af68",
	status = {
		bg = "#2A2A37",
		fg = "#7e9cd8",
	},
	workspace = {
		active_bg = "#7e9cd8",
		active_fg = "#1F1F28",
		inactive_bg = "#2A2A37",
		inactive_fg = "#dcd7ba",
	},

	ansi = {
		"#090618", -- Black
		"#c34043", -- Maroon
		"#76946a", -- Green
		"#c0a36e", -- Olive
		"#7e9cd8", -- Navy
		"#957fb8", -- Purple
		"#6a9589", -- Teal
		"#c8c093", -- Silver
	},
	brights = {
		"#727169", -- Grey
		"#e82424", -- Red
		"#98bb6c", -- Lime
		"#e6c384", -- Yellow
		"#7fb4ca", -- Blue
		"#938aa9", -- Fuchsia
		"#7aa89f", -- Aqua
		"#dcd7ba", -- White
	},
	indexed = { [16] = "#ffa066", [17] = "#ff5d62" },
}

-- g.log("loading native rewrite config")

g.config.set({
	debug_overlay = false,
	backend = "sokol",
	vsync = false,
	max_fps = 120,
	padding = 0,
	theme = theme,
	fonts = {
		size = 14.5,
		line_height = 0.9,
		padding_x = 0,
		padding_y = 0,
		smoothing = "grayscale",
		hinting = "light",
		ligatures = true,
		-- coverage_boost = 1.0,
		-- coverage_add = 0,
		embolden = 0.33,
		regular = "fonts/RecMonoDuotone-Regular-1.085.ttf",
		bold = "fonts/RecMonoLinear-Bold-1.085.ttf",
		italic = "fonts/RecMonoDuotone-Italic-1.085.ttf",
		bold_italic = "fonts/RecMonoDuotone-BoldItalic-1.085.ttf",
		fallbacks = {
			-- Extra user fallbacks can be added here; native also bundles
			-- Symbols Nerd Font Mono and Noto Sans Symbols 2 by default.
		},
	},
	cols = 120,
	rows = 34,
	-- Scrollback is measured in bytes, not lines.
	-- 64 MB retains far more history for wide terminals.
	window_title = "hollow",
	window_width = 1440,
	window_height = 900,
	window_titlebar_show = false,
	top_bar_show = true,
	top_bar_show_when_single_tab = true,
	top_bar_height = 20,
	top_bar_bg = theme.tab_bar.background,
	top_bar_draw_tabs = true,
	top_bar_draw_status = true,
	scrollback = 64000000,
	scrollbar = {
		enabled = true,
		width = 14,
		min_thumb_size = 24,
		margin = 2,
		jump_to_click = true,
		track = "#1b1d25",
		thumb = "#5f667a",
		thumb_hover = "#7a839b",
		thumb_active = "#9fb8e8",
		border = "#2d3140",
	},
	hyperlinks = {
		enabled = true,
		shift_click_only = true,
		match_www = true,
		prefixes = "https:// http:// file:// ftp:// mailto:",
		delimiters = " \t\r\n\"'<>[]{}|\\^`",
		trim_leading = "([<{'\"",
		trim_trailing = ".,;:!?)]}",
	},
})

-- g.term.set_workspace_name("default")

if g.platform.is_windows then
	g.config.set({
		shell = "wsl.exe",
	})
else
	g.config.set({
		shell = g.platform.default_shell,
	})
end

local _metrics_cache = nil
local _metrics_last_t = 0

g.ui.topbar.mount(g.ui.topbar.new({
	render = function(ctx)
		local left = {}
		local right = {}
		local leader_state = nil -- g.keys.get_leader_state()

		if leader_state and leader_state.active then
			left[#left + 1] = g.ui.span(" " .. leader_state.display .. " ", {
				fg = theme.background,
				bg = theme.warm,
				bold = true,
			})
			if leader_state.next and #leader_state.next > 0 then
				left[#left + 1] = g.ui.span(" " .. table.concat(leader_state.next_display or {}, "  ") .. " ", {
					fg = theme.status.fg,
					bg = theme.status.bg,
				})
			end
		else
			left[#left + 1] = g.ui.span("  ", { fg = theme.warm, bg = theme.tab_bar.background, bold = true })
		end
		left[#left + 1] = g.ui.span(" " .. (ctx.term.pane and ctx.term.pane.cwd or "") .. " ", {
			fg = theme.status.fg,
			bg = theme.status.bg,
		})

		-- right[#right + 1] = g.ui.span(g.strftime("%H:%M:%S"), { fg = theme.status.fg, bg = theme.status.bg })

		local row = {}
		for _, node in ipairs(left) do
			row[#row + 1] = node
		end
		row[#row + 1] = g.ui.spacer()
		for _, node in ipairs(right) do
			row[#row + 1] = node
		end
		return row
	end,
}))

-- g.keymap.set_leader("ctrl+space", { timeout_ms = 1200 })
-- g.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
-- g.keymap.set("<leader>sd", "split_horizontal", { desc = "split horizontal" })
-- Example of user overriding or adding keys:
-- g.keymap.set("ctrl+t", "new_tab")
-- g.keymap.set("ctrl+w", "close_tab")
-- g.keymap.set("ctrl+tab", "next_tab")
-- g.keymap.set("ctrl+shift+tab", "prev_tab")
-- g.keymap.set_leader("ctrl+a", { timeout_ms = 1200 })
-- g.keymap.set("<leader>c", "close_pane", { desc = "close pane" })
-- g.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
-- g.keymap.set("<leader>sd", "split_horizontal", { desc = "split horizontal" })
-- g.keymap.del("ctrl+shift+arrow_left")
-- g.keymap.set("alt+shift+page_up", "scrollback_page_up", { desc = "scrollback page up" })
-- g.keymap.set("alt+shift+page_down", "scrollback_page_down", { desc = "scrollback page down" })
-- g.keymap.set("ctrl+shift+home", "scrollback_top", { desc = "scrollback top" })
-- g.keymap.set("ctrl+shift+end", "scrollback_bottom", { desc = "scrollback bottom" })
