local g = hollow
local c = {
	bg = "#2b2d37",
	panel = "#1f2335",
	panel_alt = "#24283b",
	muted = "#3b4261",
	text = "#c0caf5",
	subtle = "#9aa5ce",
	accent = "#7aa2f7",
	active = "#89b4fa",
	warm = "#e0af68",
	green = "#9ece6a",
}

g.log("loading native rewrite config")

g.set_config({
	debug_overlay = true,
	backend = "sokol",
	vsync = false,
	max_fps = 120,
	fonts = {
		size = 14.5,
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
	scrollback = 20000,
	window_title = "hollow",
	window_width = 1440,
	window_height = 900,
	window_titlebar_show = false,
	top_bar_show = true,
	top_bar_show_when_single_tab = true,
	top_bar_height = 20,
	top_bar_bg = "#2b2d37",
	top_bar_draw_tabs = true,
	top_bar_draw_status = true,
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
		return {
			{ text = "  ", fg = c.accent, bg = c.panel_alt, bold = true },
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
			{ text = time_text, fg = c.accent, bg = c.panel },
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
		fg = is_active and c.panel or c.text,
		bg = hover_close and "#5a2d35" or (is_active and c.active or c.panel_alt),
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
			fg = is_active and c.panel or c.text,
			bg = is_active and c.accent or c.panel_alt,
		}
	end
)

-- Example of user overriding or adding keys:
-- g.keymap.set("ctrl+t", "new_tab")
-- g.keymap.set("ctrl+w", "close_tab")
-- g.keymap.set("ctrl+tab", "next_tab")
-- g.keymap.set("ctrl+shift+tab", "prev_tab")
