-- src/api/init.lua
-- The `ghostty` global: the public scripting API exposed to user init.lua.
-- Modelled on WezTerm's wezterm module.
--
-- Usage in ~/.config/ghostty-love/init.lua:
--
--   local g = ghostty   -- already global
--
--   g.on("app:ready", function()
--       g.set_config({ font_size = 16, shell = "/bin/fish" })
--   end)
--
--   g.keys.bind({ ctrl=true, shift=true }, "p", "new_tab")
--
--   g.status_bar.set_left(function(ws, tab, pane)
--       return { { text = "  " .. ws.name .. "  ", fg={1,1,1,1}, bg={0.2,0.4,0.7,1} } }
--   end)

local Config    = require("src.core.config")
local EventBus  = require("src.core.event_bus")
local KeyMap    = require("src.core.keymap")
local StatusBar = require("src.ui.status_bar")

local M = {}

function M.create()
    local api = {}

    -- ── Version ──────────────────────────────────────────────────────────────
    api.version = {
        major = 0, minor = 1, patch = 0,
        to_string = function(self)
            return string.format("%d.%d.%d", self.major, self.minor, self.patch)
        end,
    }

    -- ── Config ───────────────────────────────────────────────────────────────
    --- Set one or more config values.
    --- ghostty.set_config({ font_size = 16, shell = "/bin/fish" })
    function api.set_config(tbl)
        Config.merge(tbl)
    end

    function api.get_config(key)
        return Config.get(key)
    end

    -- ── Events ───────────────────────────────────────────────────────────────
    --- Subscribe to an event.
    --- ghostty.on("pane:focus", function(pane) print(pane.title) end)
    function api.on(event, fn)
        EventBus.on(event, fn)
    end

    function api.once(event, fn)
        EventBus.once(event, fn)
    end

    function api.off(event, fn)
        EventBus.off(event, fn)
    end

    function api.emit(event, ...)
        EventBus.emit(event, ...)
    end

    -- ── Key bindings ──────────────────────────────────────────────────────────
    api.keys = {}

    --- Bind a key combination to an action name (string) or a callback.
    --- ghostty.keys.bind({ ctrl=true, shift=true }, "p", "new_tab")
    --- ghostty.keys.bind({ super=true }, "k", function() print("hi") end)
    function api.keys.bind(mods, key, action_or_fn)
        if type(action_or_fn) == "function" then
            -- Wrap in an event so the dispatcher can call it
            local event_name = "action:user_" .. key
            EventBus.on(event_name, action_or_fn)
            KeyMap.add_binding(mods, key, "user_" .. key)
        else
            KeyMap.add_binding(mods, key, action_or_fn)
        end
    end

    -- ── Status bar ────────────────────────────────────────────────────────────
    api.status_bar = {}

    --- Set the left side segments.
    --- Accepts a static list of segment tables or a function(workspace, tab, pane) → segments.
    --- Segment: { text="...", fg={r,g,b,a}, bg={r,g,b,a} }
    function api.status_bar.set_left(fn_or_segments)
        StatusBar.set_left(fn_or_segments)
    end

    function api.status_bar.set_right(fn_or_segments)
        StatusBar.set_right(fn_or_segments)
    end

    -- ── Tab / workspace control ───────────────────────────────────────────────
    -- These call App._dispatch – lazy require to avoid circular deps.
    local function dispatch(action, args)
        require("src.core.app")._dispatch(action, args)
    end

    api.actions = {}
    function api.actions.new_tab()         dispatch("new_tab") end
    function api.actions.close_tab()       dispatch("close_tab") end
    function api.actions.next_tab()        dispatch("next_tab") end
    function api.actions.prev_tab()        dispatch("prev_tab") end
    function api.actions.split_h()         dispatch("split_h") end
    function api.actions.split_v()         dispatch("split_v") end
    function api.actions.close_pane()      dispatch("close_pane") end
    function api.actions.focus_next()      dispatch("focus_next") end
    function api.actions.focus_prev()      dispatch("focus_prev") end
    function api.actions.new_workspace()   dispatch("new_workspace") end
    function api.actions.next_workspace()  dispatch("next_workspace") end
    function api.actions.prev_workspace()  dispatch("prev_workspace") end
    function api.actions.switch_workspace(idx) dispatch("switch_workspace", idx) end

    -- ── WSL helpers (Windows only) ────────────────────────────────────────────
    api.wsl = {}

    --- Spawn a pane using WSL. Only meaningful when running on Windows.
    --- opts: { distro="Ubuntu", shell="/bin/fish", cols=N, rows=N }
    --- Returns the new Pane, or errors if WSL is unavailable.
    function api.wsl.spawn_pane(opts)
        local Pty  = require("src.core.pty")
        local Pane = require("src.core.pane")
        -- Pane.new_with_pty lets you inject a pre-spawned PTY
        -- (add that constructor to pane.lua if you want fine control)
        local pty = Pty.spawn_wsl(opts)
        return pty  -- caller can attach to a pane manually
    end

    --- List installed WSL distributions. Returns {} on non-Windows.
    function api.wsl.distros()
        return require("src.core.pty").wsl_distros()
    end

    --- true when running the Windows Love2D build with wsl.exe available.
    api.wsl.available = require("src.core.platform").has_wsl

    --- true when Love2D itself is running inside WSL (Linux build on WSL).
    api.wsl.is_guest  = require("src.core.platform").is_wsl_guest


    api.color = {}

    function api.color.from_hex(hex)
        hex = hex:gsub("#", "")
        local r = tonumber(hex:sub(1,2), 16) / 255
        local g = tonumber(hex:sub(3,4), 16) / 255
        local b = tonumber(hex:sub(5,6), 16) / 255
        local a = #hex >= 8 and tonumber(hex:sub(7,8), 16) / 255 or 1
        return {r, g, b, a}
    end

    function api.color.lerp(a, b, t)
        return {
            a[1] + (b[1]-a[1])*t,
            a[2] + (b[2]-a[2])*t,
            a[3] + (b[3]-a[3])*t,
            (a[4] or 1) + ((b[4] or 1)-(a[4] or 1))*t,
        }
    end

    -- ── Logging ───────────────────────────────────────────────────────────────
    function api.log(...)
        local parts = {}
        for _, v in ipairs({...}) do
            table.insert(parts, tostring(v))
        end
        io.stderr:write("[ghostty] " .. table.concat(parts, "\t") .. "\n")
    end

    return api
end

return M
