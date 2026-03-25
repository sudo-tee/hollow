-- ghostty-love: A Love2D/LuaJIT terminal emulator frontend
-- Powered by libghostty-VT for VT parsing/emulation
-- Scriptable API inspired by WezTerm

local App    = require("src.core.app")
local Config = require("src.core.config")
local API    = require("src.api.init")

-- Bootstrap: load user config, then hand off to App
function love.load(args)
    -- Expose the scriptable API globally BEFORE loading user config,
    -- so that conf/init.lua (and ~/.config/ghostty-love/init.lua) can
    -- reference the `ghostty` global freely.
    _G.ghostty = API.create()

    -- Load user config from ~/.config/ghostty-love/init.lua
    Config.load()

    -- Run user init script (if any)
    Config.run_user_script()

    -- Start the app
    App.init()
end

function love.update(dt)
    local ok, err = pcall(App.update, dt)
    if not ok then
        print("[main] App.update ERROR: " .. tostring(err))
    end
end

function love.draw()
    local ok, err = pcall(App.draw)
    if not ok then
        print("[main] App.draw ERROR: " .. tostring(err))
    end
end

function love.keypressed(key, scancode, isrepeat)
    App.keypressed(key, scancode, isrepeat)
end

function love.keyreleased(key, scancode)
    App.keyreleased(key, scancode)
end

function love.textinput(text)
    App.textinput(text)
end

function love.mousepressed(x, y, button, istouch, presses)
    App.mousepressed(x, y, button, istouch, presses)
end

function love.mousereleased(x, y, button)
    App.mousereleased(x, y, button)
end

function love.mousemoved(x, y, dx, dy)
    App.mousemoved(x, y, dx, dy)
end

function love.wheelmoved(x, y)
    App.wheelmoved(x, y)
end

function love.resize(w, h)
    App.resize(w, h)
end

function love.quit()
    App.quit()
    return false -- allow quit
end
