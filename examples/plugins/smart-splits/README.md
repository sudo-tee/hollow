# smart-splits

Bidirectional pane navigation/resize between hollow and nvim.

When a nvim pane is focused, `focus_pane`/`resize_pane` keybinds forward the
corresponding key through to nvim first so smart-splits can move between nvim
windows. If the cursor is at the nvim window edge (or no vim pane is active),
hollow handles the navigation itself.

## Files

| Path | What |
|---|---|
| `hollow_plugin/smart-splits.lua` | Drop into `conf/` — registers focus/resize keybinds in hollow |
| `lua/smart-splits/init.lua` | Shared config (key table, resize amount). Reusable by `hollow_plugin/` |

## Nvim Setup

1. Install `mrjones2014/smart-splits.nvim`.

2. Add a small hollow lib at `lua/custom/lib/hollow.lua` that speaks HTP
   (Hollow Terminal Protocol over OSC 1337):

   ```lua
   local M = {}

   local function htp_emit(name, payload)
     local id = tostring(vim.fn.pid)
     local json = vim.fn.json_encode({
       kind = "event", id = id, name = name,
       payload = payload or vim.empty_dict(),
     })
     local esc = string.format("\027]1337;Hollow;%s\027\\", json)
     if vim.fn.filewritable("/dev/fd/2") == 1 then
       vim.fn.writefile({ esc }, "/dev/fd/2", "b")
     else
       vim.fn.chansend(vim.v.stderr, esc)
     end
   end

   function M.activate_pane_direction(dir)
     htp_emit("focus_pane", { direction = dir:lower() })
   end

   function M.resize_pane_direction(dir)
     local axis  = (dir == "Left" or dir == "Right") and "vertical" or "horizontal"
     local delta = (dir == "Left" or dir == "Up") and -0.05 or 0.05
     htp_emit("resize_pane", { axis = axis, delta = delta })
   end

   function M.current_pane_id()
     return vim.env.HOLLOW_PANE_ID
   end

   return M
   ```

3. Wire up a custom mux in your smart-splits plugin spec:

   ```lua
   local multiplexer
   if vim.env.HOLLOW_PANE_ID then
     multiplexer = require("custom.lib.hollow")
   end

   local custom_mux = {
     type = "custom",
     is_in_session = function() return true end,
     current_pane_id = function() return multiplexer.current_pane_id() end,
     current_pane_at_edge = function(_) return false end,
     current_pane_is_zoomed = function() return false end,
     next_pane = function(dir)
       multiplexer.activate_pane_direction(
         dir:sub(1,1):upper() .. dir:sub(2):lower()
       )
       return true
     end,
     resize_pane = function(dir, _)
       multiplexer.resize_pane_direction(
         dir:sub(1,1):upper() .. dir:sub(2):lower()
       )
       return true
     end,
     split_pane = function() return false end,
   }

   return {
     "mrjones2014/smart-splits.nvim",
     opts = { multiplexer_integration = false },
     config = function(_, opts)
       local mux_api = require("smart-splits.mux")
       mux_api.__mux = custom_mux
       require("smart-splits").setup(opts)
     end,
   }
   ```

Hollow sets `$HOLLOW_PANE_ID` in the nvim process environment, so the
`vim.env.HOLLOW_PANE_ID` guard works automatically.
