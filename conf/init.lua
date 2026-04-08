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

g.log("loading native rewrite config")

g.set_config({
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

hollow.workspace.set_name("default")

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

local _metrics_cache = nil
local _metrics_last_t = 0

hollow.status.set(function(side, active_tab_index, tab_count)
	local workspace_count = hollow.get_workspace_count()
	local workspace_name = hollow.workspace.get_name(hollow.get_active_workspace_index())

	if side == "left" then
		local leader_state = hollow.get_leader_state and hollow.get_leader_state() or nil
		local leader = nil

		if leader_state and leader_state.active then
			leader = {
				{
					text = " " .. leader_state.display .. " ",
					fg = theme.background,
					bg = theme.warm,
					bold = true,
				},
			}

			if leader_state.next and #leader_state.next > 0 then
				local next_items = leader_state.next_display or {}
				table.insert(leader, {
					text = " " .. table.concat(next_items, "  ") .. " ",
					fg = theme.status.fg,
					bg = theme.status.bg,
				})
			end
		end

		if leader then
			return leader
		end

		return {
			{ text = "  ", fg = theme.warm, bg = theme.tab_bar.background, bold = true },
		}
	end

	if side == "right" then
		local now = os.time()
		-- if now ~= _metrics_last_t then
		-- 	_metrics_cache = hollow.get_system_metrics()
		-- 	_metrics_last_t = now
		-- end
		--
		-- local cpu_text = ""
		-- local mem_text = ""
		-- local m = _metrics_cache
		-- if m and m.error ~= "error" then
		-- 	cpu_text = string.format("CPU: %.0f%% ", m.cpu_usage)
		-- 	mem_text = string.format("RAM: %d/%dMB ", m.memory_used_mb, m.memory_total_mb)
		-- end

		local time_text = hollow.strftime("%H:%M:%S")

		return {
			{ text = time_text, fg = theme.status.fg, bg = theme.status.bg },
		}
	end

	return nil
end)

hollow.top_bar.format_tab_title(function(index, is_active, hover_close, fallback_title)
	local icon = is_active and "" or ""
	local title = fallback_title

	if title == nil or title == "" then
		title = "shell"
	end

	return {
		text = " " .. icon .. " " .. title .. " ",
		fg = is_active and theme.tab_bar.active_tab.fg or theme.tab_bar.inactive_tab.fg,
		bg = hover_close and theme.tab_bar.hover_close_bg
			or (is_active and theme.tab_bar.active_tab.bg or theme.tab_bar.inactive_tab.bg),
		bold = is_active,
	}
end)

hollow.top_bar.format_workspace_title(
	function(index, is_active, active_workspace_index, workspace_count, fallback_title)
		local label = "  "
			.. fallback_title
			.. "  "
			.. tostring(index + 1)
			.. "/"
			.. tostring(workspace_count)
			.. " "

		return {
			text = label,
			fg = is_active and theme.workspace.active_fg or theme.workspace.inactive_fg,
			bg = is_active and theme.workspace.active_bg or theme.workspace.inactive_bg,
		}
	end
)

g.keymap.set_leader("ctrl+space", { timeout_ms = 1200 })
g.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
g.keymap.set("<leader>sd", "split_horizontal", { desc = "split horizontal" })
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
g.keymap.set("alt+shift+page_up", "scrollback_page_up", { desc = "scrollback page up" })
g.keymap.set("alt+shift+page_down", "scrollback_page_down", { desc = "scrollback page down" })
g.keymap.set("ctrl+shift+home", "scrollback_top", { desc = "scrollback top" })
g.keymap.set("ctrl+shift+end", "scrollback_bottom", { desc = "scrollback bottom" })
