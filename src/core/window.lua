-- src/core/window.lua
-- Platform window chrome helpers.
--
-- Provides `M.apply_decorations()` which reads the `no_titlebar` config key
-- and, on Windows, strips the title bar while keeping the resize border
-- (WS_THICKFRAME) so the window still snaps, resizes, and responds to
-- Aero-snap / DWM correctly — exactly the same technique WezTerm uses.
--
-- Implementation detail:
--   Removing WS_CAPTION alone leaves a thin DWM-drawn top border (~8 px).
--   To eliminate it we also subclass the WNDPROC to handle WM_NCCALCSIZE,
--   returning zero non-client insets so the client area covers the full
--   window rect.  DwmExtendFrameIntoClientArea({-1,-1,-1,-1}) then tells
--   the compositor to collapse its own shadow/frame sheet.
--
-- On non-Windows platforms the module is a no-op.

local ffi      = require("ffi")
local bit      = require("bit")
local Config   = require("src.core.config")
local Platform = require("src.core.platform")
local M = {}

if not Platform.is_windows then
    function M.strip_titlebar() end
    function M.apply_decorations() end
    function M.begin_drag() return false end
    return M
end

-- ── FFI declarations ─────────────────────────────────────────────────────────
ffi.cdef([[
    typedef void*     HWND;
    typedef void*     HINSTANCE;
    typedef uintptr_t UINT_PTR;
    typedef intptr_t  LONG_PTR;
    typedef uint32_t  UINT;
    typedef uint32_t  DWORD;
    typedef intptr_t  LRESULT;
    typedef uintptr_t WPARAM;
    typedef intptr_t  LPARAM;

    typedef LRESULT (__stdcall *WNDPROC)(HWND, UINT, WPARAM, LPARAM);

    typedef struct { int left; int top; int right; int bottom; } RECT;
    typedef struct { int left; int top; int right; int bottom; } MARGINS;

    HWND     GetForegroundWindow(void);
    DWORD    GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
    LONG_PTR GetWindowLongPtrW(HWND hWnd, int nIndex);
    LONG_PTR SetWindowLongPtrW(HWND hWnd, int nIndex, LONG_PTR dwNewLong);
    bool     SetWindowPos(HWND hWnd, HWND hWndInsertAfter,
                          int X, int Y, int cx, int cy, UINT uFlags);
    LRESULT  DefWindowProcW(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT  CallWindowProcW(WNDPROC lpPrevWndFunc, HWND hWnd,
                             UINT msg, WPARAM wParam, LPARAM lParam);
    bool     ReleaseCapture(void);
    LRESULT  SendMessageW(HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam);
    bool     GetWindowRect(HWND hWnd, RECT* lpRect);

    /* kernel32.dll */
    DWORD GetCurrentProcessId(void);

    /* dwmapi.dll */
    int __stdcall DwmExtendFrameIntoClientArea(HWND hWnd, const MARGINS* pMarInset);
]])

-- ── Constants ────────────────────────────────────────────────────────────────
local GWL_WNDPROC   = -4
local GWL_STYLE     = -16
local WS_CAPTION    = 0x00C00000
local WS_BORDER     = 0x00800000
local WS_DLGFRAME   = 0x00400000

local SWP_NOMOVE      = 0x0002
local SWP_NOSIZE      = 0x0001
local SWP_NOZORDER    = 0x0004
local SWP_FRAMECHANGED = 0x0020

local WM_NCCALCSIZE = 0x0083
local WM_NCHITTEST  = 0x0084
local WM_NCLBUTTONDOWN = 0x00A1

-- NCHITTEST return values for resize hit-testing along the top edge
local HTCLIENT      = 1
local HTCAPTION     = 2
local HTTOP         = 12
local HTTOPLEFT     = 13
local HTTOPRIGHT    = 14

-- ── HWND resolution ──────────────────────────────────────────────────────────
local user32   = ffi.load("user32")
local kernel32 = ffi.load("kernel32")
local dwmapi   = ffi.load("dwmapi")

local function get_own_hwnd()
    local pid = kernel32.GetCurrentProcessId()
    for _ = 1, 20 do
        local hwnd = user32.GetForegroundWindow()
        if hwnd ~= nil then
            local win_pid = ffi.new("DWORD[1]")
            user32.GetWindowThreadProcessId(hwnd, win_pid)
            if win_pid[0] == pid then
                return hwnd
            end
        end
    end
    return nil
end

-- ── WNDPROC subclass ─────────────────────────────────────────────────────────
-- We keep a reference to the callback so the GC doesn't collect it.
local _orig_wndproc = nil
local _wndproc_cb   = nil

local function install_wndproc(hwnd)
    local orig_ptr = user32.GetWindowLongPtrW(hwnd, GWL_WNDPROC)
    _orig_wndproc = ffi.cast("WNDPROC", orig_ptr)

    _wndproc_cb = ffi.cast("WNDPROC", function(h, msg, wp, lp)

        if msg == WM_NCCALCSIZE and wp ~= 0 then
            -- Call the default handler first so it fills in the normal insets
            -- (sides + bottom get the standard WS_THICKFRAME resize border).
            -- Then override only the top: set it to window_top + 1 so the
            -- title bar height is gone but 1 px DWM accent border remains.
            local rects = ffi.cast("RECT*", lp)
            local window_top = rects[0].top          -- save before default clobbers
            user32.CallWindowProcW(_orig_wndproc, h, msg, wp, lp)
            rects[0].top = window_top + 1            -- 1 px top inset only
            return 0
        end

        if msg == WM_NCHITTEST then
            local result = user32.CallWindowProcW(_orig_wndproc, h, msg, wp, lp)
            -- After zeroing NCCALCSIZE the top resize band disappears because
            -- it was part of the non-client area.  Restore it: if the cursor
            -- is within RESIZE_BAND px of the top window edge, return HTTOP
            -- (or the corner variants) so drag-resize still works.
            if result == HTCLIENT then
                local RESIZE_BAND = 4  -- px, matches Windows default
                local wr = ffi.new("RECT")
                user32.GetWindowRect(h, wr)
                -- lParam screen coords: low word = x, high word = y (signed)
                local sy = bit.arshift(bit.lshift(tonumber(lp), 0), 0)
                -- extract high 16 bits as signed
                local screen_y = bit.arshift(bit.band(tonumber(lp), 0xFFFF0000), 16)
                local screen_x = bit.bor(bit.band(tonumber(lp), 0xFFFF),
                    bit.arshift(bit.band(tonumber(lp), 0x8000), 0) ~= 0
                    and -0x10000 or 0)
                _ = sy
                if screen_y >= wr.top and screen_y < wr.top + RESIZE_BAND then
                    if screen_x < wr.left + RESIZE_BAND then
                        return HTTOPLEFT
                    elseif screen_x >= wr.right - RESIZE_BAND then
                        return HTTOPRIGHT
                    else
                        return HTTOP
                    end
                end
            end
            return result
        end

        return user32.CallWindowProcW(_orig_wndproc, h, msg, wp, lp)
    end)

    user32.SetWindowLongPtrW(hwnd, GWL_WNDPROC,
        ffi.cast("LONG_PTR", _wndproc_cb))
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.strip_titlebar()
    local hwnd = get_own_hwnd()
    if not hwnd then
        print("[window] strip_titlebar: could not find own HWND")
        return
    end

    -- 1. Remove WS_CAPTION, keep WS_THICKFRAME.
    local style = user32.GetWindowLongPtrW(hwnd, GWL_STYLE)
    local new_style = bit.band(style, bit.bnot(WS_CAPTION))
    user32.SetWindowLongPtrW(hwnd, GWL_STYLE, new_style)

    -- 2. Subclass WNDPROC to swallow WM_NCCALCSIZE so DWM grants us a
    --    zero-height non-client top border.
    install_wndproc(hwnd)

    -- 3. Extend DWM frame by 1 px on top so the compositor keeps its drop
    --    shadow and the window is visually distinct from the desktop.
    --    {left, right, top, bottom} — only top matters here.
    local margins = ffi.new("MARGINS", {0, 0, 1, 0})
    dwmapi.DwmExtendFrameIntoClientArea(hwnd, margins)

    -- 4. Force a non-client repaint.
    user32.SetWindowPos(
        hwnd, nil, 0, 0, 0, 0,
        bit.bor(SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SWP_FRAMECHANGED)
    )

    print("[window] Title bar stripped (WS_THICKFRAME kept, NCCALCSIZE zeroed)")
end

function M.apply_decorations()
    if Config.get("no_titlebar") then
        M.strip_titlebar()
    end
end

function M.begin_drag()
    if not Config.get("no_titlebar") then
        return false
    end

    local hwnd = get_own_hwnd()
    if not hwnd then
        print("[window] begin_drag: could not find own HWND")
        return false
    end

    user32.ReleaseCapture()
    user32.SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0)
    return true
end

return M
