--- Smart-splits integration for hollow.
---
--- This file goes in your hollow config (conf/) and wires up focus/resize
--- keybinds that forward to nvim when a vim pane is active.
---
--- NVIM SETUP
---
--- On the nvim side, add `mrjones2014/smart-splits.nvim` with a custom mux
--- that speaks HTP (Hollow Terminal Protocol) over OSC 1337.
---
--- 1. Install the hollow lib at `lua/custom/lib/hollow.lua`:
---
---    local M = {}
---
---    local function htp_emit(name, payload)
---      local id = tostring(vim.fn.pid)
---      local json = vim.fn.json_encode({
---        kind = "event", id = id, name = name,
---        payload = payload or vim.empty_dict(),
---      })
---      local esc = string.format("\027]1337;Hollow;%s\027\\", json)
---      if vim.fn.filewritable("/dev/fd/2") == 1 then
---        vim.fn.writefile({ esc }, "/dev/fd/2", "b")
---      else
---        vim.fn.chansend(vim.v.stderr, esc)
---      end
---    end
---
---    function M.activate_pane_direction(dir)
---      htp_emit("focus_pane", { direction = dir:lower() })
---    end
---
---    function M.resize_pane_direction(dir)
---      local axis  = (dir == "Left" or dir == "Right") and "vertical" or "horizontal"
---      local delta = (dir == "Left" or dir == "Up") and -0.05 or 0.05
---      htp_emit("resize_pane", { axis = axis, delta = delta })
---    end
---
---    function M.current_pane_id()
---      return vim.env.HOLLOW_PANE_ID
---    end
---
---    return M
---
--- 2. In your smart-splits plugin spec, set up the custom mux:
---
---    local multiplexer
---    if vim.env.HOLLOW_PANE_ID then
---      multiplexer = require("custom.lib.hollow")
---    end
---
---    local custom_mux = {
---      type = "custom",
---      is_in_session = function() return true end,
---      current_pane_id = function() return multiplexer.current_pane_id() end,
---      current_pane_at_edge = function(_) return false end,
---      current_pane_is_zoomed = function() return false end,
---      next_pane = function(dir)
---        multiplexer.activate_pane_direction(dir:sub(1,1):upper() .. dir:sub(2):lower())
---        return true
---      end,
---      resize_pane = function(dir, _)
---        multiplexer.resize_pane_direction(dir:sub(1,1):upper() .. dir:sub(2):lower())
---        return true
---      end,
---      split_pane = function() return false end,
---    }
---
---    Then in config:
---      local mux_api = require("smart-splits.mux")
---      mux_api.__mux = custom_mux
---      require("smart-splits").setup(opts)
---
---    Set `multiplexer_integration = false` (or `vim.g.smart_splits_multiplexer_integration = false`)
---    so smart-splits doesn't try to auto-detect tmux/wezterm.
---
--- Hollow sets `$HOLLOW_PANE_ID` in the nvim process environment so the lib
--- can detect it's running inside a hollow pane.

local hollow = _G.hollow

local function is_vim(pane)
  if not pane then
    return false
  end
  local fp = pane.foreground_process
  return fp and (fp:lower() == "nvim" or fp:lower() == "vim")
end

local function focus_handler(key, direction)
  return function()
    local pane = hollow.term.current_pane()
    if not pane then
      return
    end
    if is_vim(pane) then
      hollow.term.send_key("<C-" .. key .. ">", pane.id)
      return
    end
    hollow.term.focus_pane(direction)
  end
end

local function resize_handler(key, direction)
  return function()
    local pane = hollow.term.current_pane()
    if not pane then
      return
    end
    if is_vim(pane) then
      hollow.term.send_key("<C-A-" .. key .. ">", pane.id)
      return
    end
    local ok, splits = pcall(require, "smart-splits")
    local amount = ok and splits.get_config().resize_amount or 0.05
    local horizontal = direction == "up" or direction == "down"
    local by = (direction == "left" or direction == "up") and -amount or amount
    hollow.term.resize_pane(horizontal and "horizontal" or "vertical", by)
  end
end

local splits = require("smart-splits")
for key, mapping in pairs(splits.get_config().keys) do
  local handler
  if mapping.type == "focus" then
    handler = focus_handler(mapping.vim_key, mapping.direction)
  else
    handler = resize_handler(mapping.vim_key, mapping.direction)
  end
  hollow.keymap.set(key, handler, { desc = mapping.type .. " " .. mapping.direction .. " pane" })
end
