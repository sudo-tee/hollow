-- Tasks: a docked task runner built on hollow.ui.pane.
--
-- Launch with: hollow --config /path/to/examples/lua-pane.lua
-- or dofile() it from your own config or the Lua REPL.
--
--   <leader>T  toggle the Tasks pane on the right edge (default leader: Ctrl+Space)
--   arrows     move between buttons; Tab/Shift-Tab cycle all controls
--   Enter      run/cancel the focused task, or add the typed command
--
-- Each task runs on a domain. `local` and domains without a host run on this
-- machine with hollow.process.spawn; domains with a host (WSL, SSH, containers)
-- run through hollow-agent on that host via hollow.host.for_domain. Pick the
-- domain for new commands with the @ button or by typing @ into the empty
-- input, or type `@name command`.
--
-- Commands are split on whitespace and are not passed through a shell, so
-- quoting is not supported.
local hollow = require("hollow")
local ui = hollow.ui
local c = ui.components

local LOCAL = "local"
local DEFAULT_COMMANDS = hollow.platform.is_windows
    and { "cmd /c ver", "ping -n 3 127.0.0.1", "cmd /c exit 3" }
  or { "uname -sr", "sleep 2", "false" }
-- Without cwd, local jobs inherit the app's working directory.
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

-- `@name command` targets a domain; anything else uses `domain`.
local function parse(text, domain)
  local name, command = text:match("^@(%S+)%s+(.-)%s*$")
  return { command = command or text, domain = name or domain, status = "idle" }
end

local function domain_names()
  local names = {}
  for name in pairs(hollow.config.get("domains") or {}) do
    if name ~= LOCAL then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  table.insert(names, 1, LOCAL)
  return names
end

-- Runners call done(status, output) when the task ends and return a cancel
-- function.
local function run_local(task, cwd, done)
  local job = hollow.process.spawn({
    cmd = argv(task.command),
    cwd = cwd,
    timeout_ms = 60000,
    on_complete = function(result)
      if result.canceled then
        return done("canceled")
      end
      done(
        result.code == 0 and "ok" or "failed",
        last_line(result.error or result.stdout)
          or last_line(result.stderr)
          or ("exit " .. result.code)
      )
    end,
  })
  return function()
    job:cancel()
  end
end

local function run_on_host(task, connecting, done, started)
  local exec, canceled
  local function failed(err)
    done("failed", err.message or err.code)
  end
  connecting:next(function(host)
    if canceled then
      return
    end
    started()
    exec = host:exec({ argv = argv(task.command), timeout_ms = 60000 })
    exec:next(function(result)
      done(
        result.exit_code == 0 and "ok" or "failed",
        last_line(result.stdout) or last_line(result.stderr) or ("exit " .. result.exit_code)
      )
    end, failed)
  end, failed)
  return function()
    -- The connection is shared by every task on the domain; only stop ours.
    canceled = true
    if exec then
      exec:cancel()
    end
    done("canceled")
  end
end

-- Register at config load (not in gui:ready) so config reload and workspace
-- restore can rebuild the pane. Only `args` persist; live state starts fresh.
hollow.ui.pane.register("tasks", function(args)
  -- Per-instance state: every factory call gets its own tables.
  local default_domain = hollow.config.get("default_domain") or LOCAL
  local tasks, jobs, pane_id = {}, {}, nil
  local target = default_domain
  local commands = args.commands
  if not commands then
    commands = { unpack(DEFAULT_COMMANDS) }
    if default_domain ~= LOCAL and hollow.platform.is_windows then
      commands[#commands + 1] = "@" .. default_domain .. " uname -sr"
    end
  end
  for _, command in ipairs(commands) do
    tasks[#tasks + 1] = parse(command, LOCAL)
  end
  local pick_domain
  -- Typing @ into an empty input opens the domain picker. Picking a domain
  -- clears the @; canceling keeps it so you can type `@name command`.
  local input, previous = nil, ""
  input = ui.text_input({
    initial = "",
    on_change = function(value)
      local typed_at = value == "@" and previous == ""
      previous = value
      if typed_at then
        pick_domain(function()
          input.set("", 0)
          previous = ""
        end)
      end
    end,
  })

  -- Clicks and handled keys repaint automatically; async work must invalidate.
  local function refresh()
    local pane = pane_id and ui.pane.get(pane_id)
    if pane then
      pane:invalidate()
    end
  end

  local function toggle(task)
    if jobs[task] then
      jobs[task]()
      return
    end
    local function done(status, output)
      if jobs[task] == nil then
        return
      end
      jobs[task] = nil
      task.status, task.output = status, output
      refresh()
    end
    task.output = nil
    -- Placeholder so done() accepts a result delivered before the runner returns.
    jobs[task] = true
    local cancel
    local connecting = task.domain ~= LOCAL and hollow.host.for_domain(task.domain)
    if connecting then
      task.status = connecting:status() == "pending" and "connecting" or "running"
      cancel = run_on_host(task, connecting, done, function()
        task.status = "running"
        refresh()
      end)
    else
      task.status = "running"
      cancel = run_local(task, args.cwd or HOME, done)
    end
    if jobs[task] then
      jobs[task] = cancel
    end
  end

  local function add()
    local text = input.value:match("^%s*(.-)%s*$")
    if text ~= "" then
      tasks[#tasks + 1] = parse(text, target)
      input.set("", 0)
      previous = ""
    end
  end

  function pick_domain(on_pick)
    ui.select.open({
      items = domain_names(),
      label = function(name)
        return name
      end,
      prompt = "Run new tasks on",
      actions = {
        {
          name = "use",
          desc = "use domain",
          fn = function(name)
            ui.select.close()
            if name then
              target = name
              if on_pick then
                on_pick()
              end
              refresh()
            end
          end,
        },
      },
    })
  end

  local function status_pill(task, theme)
    local bg = ({
      connecting = theme.primary_bg,
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
      for _, cancel in pairs(jobs) do
        cancel()
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
                c.row({
                  c.label(task.command),
                  c.label({ text = "@" .. task.domain, tone = "muted" }),
                }, { gap = 8 }),
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
          c.button({
            id = "domain",
            text = "@" .. target,
            appearance = "quiet",
            size = "sm",
            on_click = function()
              pick_domain()
            end,
          }),
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

hollow.keymap.set("<leader>T", function()
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
