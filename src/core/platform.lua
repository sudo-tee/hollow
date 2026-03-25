-- src/core/platform.lua
-- Single source of truth for OS / environment detection.
-- Everything else imports from here instead of calling love.system.getOS() directly.

local ffi = require("ffi")
local M = {}

-- love.system may not exist yet if we're called at module-load time before
-- Love2D finishes initialising.  Fall back to env-var probing so the module
-- is safe to require early (e.g. from pane.lua → ghostty_ffi.lua → here,
-- all of which happen during the top-level require phase).
local function detect_os()
    if love and love.system and love.system.getOS then
        return love.system.getOS()
    end
    -- Fallback: Windows-specific env variables
    if os.getenv("WINDIR") or os.getenv("SystemRoot") then
        return "Windows"
    end
    -- Check for macOS/Linux via uname
    local h = io.popen("uname -s 2>/dev/null")
    if h then
        local r = h:read("*a"); h:close()
        if r:match("Darwin") then return "OS X" end
        if r:match("Linux")  then return "Linux" end
    end
    return "Linux"  -- sane default for unknown Unix
end

M.os = detect_os()  -- "Windows", "OS X", "Linux", "Android", "iOS"

M.is_windows = (M.os == "Windows")
M.is_mac     = (M.os == "OS X")
M.is_linux   = (M.os == "Linux")

-- ── WSL detection ────────────────────────────────────────────────────────────
-- Running Love2D *natively on Windows* but the user wants a WSL shell.
-- Also detect when Love2D itself is running *inside* WSL (Linux build).
--
-- WSL inside Linux: /proc/version contains "Microsoft" or "WSL"
M.is_wsl_guest = false
do
    local f = io.open("/proc/version", "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content:match("Microsoft") or content:match("WSL") then
            M.is_wsl_guest = true
        end
    end
end

-- Running the *Windows* Love2D binary but want to talk to WSL:
-- Check if wsl.exe is available on PATH.
M.has_wsl = false
if M.is_windows then
    local handle = io.popen("where wsl.exe 2>nul")
    if handle then
        local result = handle:read("*a")
        handle:close()
        M.has_wsl = (result ~= nil and result:match("wsl%.exe") ~= nil)
    end
end

-- ── Default shell resolution ──────────────────────────────────────────────────
-- Returns the best default shell for the current platform.
function M.default_shell(prefer_wsl)
    if M.is_windows then
        if prefer_wsl and M.has_wsl then
            -- Launch the WSL default distro's login shell
            return "wsl.exe"
        end
        -- Prefer PowerShell 7 → 5 → cmd
        local pwsh = os.getenv("PROGRAMFILES") or "C:\\Program Files"
        local candidates = {
            pwsh .. "\\PowerShell\\7\\pwsh.exe",
            "pwsh.exe",
            "powershell.exe",
            "cmd.exe",
        }
        for _, c in ipairs(candidates) do
            local h = io.popen("where \"" .. c .. "\" 2>nul")
            if h then
                local r = h:read("*a"); h:close()
                if r and r:match("%S") then return c end
            end
        end
        return "cmd.exe"
    elseif M.is_wsl_guest or M.is_linux or M.is_mac then
        return os.getenv("SHELL") or "/bin/sh"
    end
    return "/bin/sh"
end

-- ── DLL extraction from .love archive ────────────────────────────────────────
-- When the DLL is bundled inside the .love archive (under lib/), Love2D's
-- virtual filesystem can read it but ffi.load() needs a real OS path.
-- We copy it to the save directory once and load from there.
--
-- Call this before lib_search_paths() if you want bundled-DLL support.
-- Returns the real OS path of the extracted DLL, or nil on failure.
local DLL_NAME_WINDOWS = "ghostty-vt.dll"
local DLL_NAME_LINUX   = "ghostty-vt.so"
local DLL_NAME_MAC     = "ghostty-vt.dylib"

local function dll_name()
    if M.is_windows then return DLL_NAME_WINDOWS
    elseif M.is_mac  then return DLL_NAME_MAC
    else                   return DLL_NAME_LINUX
    end
end

-- Extract the DLL from the .love archive to Love's save directory.
-- Returns the real OS path on success, nil otherwise.
local function extract_bundled_dll()
    local name     = dll_name()
    local src_path = "lib/" .. name          -- path inside the .love archive

    if not love.filesystem.getInfo(src_path) then
        return nil  -- not bundled, nothing to extract
    end

    -- Ensure the save directory exists (love.filesystem.write needs it).
    love.filesystem.createDirectory("lib")

    local dest_vpath = "lib/" .. name        -- path inside the save dir

    -- Only re-extract if the file isn't already there.
    if not love.filesystem.getInfo(dest_vpath) then
        local data = love.filesystem.read(src_path)
        if not data then return nil end
        local ok, err = love.filesystem.write(dest_vpath, data)
        if not ok then
            print("[platform] Could not extract DLL: " .. tostring(err))
            return nil
        end
    end

    -- Convert the virtual save-dir path to a real OS path.
    local save_dir = love.filesystem.getSaveDirectory()
    if M.is_windows then
        return save_dir .. "\\" .. "lib" .. "\\" .. name
    else
        return save_dir .. "/lib/" .. name
    end
end

-- ── DLL / .so search paths ────────────────────────────────────────────────────
-- Returns an ordered list of paths to try when loading ghostty-vt.
function M.lib_search_paths()
    local name = dll_name()

    -- Try to extract from the .love archive first; prepend it if available.
    local extracted = extract_bundled_dll()

    if M.is_windows then
        -- getSourceBaseDirectory() returns forward-slash paths on Windows
        -- (e.g. "C:/Users/fbelanger/ghostty-love").  Normalise to backslashes
        -- so ffi.load() doesn't choke on mixed separators.
        local src_raw = love.filesystem.getSourceBaseDirectory() or "."
        local src = src_raw:gsub("/", "\\")

        -- love.exe path: no getExecutablePath() in Love2D, but the DLL is
        -- also copied next to love.exe by launch.sh so a bare name works too.
        local paths = {
            src .. "\\" .. name,   -- project dir (most reliable in dev)
            name,                  -- system PATH / love.exe dir (launch.sh copy)
        }
        if extracted then table.insert(paths, 1, extracted) end
        return paths
    elseif M.is_mac then
        local paths = {
            "./" .. name,
            "/usr/local/lib/" .. name,
            "/opt/homebrew/lib/" .. name,
            name,
        }
        if extracted then table.insert(paths, 1, extracted) end
        return paths
    else
        local paths = {
            "./" .. name,
            "/usr/local/lib/" .. name,
            "/usr/lib/" .. name,
            name,
        }
        if extracted then table.insert(paths, 1, extracted) end
        return paths
    end
end

-- ── Config dir ────────────────────────────────────────────────────────────────
function M.config_dir()
    if M.is_windows then
        local appdata = os.getenv("APPDATA") or os.getenv("USERPROFILE") .. "\\AppData\\Roaming"
        return appdata .. "\\ghostty-love"
    else
        local xdg = os.getenv("XDG_CONFIG_HOME")
        if xdg then return xdg .. "/ghostty-love" end
        return (os.getenv("HOME") or "~") .. "/.config/ghostty-love"
    end
end

return M
