-- conf/init.lua
-- Example user configuration for hollow.
-- Copy this to ~/.config/ghostty-love/init.lua and customize.
--
-- `hollow` is available as a global by the time this file runs.

local g = hollow

-- ── Shell / WSL (Windows users) ──────────────────────────────────────────────
-- Running the Windows Love2D build?  Choose your shell here.
--
-- Option A: native PowerShell (default on Windows)
-- hollow.set_config({ shell = "pwsh.exe" })
--
-- Option B: WSL default distro
-- hollow.set_config({ shell = "wsl.exe" })
--
-- Option C: specific WSL distro + shell
-- hollow.set_config({ shell = "wsl.exe --distribution Ubuntu --exec /bin/fish" })
--
-- Avoid probing installed distros during startup; `wsl.exe --list` can be
-- surprisingly slow on some Windows setups.

-- Running Love2D *inside* WSL2 (the Linux build)?  Shell is auto-detected
-- from $SHELL.  You can still override:
-- if hollow.wsl.is_guest then
--     hollow.set_config({ shell = "/bin/fish" })
-- end

g.set_config({
	font_size = 15,
	-- Hinting options: "normal", "light", "mono", "none"
	font_hinting = "light",
	-- Experimental pane supersampling.  1 = off, 2 = render text to a 2x canvas
	-- and scale it back down.
	font_supersample = 1,
	startup_present_frame = true,
	-- Set font_path to a Nerd Font for icon/glyph support.
	-- Love2D on Windows: use a Windows path (forward slashes are fine).
	--   font_path = "C:/Windows/Fonts/CaskaydiaCoveNerdFont-Regular.ttf",
	font_path = "RecMonoDuotoneNerdFontMono-Regular.ttf",
	-- font_path = "JetBrainsMonoNerdFont-Medium.ttf",
	-- font_bold_path = "JetBrainsMonoNerdFont-Bold.ttf",
	-- font_italic_path = "JetBrainsMonoNerdFont-Italic.ttf",
	-- font_bold_italic_path = "JetBrainsMonoNerdFont-BoldItalic.ttf",
	-- font_bold_path = "RecMonoDuotoneNerdFontMono-Bold.ttf",
	-- font_italic_path = "RecMonoDuotoneNerdFontMono-Italic.ttf",
	-- font_bold_italic_path = "RecMonoDuotoneNerdFontMono-BoldItalic.ttf",
	-- Optional explicit style faces. These are preferred over auto-detection.
	-- font_bold_path = "RecMonoLinearNerdFontMono-Bold.ttf",
	-- font_italic_path = "RecMonoLinearNerdFontMono-Italic.ttf",
	-- font_bold_italic_path = "RecMonoLinearNerdFontMono-BoldItalic.ttf",
	--   font_path = "C:/Users/YourName/AppData/Local/Microsoft/Windows/Fonts/JetBrainsMonoNerdFont-Regular.ttf",
	-- Love2D inside WSL2 (Linux build): use a Linux path.
	--   font_path = "/usr/share/fonts/truetype/nerd-fonts/JetBrainsMonoNerdFont-Regular.ttf",
	--   font_path = "/home/yourname/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
	-- shell is intentionally omitted here: platform.lua auto-detects the
	-- right shell for Windows (pwsh/cmd) vs Linux/WSL ($SHELL).
	-- Uncomment ONE of the lines below only if you want to override it:
	-- shell = "wsl.exe",                                    -- WSL default distro
	-- shell = "wsl.exe --distribution Ubuntu",              -- specific distro
	shell = "wsl.exe",
	tab_bar_height = 26,
	status_bar_height = 22,
	split_gap = 2,
})

-- Override colour palette
local c = g.color
g.set_config({
	colors = {
		background = c.from_hex("#0d0f14"),
		foreground = c.from_hex("#cdd6f4"),
		cursor = c.from_hex("#f5a97f"),
		selection = { 0.24, 0.43, 0.73, 0.4 },

		tab_bar_bg = c.from_hex("#11131a"),
		tab_active = c.from_hex("#1e2030"),
		tab_inactive = c.from_hex("#11131a"),
		tab_text = c.from_hex("#cdd6f4"),

		status_bar_bg = c.from_hex("#0d0f14"),
		status_bar_fg = c.from_hex("#7f849c"),
		split_line = c.from_hex("#2a2d3d"),
	},
})

-- ── Key bindings ─────────────────────────────────────────────────────────────
-- Add custom bindings on top of defaults
g.keys.bind({ ctrl = true, shift = true }, "h", "split_h")
g.keys.bind({ ctrl = true, shift = true }, "v", "split_v")

-- Custom action via callback
g.keys.bind({ super = true }, "k", function()
	g.log("Custom keybind fired!")
	g.actions.new_tab()
end)

-- ── Status bar ───────────────────────────────────────────────────────────────
g.status_bar.set_left(function(workspace, tab, pane)
	local ws_name = workspace and workspace.name or "?"
	local segments = {
		{ text = "  " .. ws_name .. "  ", fg = { 1, 1, 1, 1 }, bg = c.from_hex("#7287fd") },
	}
	if tab then
		local title = (pane and pane.title ~= "" and pane.title) or tab.title or "terminal"
		table.insert(segments, {
			text = "  " .. title .. "  ",
			fg = c.from_hex("#cdd6f4"),
			bg = c.from_hex("#1e2030"),
		})
	end
	return segments
end)

g.status_bar.set_right(function(workspace, tab, pane)
	local time_str = os.date("  %H:%M  ")
	local date_str = os.date("  %a %d %b  ")
	return {
		{ text = date_str, fg = c.from_hex("#7f849c"), bg = c.from_hex("#11131a") },
		{ text = time_str, fg = c.from_hex("#cdd6f4"), bg = c.from_hex("#1e2030") },
	}
end)

-- ── Event hooks ──────────────────────────────────────────────────────────────
g.on("app:ready", function()
	g.log("hollow ready! Version:", g.version:to_string())
end)

g.on("pane:focus", function(pane)
	-- e.g. update window title
	if pane then
		love.window.setTitle("hollow - " .. (pane.title or "terminal"))
	end
end)

g.on("workspace:switch", function(idx)
	g.log("Switched to workspace", idx)
end)
