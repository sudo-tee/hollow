-- src/core/pty.lua
-- Platform PTY abstraction.
--
--   Linux / macOS / WSL-guest  →  POSIX forkpty via FFI
--   Windows (native shell)     →  Windows ConPTY (CreatePseudoConsole) via FFI
--   Windows + WSL shell        →  ConPTY wrapping  wsl.exe  (WSL bridge)
--
-- All three expose the same interface:
--   pty = M.spawn(cmd, cols, rows, opts)
--   pty:read()          → string | nil   (non-blocking)
--   pty:write_str(s)
--   pty:resize(cols, rows)
--   pty:close()

local ffi      = require("ffi")
local bit      = require("bit")
local Platform = require("src.core.platform")

local M = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- POSIX  (Linux, macOS, WSL-guest)
-- ═══════════════════════════════════════════════════════════════════════════
if not Platform.is_windows then

    ffi.cdef[[
        typedef int pid_t;
        typedef unsigned short uint16_t;
        typedef long           ssize_t;
        typedef unsigned long  size_t;

        struct winsize {
            uint16_t ws_row, ws_col, ws_xpixel, ws_ypixel;
        };

        pid_t   forkpty(int *amaster, char *name,
                        void *termp, const struct winsize *winp);
        int     execve(const char *path, char *const argv[], char *const envp[]);
        ssize_t read (int fd, void *buf,       size_t count);
        ssize_t write(int fd, const void *buf, size_t count);
        int     close(int fd);
        int     fcntl(int fd, int cmd, ...);
        int     ioctl(int fd, unsigned long req, ...);
        int     kill (pid_t pid, int sig);
        void    _exit(int status);
    ]]

    -- forkpty lives in libutil on Linux, libc on macOS
    local ok_util, util_lib = pcall(ffi.load, "util")
    local clib = ok_util and util_lib or ffi.C

    local F_GETFL    = 3
    local F_SETFL    = 4
    local O_NONBLOCK = Platform.is_mac and 0x0004 or 0x0800
    local TIOCSWINSZ = Platform.is_mac and 0x80087467 or 0x5414

    function M.spawn(cmd, cols, rows, opts)
        cmd  = cmd  or Platform.default_shell()
        cols = cols or 80
        rows = rows or 24

        local ws      = ffi.new("struct winsize", {rows, cols, 0, 0})
        local amaster = ffi.new("int[1]", {-1})
        local pid     = clib.forkpty(amaster, nil, nil, ws)

        if pid == 0 then
            -- child process
            local argv = ffi.new("char*[2]")
            argv[0] = ffi.cast("char*", cmd)
            argv[1] = nil
            ffi.C.execve(cmd, argv, nil)
            ffi.C._exit(1)
        elseif pid < 0 then
            error("[pty/posix] forkpty() failed")
        end

        local fd = amaster[0]
        assert(fd >= 0, "[pty/posix] bad master fd")

        -- non-blocking reads so we don't stall the Love2D main loop
        local flags = ffi.C.fcntl(fd, F_GETFL)
        ffi.C.fcntl(fd, F_SETFL, bit.bor(flags, O_NONBLOCK))

        local self = {
            fd   = fd,
            pid  = pid,
            cols = cols,
            rows = rows,
            _buf = ffi.new("uint8_t[4096]"),
        }

        function self:read(max)
            local n = ffi.C.read(self.fd, self._buf, math.min(max or 4096, 4096))
            if n > 0 then return ffi.string(self._buf, n) end
            return nil
        end

        function self:write_str(s)
            if #s > 0 then ffi.C.write(self.fd, s, #s) end
        end

        function self:resize(c, r)
            self.cols, self.rows = c, r
            local nws = ffi.new("struct winsize", {r, c, 0, 0})
            ffi.C.ioctl(self.fd, TIOCSWINSZ, nws)
        end

        function self:close()
            ffi.C.kill(self.pid, 15) -- SIGTERM
            ffi.C.close(self.fd)
        end

        return self
    end


-- ═══════════════════════════════════════════════════════════════════════════
-- Windows  –  ConPTY (Windows 10 build 1809 / Server 2019+)
-- ═══════════════════════════════════════════════════════════════════════════
else

    ffi.cdef[[
        typedef void*          HANDLE;
        typedef void*          HPCON;
        typedef unsigned long  DWORD;
        typedef int            BOOL;
        typedef long           HRESULT;
        typedef unsigned int   UINT;
        typedef size_t         SIZE_T;
        typedef void*          LPVOID;
        typedef const void*    LPCVOID;
        typedef char*          LPSTR;
        typedef const char*    LPCSTR;
        typedef unsigned char  BYTE;

        typedef struct { short X, Y; } COORD;

        typedef struct {
            DWORD  nLength;
            LPVOID lpSecurityDescriptor;
            BOOL   bInheritHandle;
        } SECURITY_ATTRIBUTES;

        /* STARTUPINFOEXA – we only need cb + lpAttributeList */
        typedef struct {
            DWORD  cb;
            LPSTR  lpReserved;
            LPSTR  lpDesktop;
            LPSTR  lpTitle;
            DWORD  dwX, dwY, dwXSize, dwYSize;
            DWORD  dwXCountChars, dwYCountChars;
            DWORD  dwFillAttribute;
            DWORD  dwFlags;
            unsigned short wShowWindow;
            unsigned short cbReserved2;
            BYTE  *lpReserved2;
            HANDLE hStdInput, hStdOutput, hStdError;
            LPVOID lpAttributeList;
        } STARTUPINFOEXA;

        typedef struct {
            HANDLE hProcess, hThread;
            DWORD  dwProcessId, dwThreadId;
        } PROCESS_INFORMATION;

        /* ConPTY */
        HRESULT CreatePseudoConsole (COORD size,
                                     HANDLE hInput, HANDLE hOutput,
                                     DWORD dwFlags, HPCON *phPC);
        HRESULT ResizePseudoConsole (HPCON hPC, COORD size);
        void    ClosePseudoConsole  (HPCON hPC);

        /* Pipes */
        BOOL CreatePipe(HANDLE *hRead, HANDLE *hWrite,
                        SECURITY_ATTRIBUTES *sa, DWORD sz);

        BOOL PeekNamedPipe(HANDLE hPipe, LPVOID buf, DWORD bufSz,
                           DWORD *lpRead, DWORD *lpAvail, DWORD *lpLeft);

        BOOL ReadFile (HANDLE h, LPVOID buf, DWORD toRead,
                       DWORD *lpRead, LPVOID overlap);
        BOOL WriteFile(HANDLE h, LPCVOID buf, DWORD toWrite,
                       DWORD *lpWritten, LPVOID overlap);

        /* Process */
        BOOL CreateProcessA(
            LPCSTR lpApp, LPSTR lpCmd,
            SECURITY_ATTRIBUTES *lpProcAttr, SECURITY_ATTRIBUTES *lpThreadAttr,
            BOOL bInherit, DWORD dwFlags,
            LPVOID lpEnv, LPCSTR lpCurDir,
            STARTUPINFOEXA *lpSI, PROCESS_INFORMATION *lpPI);

        BOOL  TerminateProcess(HANDLE hProc, UINT uCode);
        BOOL  CloseHandle(HANDLE h);
        DWORD GetLastError(void);

        /* Thread attribute list */
        BOOL InitializeProcThreadAttributeList(LPVOID list, DWORD cnt,
                                               DWORD flags, SIZE_T *sz);
        BOOL UpdateProcThreadAttribute(LPVOID list, DWORD flags,
                                       SIZE_T attr, LPVOID val, SIZE_T cbVal,
                                       LPVOID prev, SIZE_T *lpRet);
        void DeleteProcThreadAttributeList(LPVOID list);
    ]]

    local k32 = ffi.load("kernel32")

    local S_OK                              = 0
    local EXTENDED_STARTUPINFO_PRESENT      = 0x00080000
    -- PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE:
    -- ProcThreadAttributeValue(22, Thread=FALSE, Input=TRUE, Additive=FALSE)
    -- = 22 | PROC_THREAD_ATTRIBUTE_INPUT(0x00020000) = 0x00020016
    local ATTR_PSEUDOCONSOLE                = bit.bor(22, 0x00020000)

    local function hr_ok(hr, msg)
        if hr ~= S_OK then
            error(string.format("[pty/conpty] %s HRESULT=0x%08X GLE=%d",
                msg, hr, k32.GetLastError()))
        end
    end

    local function make_pipe()
        local sa  = ffi.new("SECURITY_ATTRIBUTES")
        sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
        sa.bInheritHandle = true
        local rh, wh = ffi.new("HANDLE[1]"), ffi.new("HANDLE[1]")
        assert(k32.CreatePipe(rh, wh, sa, 0) ~= 0, "[pty/conpty] CreatePipe failed")
        return rh[0], wh[0]
    end

    function M.spawn(cmd, cols, rows, opts)
        cmd  = cmd  or Platform.default_shell(opts and opts.prefer_wsl)
        cols = cols or 80
        rows = rows or 24

        -- pipe_in:  parent writes keyboard → ConPTY reads
        -- pipe_out: ConPTY writes output   → parent reads
        local pin_r,  pin_w  = make_pipe()   -- child-read, parent-write
        local pout_r, pout_w = make_pipe()   -- parent-read, child-write

        local coord = ffi.new("COORD", {cols, rows})
        local hpc   = ffi.new("HPCON[1]")
        hr_ok(k32.CreatePseudoConsole(coord, pin_r, pout_w, 0, hpc),
              "CreatePseudoConsole")

        -- Thread attribute list
        local attr_sz = ffi.new("SIZE_T[1]", {0})
        k32.InitializeProcThreadAttributeList(nil, 1, 0, attr_sz)
        local attr_buf = ffi.new("uint8_t[?]", attr_sz[0])
        local ok1 = k32.InitializeProcThreadAttributeList(attr_buf, 1, 0, attr_sz)
        if ok1 == 0 then
            error(string.format("[pty/conpty] InitializeProcThreadAttributeList failed GLE=%d", k32.GetLastError()))
        end

        local ok2 = k32.UpdateProcThreadAttribute(attr_buf, 0, ATTR_PSEUDOCONSOLE,
               hpc[0], ffi.sizeof("HPCON"), nil, nil)
        if ok2 == 0 then
            error(string.format("[pty/conpty] UpdateProcThreadAttribute failed GLE=%d", k32.GetLastError()))
        end

        local si = ffi.new("STARTUPINFOEXA")
        si.cb              = ffi.sizeof("STARTUPINFOEXA")
        si.lpAttributeList = attr_buf

        local pi      = ffi.new("PROCESS_INFORMATION")
        local cmdline = ffi.new("char[?]", #cmd + 1, cmd)

        local ok = k32.CreateProcessA(nil, cmdline, nil, nil, false,
                        EXTENDED_STARTUPINFO_PRESENT, nil, nil, si, pi)
        assert(ok ~= 0,
            string.format("[pty/conpty] CreateProcessA('%s') GLE=%d",
                cmd, k32.GetLastError()))

        -- Parent doesn't need the child-side ends
        k32.CloseHandle(pin_r)
        k32.CloseHandle(pout_w)
        k32.DeleteProcThreadAttributeList(attr_buf)

        local self = {
            hpc      = hpc[0],
            hProcess = pi.hProcess,
            hThread  = pi.hThread,
            hRead    = pout_r,   -- parent reads output here
            hWrite   = pin_w,    -- parent writes input here
            cols     = cols,
            rows     = rows,
            _rbuf    = ffi.new("uint8_t[4096]"),
            _rd      = ffi.new("DWORD[1]"),
            _wr      = ffi.new("DWORD[1]"),
            _avail   = ffi.new("DWORD[1]"),
        }

        function self:read(max)
            self._avail[0] = 0
            if k32.PeekNamedPipe(self.hRead, nil, 0, nil,
                                  self._avail, nil) == 0 then
                return nil
            end
            local n = math.min(tonumber(self._avail[0]), max or 4096, 4096)
            if n == 0 then return nil end
            self._rd[0] = 0
            if k32.ReadFile(self.hRead, self._rbuf, n, self._rd, nil) ~= 0 then
                local got = tonumber(self._rd[0])
                if got > 0 then return ffi.string(self._rbuf, got) end
            end
            return nil
        end

        function self:write_str(s)
            if #s == 0 then return end
            local cs = ffi.new("char[?]", #s, s)
            k32.WriteFile(self.hWrite, cs, #s, self._wr, nil)
        end

        function self:resize(c, r)
            self.cols, self.rows = c, r
            k32.ResizePseudoConsole(self.hpc, ffi.new("COORD", {c, r}))
        end

        function self:close()
            k32.TerminateProcess(self.hProcess, 0)
            k32.CloseHandle(self.hProcess)
            k32.CloseHandle(self.hThread)
            k32.CloseHandle(self.hRead)
            k32.CloseHandle(self.hWrite)
            k32.ClosePseudoConsole(self.hpc)
        end

        return self
    end

end -- Windows block


-- ─────────────────────────────────────────────────────────────────────────────
-- WSL convenience wrapper  (only useful when running the Windows Love2D build)
-- Spawns  wsl.exe [--distribution DISTRO] [--exec SHELL]  through ConPTY.
-- On Linux / WSL-guest just calls M.spawn() directly.
-- ─────────────────────────────────────────────────────────────────────────────
function M.spawn_wsl(opts)
    opts = opts or {}

    if not Platform.is_windows then
        -- Running inside WSL/Linux already – plain spawn
        return M.spawn(opts.shell or nil, opts.cols, opts.rows, opts)
    end

    assert(Platform.has_wsl,
        "[pty/wsl] wsl.exe not found.\n" ..
        "Run in an elevated PowerShell:  wsl --install\n" ..
        "Then restart and try again.")

    local parts = {"wsl.exe"}
    if opts.distro then
        parts[#parts+1] = "--distribution"
        parts[#parts+1] = opts.distro
    end
    if opts.shell then
        parts[#parts+1] = "--exec"
        parts[#parts+1] = opts.shell
    end

    return M.spawn(table.concat(parts, " "), opts.cols, opts.rows, opts)
end

-- List installed WSL distros (Windows only, returns {} elsewhere)
function M.wsl_distros()
    if not Platform.is_windows then return {} end
    local h = io.popen("wsl.exe --list --quiet 2>nul")
    if not h then return {} end
    local out = h:read("*a"); h:close()
    local t = {}
    for line in out:gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        -- Strip the UTF-16 BOM that wsl --list sometimes emits
        name = name and name:gsub("^\xEF\xBB\xBF", "")
        if name and name ~= "" then t[#t+1] = name end
    end
    return t
end

return M
