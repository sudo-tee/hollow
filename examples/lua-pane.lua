-- Tasks: a docked task runner built on hollow.ui.pane.
--
-- Launch with: hollow --config /path/to/examples/lua-pane.lua
-- or copy the factory and keybinding into your own config.
--
--   <leader>t  toggle the Tasks pane on the right edge (default leader: Ctrl+Space)
--   arrows     move between buttons; Tab/Shift-Tab cycle all controls
--   Enter      run/cancel the focused task, or add the typed command
--
-- Commands are split on whitespace and run with hollow.process.spawn; they are
-- not passed through a shell, so quoting is not supported.
local hollow = require("hollow")
local ui = hollow.ui
local c = ui.components

hollow.config.set({
  window_width = 1100,
  window_height = 720,
  default_domain = "shell",
  domains = {
    shell = { shell = hollow.platform.is_windows and "powershell.exe -NoLogo -NoExit" or "/bin/sh" },
  },
})

local DEFAULT_COMMANDS = hollow.platform.is_windows
    and { "cmd /c ver", "ping -n 3 127.0.0.1", "cmd /c exit 3" }
  or { "uname -sr", "sleep 2", "false" }
-- Without cwd, jobs inherit the app's working directory.
local HOME = os.getenv(hollow.platform.is_windows and "USERPROFILE" or "HOME")

local function argv(command)
  local parts = {}
  for part in command:gmatch("%S+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function last_line(text)
  local line
  for each in (text or ""):gmatch("[^\r\n]+") do
    line = each
  end
  return line
end

-- Register at config load (not in gui:ready) so config reload and workspace
-- restore can rebuild the pane. Only `args` persist; live state starts fresh.
hollow.ui.pane.register("tasks", function(args)
  -- Per-instance state: every factory call gets its own tables.
  local tasks, jobs, pane_id = {}, {}, nil
  for _, command in ipairs(args.commands or DEFAULT_COMMANDS) do
    tasks[#tasks + 1] = { command = command, status = "idle" }
  end
  local input = ui.text_input({ initial = "" })

  -- Clicks and handled keys repaint automatically; async work must invalidate.
  local function refresh()
    local pane = pane_id and ui.pane.get(pane_id)
    if pane then
      pane:invalidate()
    end
  end

  local function toggle(task)
    if jobs[task] then
      jobs[task]:cancel()
      return
    end
    task.status, task.output = "running", nil
    jobs[task] = hollow.process.spawn({
      cmd = argv(task.command),
      cwd = args.cwd or HOME,
      timeout_ms = 60000,
      on_complete = function(result)
        jobs[task] = nil
        if result.canceled then
          task.status = "canceled"
        else
          task.status = result.code == 0 and "ok" or "failed"
        end
        task.output = last_line(result.error or result.stdout)
          or last_line(result.stderr)
          or ("exit " .. result.code)
        refresh()
      end,
    })
  end

  local function add()
    local command = input.value:match("^%s*(.-)%s*$")
    if command ~= "" then
      tasks[#tasks + 1] = { command = command, status = "idle" }
      input.set("", 0)
    end
  end

  local function status_pill(task, theme)
    local bg = ({
      running = theme.primary_bg,
      ok = theme.selection_bg,
      failed = theme.destructive_bg,
    })[task.status]
    return c.pill({ text = task.status, bg = bg })
  end

  return {
    title = args.title or "Tasks",
    on_mount = function(ctx)
      pane_id = ctx.pane_id
    end,
    -- Release anything acquired while mounted: close, teardown and reload.
    on_unmount = function()
      for _, job in pairs(jobs) do
        job:cancel()
      end
    end,
    render = function(ctx)
      local running = 0
      for _ in pairs(jobs) do
        running = running + 1
      end
      return c.column({
        c.header({
          width = "grow",
          title = args.title or "Tasks",
          meta = running > 0 and (running .. " running") or (#tasks .. " tasks"),
        }),
        c.column(
          ui.each(tasks, function(task, index)
            return c.row({
              c.button({
                id = "run:" .. index,
                text = jobs[task] and "Cancel" or "Run",
                size = "sm",
                variant = jobs[task] and "destructive" or "primary",
                on_click = function()
                  toggle(task)
                end,
              }),
              c.column({
                c.label(task.command),
                task.output and c.label({ text = task.output, tone = "muted" }),
              }, { width = "grow" }),
              status_pill(task, ctx.theme),
              c.button({
                id = "remove:" .. index,
                text = "Remove",
                appearance = "quiet",
                size = "sm",
                disabled = jobs[task] ~= nil,
                on_click = function()
                  table.remove(tasks, index)
                end,
              }),
            }, { width = "grow", gap = 8 })
          end),
          { width = "grow", gap = 6 }
        ),
        c.row({
          -- Inputs own their arrows; Enter adds, Tab moves on.
          c.input({ id = "command", behavior = input, on_key = ui.keys(input, { enter = add }) }),
          c.button({ id = "add", text = "Add", size = "sm", on_click = add }),
        }, { width = "grow", gap = 8 }),
        c.hints({ { "Arrows", "move" }, { "Enter", "run" }, { "Tab", "next" } }),
      }, { width = "grow", height = "grow", padding = 16, gap = 12 })
    end,
  }
end)

-- Look the pane up in the current tab instead of remembering its ID, so the
-- toggle keeps working after config reload or workspace restore.
local function find_tasks_pane()
  local tab = hollow.term.current_tab()
  for _, pane in ipairs(tab and tab.panes or {}) do
    if pane.kind == "lua" and pane.module == "tasks" then
      return pane.id
    end
  end
end

local function open()
  if not find_tasks_pane() then
    ui.pane.split({ module = "tasks", edge = "right", ratio = 0.4 })
  end
end

hollow.keymap.set("<leader>t", function()
  local id = find_tasks_pane()
  local pane = id and ui.pane.get(id)
  if pane then
    pane:close()
  else
    open()
  end
end, { desc = "toggle tasks pane" })

-- gui:ready fires once per process. When this file is loaded into a running
-- window (dofile from the REPL, config reload) a tab already exists, so open
-- on the next tick instead; a reloaded pane is restored and not duplicated.
if hollow.term.current_tab() then
  hollow.defer(open)
else
  hollow.events.on("gui:ready", open)
end
