-- src/core/app.lua
-- Top-level orchestrator: manages Workspaces, routes input, drives rendering.

local Workspace = require("src.core.workspace")
local Renderer = require("src.renderer.terminal")
local Split = require("src.core.split")
local TabBar = require("src.ui.tab_bar")
local StatusBar = require("src.ui.status_bar")
local KeyMap = require("src.core.keymap")
local Config = require("src.core.config")
local EventBus = require("src.core.event_bus")
local GhosttyFFI = require("src.core.ghostty_ffi")
local Window = require("src.core.window")

local App = {}

-- ── State ────────────────────────────────────────────────────────────────────
local workspaces = {}
local active_ws_idx = 1
local win_w, win_h = 0, 0

-- ── Geometry helpers ─────────────────────────────────────────────────────────
local function status_bar_h()
	return Config.get("status_bar_height") or 20
end

local function content_rect()
	return { x = 0, y = 0, w = win_w, h = win_h - status_bar_h() }
end

local function sync_cell_metrics()
	local cw, ch = Renderer.char_size()
	local cw_px, ch_px = Renderer.char_pixel_size()
	Split.set_cell_size(cw, ch, cw_px, ch_px)
end

local function is_printable_key(key)
	return key == "space" or #key == 1
end

local function should_route_keypress(key, mods)
	if not is_printable_key(key) then
		return true
	end

	return mods.ctrl or mods.alt or mods.super
end

-- ── Init ─────────────────────────────────────────────────────────────────────
function App.init()
	win_w, win_h = love.graphics.getDimensions()
	love.graphics.setBlendMode("alpha", "alphamultiply")
	love.keyboard.setKeyRepeat(true)

	-- Set app icon
	local icon = love.image.newImageData("assets/logo.png")
	love.window.setIcon(icon)

	-- Font setup (pass to renderer)
	local font_path = Config.get("font_path") or nil
	local font_size = Config.get("font_size") or 14
	Renderer.init(font_path, font_size)

	-- Sync logical layout cell size and physical pixel cell size.
	sync_cell_metrics()

	-- First workspace
	local ws = Workspace.new(content_rect())
	table.insert(workspaces, ws)

	-- Emit startup event for user scripts
	EventBus.emit("app:ready")

	-- Apply window decoration overrides (e.g. no_titlebar) after the window
	-- is fully up so the HWND is reachable.
	Window.apply_decorations()
end

-- ── Active workspace helpers ─────────────────────────────────────────────────
local function active_ws()
	return workspaces[active_ws_idx]
end

local function focused_pane()
	return active_ws():focused_pane()
end

-- ── Workspaces ───────────────────────────────────────────────────────────────
function App.new_workspace(opts)
	local ws = Workspace.new(content_rect(), opts)
	table.insert(workspaces, ws)
	active_ws_idx = #workspaces
	return ws
end

function App.switch_workspace(idx)
	if workspaces[idx] then
		active_ws_idx = idx
		EventBus.emit("workspace:switch", idx)
	end
end

function App.close_workspace(idx)
	idx = idx or active_ws_idx
	if workspaces[idx] then
		workspaces[idx]:destroy()
		table.remove(workspaces, idx)
		if #workspaces == 0 then
			love.event.quit(0)
		end
		active_ws_idx = math.min(active_ws_idx, #workspaces)
	end
end

-- ── Update ───────────────────────────────────────────────────────────────────
function App.update(dt)
    local idx = 1
    while idx <= #workspaces do
        local ws = workspaces[idx]
        local empty = ws:update()
        if empty then
            ws:destroy()
            table.remove(workspaces, idx)
            if #workspaces == 0 then
                love.event.quit(0)
                return
            end
            if active_ws_idx > #workspaces then
                active_ws_idx = #workspaces
            elseif idx <= active_ws_idx and active_ws_idx > 1 then
                active_ws_idx = active_ws_idx - 1
            end
        else
            idx = idx + 1
        end
    end
    EventBus.emit("app:update", dt)
end

-- ── Draw ─────────────────────────────────────────────────────────────────────
function App.draw()
	local ws = active_ws()
	if not ws then
		return
	end

	local tab = ws:active_tab()
	if not tab then
		return
	end

	-- Begin per-frame renderer stats collection.
	Renderer.begin_frame()

	-- Draw all panes in the active tab
	local panes = tab:all_panes()

	for _, pane in ipairs(panes) do
		local focused = (pane == tab.focused)
		Renderer.draw_pane(pane, focused)
	end

	-- Draw split dividers
	Renderer.draw_splits(tab.root)

	-- Tab bar
	TabBar.draw(ws, tab)

	-- Status bar
	StatusBar.draw(ws, tab, focused_pane())

	-- Finalise frame timing and draw optional debug overlay.
	Renderer.end_frame()
	Renderer.draw_debug_overlay()
end

-- ── Input routing ────────────────────────────────────────────────────────────
-- Track whether the last keypressed was handled by send_key so textinput
-- can avoid double-sending the same character.
local _last_key_handled = false

function App.keypressed(key, scancode, isrepeat)
	local mods = {
		ctrl = love.keyboard.isDown("lctrl", "rctrl"),
		shift = love.keyboard.isDown("lshift", "rshift"),
		alt = love.keyboard.isDown("lalt", "ralt"),
		super = love.keyboard.isDown("lgui", "rgui"),
	}

	_last_key_handled = false

	-- Check global keybindings first (tab/split/workspace actions)
	local action = KeyMap.match(key, mods)
	if action then
		if not isrepeat then
			App._dispatch(action)
		end
		_last_key_handled = true
		return
	end

	-- Route all keys through the ghostty key encoder so that:
	--   • key repeat (hold backspace, arrows, etc.) works correctly
	--   • modifier combos (Ctrl/Alt/Shift) are encoded faithfully
	--   • nvim and other TUI apps receive the correct VT sequences
	--
	-- The ghostty encoder handles plain printable keys, special keys, and
	-- modifier combinations.  For keys it cannot encode (returns nil/empty),
	-- we fall through to love.textinput so Unicode / IME input still works.
	local action_type = isrepeat and GhosttyFFI.KEY_ACTION.REPEAT or GhosttyFFI.KEY_ACTION.PRESS

	local pane = focused_pane()
	if pane and should_route_keypress(key, mods) then
		-- send_key returns true when it successfully wrote bytes to the PTY
		local sent = pane:send_key(key, mods, action_type)
		if sent then
			_last_key_handled = true
		end
	end
end

function App.keyreleased(key, scancode) end

function App.textinput(text)
	-- textinput fires right after keypressed for printable chars.
	-- If send_key already handled it via the ghostty encoder, skip here to
	-- avoid double-sending.  For IME / composed characters that have no
	-- corresponding keypressed event, _last_key_handled will be false and
	-- we forward them normally.
	if _last_key_handled then
		_last_key_handled = false
		return
	end
	local pane = focused_pane()
	if pane then
		pane:send_text(text)
	end
end

function App.mousepressed(x, y, button, istouch, presses)
	local ws = active_ws()
	if not ws then
		return
	end
	if TabBar.mousepressed(ws, x, y, button) then
		return
	end
	-- Click to focus a pane
	local pane = ws:get_pane_at(x, y)
	if pane then
		ws:active_tab():focus_pane(pane)
		EventBus.emit("pane:focus", pane)
	end
end

function App.mousereleased(x, y, button) end
function App.mousemoved(x, y, dx, dy) end

function App.wheelmoved(x, y)
	local pane = focused_pane()
	if pane then
		pane:scroll(-y * 3)
	end
end

function App.resize(w, h)
	win_w, win_h = w, h
	sync_cell_metrics()
	local rect = content_rect()
	for _, ws in ipairs(workspaces) do
		ws:relayout(rect)
	end
	EventBus.emit("app:resize", w, h)
end

function App.quit()
	for _, ws in ipairs(workspaces) do
		ws:destroy()
	end
	EventBus.emit("app:quit")
end

-- ── Action dispatcher (called by KeyMap and scripting API) ───────────────────
function App._dispatch(action, args)
	local ws = active_ws()
	local tab = ws and ws:active_tab()

	if action == "new_tab" then
		ws:new_tab()
	elseif action == "close_tab" then
		local empty = ws:close_tab()
		if empty then
			App.close_workspace()
		end
	elseif action == "next_tab" then
		ws:next_tab()
	elseif action == "prev_tab" then
		ws:prev_tab()
	elseif action == "split_h" then
		ws:split_horizontal()
	elseif action == "split_v" then
		ws:split_vertical()
	elseif action == "close_pane" then
		local dead = ws:close_focused_pane()
		if dead then
			App.close_workspace()
		end
	elseif action == "focus_next" then
		ws:cycle_focus(1)
	elseif action == "focus_prev" then
		ws:cycle_focus(-1)
	elseif action == "new_workspace" then
		App.new_workspace()
	elseif action == "next_workspace" then
		App.switch_workspace((active_ws_idx % #workspaces) + 1)
	elseif action == "prev_workspace" then
		App.switch_workspace(((active_ws_idx - 2) % #workspaces) + 1)
	elseif action == "toggle_debug_overlay" then
		-- Toggle the renderer debug overlay (show/hide on-screen stats)
		Renderer.toggle_debug_overlay()
	elseif action == "switch_workspace" and args then
		App.switch_workspace(args)
	else
		EventBus.emit("action:" .. action, args)
	end
end

return App
