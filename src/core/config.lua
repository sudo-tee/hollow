-- src/core/config.lua
-- Loads and stores configuration. Merges built-in defaults with user config.

local Platform = require("src.core.platform")
local M = {}

local defaults = {
    shell           = nil,          -- resolved lazily via Platform.default_shell()
	font_size       = 14,
	font_path       = nil,      -- nil = use built-in monospace
	font_hinting    = "normal",
	font_filter     = "linear",
	font_embolden   = 0,
	font_supersample = 1,
    startup_present_frame = true,
    font_bold_path  = nil,
    font_italic_path = nil,
    font_bold_italic_path = nil,
    font_fallback_paths = { "fonts/SymbolsNerdFontMono-Regular.ttf" },
    tab_bar_height  = 26,
    status_bar_height = 22,
    split_gap       = 2,
    no_titlebar     = false,    -- Windows only: hide title bar, keep resize border

    -- Colours (RGBA 0-1)
    colors = {
        background    = {0.05, 0.05, 0.08, 1},
        foreground    = {0.90, 0.90, 0.90, 1},
        cursor        = {0.95, 0.75, 0.20, 1},
        selection     = {0.25, 0.45, 0.75, 0.4},
        tab_bar_bg    = {0.08, 0.08, 0.12, 1},
        tab_active    = {0.15, 0.15, 0.22, 1},
        tab_inactive  = {0.08, 0.08, 0.12, 1},
        tab_text      = {0.90, 0.90, 0.90, 1},
        status_bar_bg = {0.05, 0.05, 0.08, 1},
        status_bar_fg = {0.70, 0.70, 0.70, 1},
        split_line    = {0.20, 0.20, 0.30, 1},
        -- ANSI 16 colours
        ansi = {
            [0]  = {0.10, 0.10, 0.10, 1}, -- black
            [1]  = {0.80, 0.20, 0.20, 1}, -- red
            [2]  = {0.20, 0.75, 0.20, 1}, -- green
            [3]  = {0.80, 0.75, 0.15, 1}, -- yellow
            [4]  = {0.25, 0.45, 0.85, 1}, -- blue
            [5]  = {0.75, 0.30, 0.75, 1}, -- magenta
            [6]  = {0.25, 0.75, 0.80, 1}, -- cyan
            [7]  = {0.85, 0.85, 0.85, 1}, -- white
            -- bright variants
            [8]  = {0.40, 0.40, 0.40, 1},
            [9]  = {1.00, 0.40, 0.40, 1},
            [10] = {0.40, 1.00, 0.40, 1},
            [11] = {1.00, 1.00, 0.40, 1},
            [12] = {0.40, 0.60, 1.00, 1},
            [13] = {1.00, 0.50, 1.00, 1},
            [14] = {0.40, 1.00, 1.00, 1},
            [15] = {1.00, 1.00, 1.00, 1},
        },
    },
}

local config = {}

-- Deep copy defaults
local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = deep_copy(v) end
    return copy
end

config = deep_copy(defaults)

function M.load()
    local paths = {
        Platform.config_dir() .. (Platform.is_windows and "\\init.lua" or "/init.lua"),
        "./conf/init.lua",   -- project-local fallback for dev
    }
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            f:close()
            local ok, err = pcall(dofile, p)
            if not ok then
                io.stderr:write("[config] Error in " .. p .. ": " .. err .. "\n")
            else
                print("[config] Loaded: " .. p)
            end
            return
        end
    end
    print("[config] No user config found, using defaults.")
end

-- Run the user init script (executes after API is set up)
function M.run_user_script()
    -- Already ran in load(); kept separate so users can call API in init.lua
end

function M.get(key)
    return config[key]
end

function M.set(key, value)
    config[key] = value
end

-- Merge a table of overrides
function M.merge(overrides)
    for k, v in pairs(overrides) do
        config[k] = v
    end
end

return M
