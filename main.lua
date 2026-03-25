-- hollow: A Love2D/LuaJIT terminal emulator frontend
-- Powered by libghostty-VT for VT parsing/emulation
-- Scriptable API inspired by WezTerm

local App    = require("src.core.app")
local Config = require("src.core.config")
local API    = require("src.api.init")
local app_started = false
local startup_frame_drawn = false

local function startup_background()
    local colors = Config.get("colors") or {}
    return colors.background or { 0.05, 0.05, 0.08, 1 }
end

local function present_startup_background()
    if Config.get("startup_present_frame") == false then
        return
    end
    local bg = startup_background()
    love.graphics.setBackgroundColor(bg[1] or 0.05, bg[2] or 0.05, bg[3] or 0.08, bg[4] or 1)
    love.graphics.clear(bg[1] or 0.05, bg[2] or 0.05, bg[3] or 0.08, bg[4] or 1)
    love.graphics.present()
end

-- Bootstrap: load user config, then hand off to App
function love.load(args)
    -- Expose the scriptable API globally BEFORE loading user config,
    -- so that conf/init.lua (and ~/.config/ghostty-love/init.lua) can
    -- reference the `hollow` global freely.
    _G.hollow = API.create()

    -- Load user config from ~/.config/ghostty-love/init.lua
    Config.load()

    -- Paint a themed frame before the heavier renderer / PTY startup work so
    -- the window doesn't flash the default background on slower or HiDPI setups.
    present_startup_background()

    -- Run user init script (if any)
    Config.run_user_script()
end

function love.update(dt)
    if not app_started and startup_frame_drawn then
        App.init()
        app_started = true
    end
    local ok, err = pcall(App.update, dt)
    if not ok then
        print("[main] App.update ERROR: " .. tostring(err))
    end
end

function love.draw()
    if not app_started then
        local bg = startup_background()
        love.graphics.clear(bg[1] or 0.05, bg[2] or 0.05, bg[3] or 0.08, bg[4] or 1)
        startup_frame_drawn = true
        return
    end
    local ok, err = pcall(App.draw)
    if not ok then
        print("[main] App.draw ERROR: " .. tostring(err))
    end
end

function love.keypressed(key, scancode, isrepeat)
    if not app_started then
        return
    end
    App.keypressed(key, scancode, isrepeat)
end

function love.keyreleased(key, scancode)
    if not app_started then
        return
    end
    App.keyreleased(key, scancode)
end

function love.textinput(text)
    if not app_started then
        return
    end
    App.textinput(text)
end

function love.mousepressed(x, y, button, istouch, presses)
    if not app_started then
        return
    end
    App.mousepressed(x, y, button, istouch, presses)
end

function love.mousereleased(x, y, button)
    if not app_started then
        return
    end
    App.mousereleased(x, y, button)
end

function love.mousemoved(x, y, dx, dy)
    if not app_started then
        return
    end
    App.mousemoved(x, y, dx, dy)
end

function love.wheelmoved(x, y)
    if not app_started then
        return
    end
    App.wheelmoved(x, y)
end

function love.resize(w, h)
    if not app_started then
        return
    end
    App.resize(w, h)
end

function love.quit()
    if app_started then
        App.quit()
    end
    return false -- allow quit
end
