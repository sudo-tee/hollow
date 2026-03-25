# Windows & WSL Setup Guide

## Prerequisites

### 1. Love2D for Windows
Download the **64-bit** installer or zip from https://love2d.org  
Tested on Love2D 11.4 and 11.5.

### 2. libghostty-VT.dll
Build from the ghostty source tree on a Linux/WSL machine, then copy the DLL across:

```bash
# Inside WSL or a Linux VM that has Zig installed
cd ghostty
zig build libghostty -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
# Output: zig-out/lib/libghostty-VT.dll
```

Copy `libghostty-VT.dll` **next to `love.exe`** (or next to your `.love` file if
you've packaged it). That location is what `love.filesystem.getSourceBaseDirectory()`
returns on Windows, which is where the loader searches first.

### 3. ConPTY requirement
ConPTY is built into Windows 10 **build 1809** (October 2018 Update) and later,
including Windows 11. If you're on an older build, upgrade or use WSL2.

---

## Running modes

### Mode A – Native Windows shell (PowerShell / cmd)

```lua
-- conf/init.lua
ghostty.set_config({ shell = "pwsh.exe" })        -- PowerShell 7
-- ghostty.set_config({ shell = "powershell.exe" }) -- PowerShell 5
-- ghostty.set_config({ shell = "cmd.exe" })
```

Launch:
```bat
love.exe C:\path\to\ghostty-love
```

### Mode B – WSL shell (recommended for dev work)

Install WSL2 first (run in an **elevated** PowerShell):
```powershell
wsl --install          # installs Ubuntu by default
# or
wsl --install -d Debian
```

Then in your config:
```lua
-- conf/init.lua

-- Default distro, default shell:
ghostty.set_config({ shell = "wsl.exe" })

-- Specific distro + shell:
ghostty.set_config({ shell = "wsl.exe --distribution Ubuntu --exec /bin/fish" })

-- Or via the API helper:
ghostty.on("app:ready", function()
    -- list distros at startup
    for _, d in ipairs(ghostty.wsl.distros()) do
        ghostty.log("distro:", d)
    end
end)
```

The terminal will open directly into your WSL home directory with full colour,
resize, and mouse support.

### Mode C – Run Love2D *inside* WSL2 (Linux build)

If you have an X server (VcXsrv, WSLg on Windows 11) you can run the Linux
build of Love2D inside WSL2. The POSIX PTY path is used automatically.

```bash
# Inside WSL2
sudo apt install love
cd /mnt/c/Users/you/ghostty-love
love .
```

WSL2 + WSLg on Windows 11 gives you GPU-accelerated OpenGL with zero extra setup.

---

## Keyboard / Terminal notes

**ConPTY quirks to be aware of:**

- ConPTY translates Win32 VK codes into VT sequences internally. The LuaJIT key
  encoder in `keymap.lua` only needs to produce VT sequences (same as Linux).
- `Ctrl+C`, `Ctrl+Z`, `Ctrl+D` work correctly through ConPTY.
- Mouse reporting (`SET_ANY_EVENT_MOUSE`, `SGR` mode) is forwarded by ConPTY to
  the child process. The Love2D mouse handler in `app.lua` converts pixel coords
  to cell coords before sending.

**WSL-specific:**

- ConPTY + `wsl.exe` correctly sets `TERM=xterm-256color` inside the WSL shell.
- `COLORTERM=truecolor` is **not** set automatically; add it to your `.bashrc` /
  `.zshrc` if needed by your prompt or tools.
- Resize events propagate through `wsl.exe` to the inner PTY, so tmux / Neovim
  resize correctly when you drag the window.

---

## Packaging as a .love / .exe

```bat
rem Create the .love archive
cd ghostty-love
powershell Compress-Archive -Path * -DestinationPath ..\ghostty-love.zip
rename ..\ghostty-love.zip ..\ghostty-love.love

rem Fuse into a standalone exe
copy /b love.exe+ghostty-love.love ghostty-love.exe

rem Copy the DLL alongside
copy libghostty-VT.dll .
```

Distribute `ghostty-love.exe` + `libghostty-VT.dll` together (and any Love2D
runtime DLLs if you're not assuming Love2D is installed).

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `Could not load libghostty-VT` | Put `libghostty-VT.dll` next to `love.exe` |
| `CreatePseudoConsole` error | Windows build < 1809; upgrade or use WSL2 |
| `wsl.exe not found` | Run `wsl --install` in an elevated PowerShell |
| Blank terminal on WSL | Check `wsl --status`; ensure default distro is set |
| Garbled Unicode | Set `LANG=en_US.UTF-8` in your WSL shell's `.profile` |
| No colour in PowerShell | Add `$env:TERM="xterm-256color"` to your `$PROFILE` |
