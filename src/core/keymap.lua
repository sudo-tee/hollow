-- src/core/keymap.lua
-- Two responsibilities:
--   1. Match key+mods against user-configured bindings → action name
--   2. Encode key+mods into a VT/kitty key sequence string

local Config = require("src.core.config")

local M = {}

-- ── Default bindings ─────────────────────────────────────────────────────────
-- Format: { mods={ctrl,shift,alt,super}, key="x" } → "action"
-- User config can add/override via ghostty.keys.bind(...)

local default_bindings = {
    -- Tabs
    { mods={ctrl=true,shift=true}, key="t",     action="new_tab"         },
    { mods={ctrl=true,shift=true}, key="w",     action="close_tab"       },
    { mods={ctrl=true},            key="tab",   action="next_tab"        },
    { mods={ctrl=true,shift=true}, key="tab",   action="prev_tab"        },
    -- Splits
    { mods={ctrl=true,shift=true}, key="d",     action="split_h"         },
    { mods={ctrl=true,shift=true}, key="e",     action="split_v"         },
    { mods={ctrl=true,shift=true}, key="q",     action="close_pane"      },
    -- Focus
    { mods={ctrl=true},            key="[",     action="focus_prev"      },
    { mods={ctrl=true},            key="]",     action="focus_next"      },
    -- Workspaces
    { mods={ctrl=true,shift=true}, key="n",     action="new_workspace"   },
    { mods={ctrl=true,shift=true}, key="right", action="next_workspace"  },
    { mods={ctrl=true,shift=true}, key="left",  action="prev_workspace"  },
}

local user_bindings = {}  -- populated by Config / API

function M.add_binding(mods, key, action)
    table.insert(user_bindings, { mods=mods, key=key, action=action })
end

local function mods_match(binding_mods, actual_mods)
    for k, v in pairs(binding_mods) do
        if actual_mods[k] ~= v then return false end
    end
    -- Also make sure no *extra* mods are pressed that aren't in binding
    for k, v in pairs(actual_mods) do
        if v and binding_mods[k] == nil then return false end
    end
    return true
end

function M.match(key, mods)
    -- User bindings take priority
    for _, b in ipairs(user_bindings) do
        if b.key == key and mods_match(b.mods, mods) then
            return b.action
        end
    end
    for _, b in ipairs(default_bindings) do
        if b.key == key and mods_match(b.mods, mods) then
            return b.action
        end
    end
    return nil
end

-- ── VT key encoding ──────────────────────────────────────────────────────────
-- Minimal but correct subset. Extend for kitty protocol if desired.

local special = {
    ["return"]    = "\r",
    ["backspace"] = "\127",
    ["tab"]       = "\t",
    ["escape"]    = "\27",
    ["space"]     = " ",
    ["up"]        = "\27[A",
    ["down"]      = "\27[B",
    ["right"]     = "\27[C",
    ["left"]      = "\27[D",
    ["home"]      = "\27[H",
    ["end"]       = "\27[F",
    ["insert"]    = "\27[2~",
    ["delete"]    = "\27[3~",
    ["pageup"]    = "\27[5~",
    ["pagedown"]  = "\27[6~",
    ["f1"]        = "\27OP",
    ["f2"]        = "\27OQ",
    ["f3"]        = "\27OR",
    ["f4"]        = "\27OS",
    ["f5"]        = "\27[15~",
    ["f6"]        = "\27[17~",
    ["f7"]        = "\27[18~",
    ["f8"]        = "\27[19~",
    ["f9"]        = "\27[20~",
    ["f10"]       = "\27[21~",
    ["f11"]       = "\27[23~",
    ["f12"]       = "\27[24~",
}

function M.encode(key, mods)
    -- Ctrl+letter → control character
    if mods.ctrl and not mods.alt and not mods.shift then
        local byte = string.byte(key)
        if byte and byte >= 97 and byte <= 122 then  -- a-z
            return string.char(byte - 96)
        end
    end
    -- Special keys
    if special[key] then return special[key] end
    -- Printable single char (no ctrl/alt)
    if #key == 1 then return key end
    return nil
end

return M
