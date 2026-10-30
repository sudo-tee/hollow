package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("activity center", function()
  local env, hollow, host, status

  local function emit(name, payload)
    if name:match("^overlay:") and payload and payload.id and not payload.id:match("^layout:") then
      local node = clay.find(hollow.ui, ":" .. payload.id)
      if not node then
        local labels = {
          ["activity:inbox"] = "Inbox ",
          ["activity:history"] = "History",
          ["activity:copy"] = "Copy",
        }
        if labels[payload.id] then
          node = clay.label(hollow.ui, labels[payload.id])
            or clay.label(hollow.ui, labels[payload.id]:gsub("%s+$", ""))
        end
        if payload.id == "activity:copy" then
          node = node or clay.label(hollow.ui, "Copied")
        end
        local item = payload.id:match("^activity:dismiss:(.+)$")
        if item then
          for _, child in ipairs(clay.children(hollow.ui, ":activity:item:" .. item)) do
            if child.label == "×" then
              node = child
            end
          end
        end
      end
      if node then
        payload.id = node.id
      end
    end
    hollow._emit_builtin_event(name, payload or { pane_id = 101 })
  end

  local function notify(message, id)
    emit(
      "term:notification",
      { pane_id = 101, title = "Build", message = message, level = "info", id = id }
    )
  end

  local function report(state, progress)
    status[1] = {
      id = "build",
      state = state,
      app = "Compiler",
      title = "Build",
      message = "Building project",
      progress = progress,
    }
    emit("term:program_status_changed")
  end

  local function text()
    return clay.text(hollow.ui)
  end

  before_each(function()
    env = harness.boot()
    hollow, host = env.hollow, env.host_api
    status = {}
    host.get_pane_program_status = function()
      return status
    end
  end)

  it("records focused notifications in history without filling the bell", function()
    notify("finished")
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(1, #hollow.activity.list({ view = "history" }))
    assert.equals("finished", hollow.activity.list({ view = "history" })[1].message)
    assert.equals("󰂜 ", require("hollow.ui.widgets.attention").topbar_button().render().text)
  end)

  it("uses padded headers and rounded row highlights in both views", function()
    report("working", 10)
    notify("finished")
    hollow.ui.activity.open()
    local function check_header(label)
      assert.is_not_nil(clay.text_node(hollow.ui, label))
    end
    check_header("Tasks")
    env.get_key_handler()("tab", 0)
    check_header("Today")
  end)

  it("copies full notification content without acknowledging or closing", function()
    emit("window:blurred", {})
    local message = string.rep("long message ✓ ", 30) .. "\nsecond line"
    notify(message)
    hollow.ui.activity.open()
    env.get_key_handler()("y", 0)
    assert.equals("Build\n\n" .. message, env.recorded.clipboard)
    assert.equals(1, hollow.activity.summary().count)
    assert.is_truthy(text():find("Copied", 1, true))
  end)

  it("styles title, detail, and status as separate segments", function()
    emit("window:blurred", {})
    notify("all targets compiled")
    report("blocked")
    hollow.ui.activity.open()
    local theme = require("hollow.theme").resolve_widget("select")
    local function segment(value)
      return clay.text_node(hollow.ui, value)
    end
    assert.is_truthy(text():find("Build · all targets compiled", 1, true))
    assert.is_true(segment("Build").bold)
    assert.equals(theme.muted, segment("all targets compiled").fg)
    assert.equals(require("hollow.program_status").color("blocked"), segment("Blocked").fg)
  end)

  it("shows elapsed time for live work and aligns trailing columns", function()
    emit("window:blurred", {})
    notify("all targets compiled")
    report("working", 10)
    env.recorded.now_ms = env.recorded.now_ms + 125000
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Compiler · Working", 1, true))
    assert.is_truthy(text():find("2m", 1, true))
  end)

  it("colors the Inbox badge by the most severe pending item", function()
    emit("window:blurred", {})
    notify("info")
    report("blocked")
    hollow.ui.activity.open({ view = "history" })
    local badge = assert(clay.label(hollow.ui, "2"))
    assert.is_not_nil(clay.text_node(hollow.ui, "2"))
    assert.equals(require("hollow.theme").resolve_widget("select").notify_levels.warn, badge.bg)
  end)

  it("includes the count inside the active Inbox tab", function()
    emit("window:blurred", {})
    notify("info")
    hollow.ui.activity.open({ view = "inbox" })
    local tab = assert(clay.label(hollow.ui, "Inbox "))
    local badge = assert(clay.label(hollow.ui, "1"))
    assert.is_not_nil(clay.text_node(hollow.ui, "Inbox "))
    assert.equals(require("hollow.theme").resolve_widget("select").selection_bg, tab.bg)
    assert.is_not_nil(clay.text_node(hollow.ui, "1"))
    assert.equals(require("hollow.theme").resolve_widget("select").title, badge.bg)
  end)

  it("groups history under a Today section", function()
    notify("finished")
    hollow.ui.activity.open({ view = "history" })
    assert.is_truthy(text():find("Today (1)", 1, true))
    assert.is_truthy(text():find("Build · finished", 1, true))
  end)

  it("copies status details with Ctrl-C and the Copy button", function()
    report("working", 42)
    hollow.ui.activity.open()
    env.get_key_handler()("v", 0)
    env.get_key_handler()("c", 2)
    assert.equals("Build\n\nBuilding project", env.recorded.clipboard)
    env.recorded.clipboard = nil
    emit("overlay:click", { id = "activity:copy" })
    assert.equals("Build\n\nBuilding project", env.recorded.clipboard)
    assert.equals("working", hollow.activity.running()[1].state)
  end)

  it("copies history and does not duplicate matching title and message", function()
    notify("Build")
    hollow.ui.activity.open({ view = "history" })
    env.get_key_handler()("c", 2)
    assert.equals("Build", env.recorded.clipboard)
  end)

  it("reports clipboard failure without changing Inbox", function()
    emit("window:blurred", {})
    notify("message")
    host.clipboard_write = function()
      return false
    end
    hollow.ui.activity.open()
    env.get_key_handler()("y", 0)
    assert.is_truthy(text():find("Copy failed", 1, true))
    assert.equals(1, hollow.activity.summary().count)
  end)

  it("validates clipboard text and handles unavailable bridges", function()
    assert.is_true(hollow.clipboard.write(""))
    assert.equals("", env.recorded.clipboard)
    assert.is_false(hollow.clipboard.write("before\0after"))
    assert.has_error(function()
      hollow.clipboard.write({})
    end)
    host.clipboard_write = nil
    assert.is_false(hollow.clipboard.write("text"))
  end)

  it("reserves horizontal space around the serialized topbar bell", function()
    hollow.ui.topbar.configure({})
    for _, item in ipairs(hollow.ui._topbar_state().items) do
      if item.id == "attention-button" then
        assert.equals(6, item.style.padding.left)
        assert.equals(6, item.style.padding.right)
        assert.equals(6, item.style.margin.right)
        return
      end
    end
    error("missing attention button")
  end)

  for _, pending in ipairs({ false, true }) do
    it(
      "highlights the topbar bell on hover without changing its pending state: "
        .. tostring(pending),
      function()
        if pending then
          emit("window:blurred", {})
          notify("attention")
        end
        hollow.ui.topbar.configure({})
        local function button()
          for _, item in ipairs(hollow.ui._topbar_state().items) do
            if item.id == "attention-button" then
              return item
            end
          end
          error("missing attention button")
        end
        local normal = button()
        assert.is_nil(normal.style.bg)
        hollow.ui.handle_bar_node_event("topbar:hover", { id = "attention-button" })
        local hovered = button()
        assert.equals(
          require("hollow.ui.shared").resolve_theme().ui.tab_bar.hover_tab.bg,
          hovered.style.bg
        )
        assert.equals(4, hovered.style.radius)
        assert.equals(normal.text, hovered.text)
        assert.equals(normal.fg, hovered.fg)
        assert.same(normal.style.padding, hovered.style.padding)
        assert.same(normal.style.margin, hovered.style.margin)
        assert.equals(pending and 1 or 0, hollow.activity.summary().count)
        hollow.ui.handle_bar_node_event("topbar:leave", {})
        assert.is_nil(button().style.bg)
      end
    )
  end

  it("serializes overlay pill padding with box shorthands and rejects invalid sizes", function()
    local shared = require("hollow.ui.shared")
    assert.same(
      { top = 4, right = 4, bottom = 4, left = 4 },
      shared.style_to_segment("pill", { padding = 4 }).padding
    )
    assert.same(
      { top = 3, right = 8, bottom = 3, left = 8 },
      shared.style_to_segment("pill", { padding = { x = 8, y = 3 } }).padding
    )
    assert.same(
      { top = 0, right = 0, bottom = 0, left = 0 },
      shared.style_to_segment(
        "pill",
        { padding = { top = -3, right = math.huge, bottom = 0 / 0, left = "8" } }
      ).padding
    )
    assert.is_nil(shared.style_to_segment("plain", {}).padding)
  end)

  it("captures unfocused panes and an unfocused window independently", function()
    host.pane_is_focused = function()
      return false
    end
    notify("other pane")
    host.pane_is_focused = function()
      return true
    end
    emit("window:blurred", {})
    notify("other window")
    assert.equals(2, hollow.activity.summary().count)
    emit("window:focused", {})
    emit("term:pane_focused")
    assert.equals(2, hollow.activity.summary().count) -- Focus alone never dismisses.
  end)

  it("queries current native window focus, including after runtime initialization", function()
    host.window_is_focused = function()
      return false
    end
    assert.is_false(hollow.ui.is_focused())
    notify("unfocused")
    assert.equals(1, hollow.activity.summary().count)
  end)

  it("keeps inbox entries after toast expiry and closes toasts on dismissal", function()
    emit("window:blurred", {})
    hollow.ui.notify.info("short lived", { ttl = 10 })
    env.recorded.now_ms = env.recorded.now_ms + 20
    hollow.ui._overlay_state()
    assert.equals(1, hollow.activity.summary().count)
    local entry = hollow.activity.list()[1]
    assert.is_true(hollow.activity.dismiss(entry.id))
    assert.is_false(hollow.activity.dismiss(entry.id))
    assert.equals(1, #hollow.activity.list({ view = "history" }))
    hollow.ui.notify.info("still visible", { ttl = 0 })
    hollow.activity.dismiss_all()
    assert.equals(0, hollow.ui.overlay.depth())
  end)

  it("archives ID replacements and protocol close requests", function()
    emit("window:blurred", {})
    notify("old", "job")
    notify("new", "job")
    assert.equals(1, hollow.activity.summary().count)
    assert.equals(2, #hollow.activity.list({ view = "history" }))
    emit("term:notification", { pane_id = 101, id = "job", close = true })
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(2, #hollow.activity.list({ view = "history" }))
    assert.equals(0, hollow.ui.overlay.depth())
  end)

  it("groups pending bells per pane, then starts a new group after dismissal", function()
    emit("window:blurred", {})
    emit("term:bell")
    emit("term:bell")
    assert.equals(1, hollow.activity.summary().count)
    assert.equals(2, hollow.activity.list()[1].count)
    hollow.activity.dismiss_all()
    emit("term:bell")
    assert.equals(1, hollow.activity.list()[1].count)
    assert.equals(2, #hollow.activity.list({ view = "history" }))
  end)

  it("never counts working tasks or progress ticks as unread activity", function()
    emit("window:blurred", {})
    report("working", 10)
    report("working", 90)
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(0, #hollow.activity.list({ view = "history" }))
    assert.equals(90, hollow.activity.running()[1].progress)
    assert.equals("󰂜 ", require("hollow.ui.widgets.attention").topbar_button().render().text)
  end)

  it("shows shell commands when programs do not report status", function()
    hollow.htp._handle_emit("command_started", { command = "make test" }, 101, 1000)
    assert.equals("make test", hollow.activity.running()[1].title)
    assert.equals("shell_command", hollow.activity.running()[1].source)
    report("working", 10)
    assert.equals(1, #hollow.activity.running()) -- Do not duplicate a protocol-aware task.
    assert.equals("program_status", hollow.activity.running()[1].source)
  end)

  it("classifies shell builds as Tasks without changing their origin or bell count", function()
    hollow.activity.setup({ tasks = { "^zig build%f[%s%z]" } })
    hollow.htp._handle_emit("command_started", { command = "zig build test" }, 101, 1000)
    local entry = hollow.activity.list({ view = "running" })[1]
    assert.equals("shell_command", entry.source)
    assert.equals("task", entry.category)
    assert.equals("zig build test", entry.title)
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(0, #hollow.activity.list({ view = "history" }))
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Tasks (1)", 1, true))
    assert.is_truthy(text():find("zig build test · Running", 1, true))
    assert.is_nil(text():find("Commands (", 1, true))
    local badge, state, deadline =
      require("hollow.program_status").workspace_badge(hollow.term.mux_tree()[1])
    assert.is_truthy(badge)
    assert.equals("working", state)
    assert.is_number(deadline)
    hollow.htp._handle_emit("command_ended", { exit_code = 1 }, 101, 2000)
    assert.equals(0, #hollow.activity.running())
    assert.is_nil(require("hollow.program_status").workspace_badge(hollow.term.mux_tree()[1]))
    assert.is_truthy(text():find("All caught up", 1, true))
    assert.equals(0, hollow.activity.summary().count)
  end)

  it("gives ignore precedence over commands and tasks, and commands over tasks", function()
    hollow.activity.setup({
      tasks = { ".*" },
      commands = { "%-%-watch", "^nvim%f[%s%z]" },
      ignore = { "^nvim%f[%s%z]" },
    })
    for _, command in ipairs({ "nvim", "nvim file.lua" }) do
      hollow.htp._handle_emit("command_started", { command = command }, 101, 1000)
      assert.equals(0, #hollow.activity.list({ view = "running" }))
      assert.is_nil(require("hollow.program_status").workspace_badge(hollow.term.mux_tree()[1]))
    end
    hollow.ui.activity.open()
    env.get_key_handler()("slash", 0)
    for char in ("nvim"):gmatch(".") do
      env.get_key_handler()(char, 0)
    end
    assert.is_truthy(text():find("No matching activity", 1, true))
    env.get_key_handler()("escape", 0)
    hollow.htp._handle_emit("command_started", { command = "npm test -- --watch" }, 101, 2000)
    assert.equals("command", hollow.activity.running()[1].category)
    assert.is_truthy(text():find("Commands (1)", 1, true))
    assert.is_nil(require("hollow.program_status").workspace_badge(hollow.term.mux_tree()[1]))
    hollow.htp._handle_emit("command_started", { command = "npm test" }, 101, 3000)
    assert.equals("task", hollow.activity.running()[1].category)
    assert.is_truthy(text():find("Tasks (1)", 1, true))
  end)

  it("keeps explicit status authoritative even for ignored commands and after clear", function()
    hollow.activity.setup({ tasks = { ".*" }, ignore = { ".*" } })
    hollow.htp._handle_emit("command_started", { command = "nvim" }, 101, 1000)
    report("working", 20)
    assert.equals(1, #hollow.activity.running())
    assert.equals("program_status", hollow.activity.running()[1].source)
    assert.equals("task", hollow.activity.running()[1].category)
    report("done")
    assert.equals(0, #hollow.activity.running())
    status[1] = nil
    emit("term:program_status_changed")
    hollow.activity.setup({ tasks = { ".*" } })
    assert.equals(0, #hollow.activity.running())
    assert.is_nil(require("hollow.program_status").workspace_badge(hollow.term.mux_tree()[1]))
    hollow.htp._handle_emit("command_started", { command = "make" }, 101, 2000)
    assert.equals("task", hollow.activity.running()[1].category)
  end)

  it("reclassifies live commands on setup, copies rules, and resets omitted lists", function()
    hollow.htp._handle_emit("command_started", { command = "make test" }, 101, 1000)
    assert.equals("command", hollow.activity.running()[1].category)
    local opts = { tasks = { "^make%f[%s%z]" } }
    hollow.activity.setup(opts)
    opts.tasks[1] = "never"
    assert.equals("task", hollow.activity.running()[1].category)
    hollow.activity.setup({ ignore = { "^make%f[%s%z]" } })
    assert.equals(0, #hollow.activity.running())
    hollow.activity.setup()
    assert.equals("command", hollow.activity.running()[1].category)
    hollow.activity.setup({ tasks = { "^make%f[%s%z]" } })
    hollow.htp._handle_emit("command_started", { command = "makebelieve" }, 101, 2000)
    assert.equals("command", hollow.activity.running()[1].category)
  end)

  it("rejects invalid rules atomically", function()
    hollow.activity.setup({ tasks = { "^make" } })
    for _, opts in ipairs({
      false,
      "bad",
      { tasks = false },
      { tasks = "bad" },
      { tasks = { 1 } },
      { tasks = { name = "^make" } },
      { ignore = { "[" } },
    }) do
      assert.has_error(function()
        hollow.activity.setup(opts)
      end)
    end
    hollow.htp._handle_emit("command_started", { command = "make test" }, 101, 1000)
    assert.equals("task", hollow.activity.running()[1].category)
  end)

  it("collapses Commands by default and toggles its header with the mouse", function()
    hollow.htp._handle_emit("command_started", { command = "node server.js" }, 101, 1000)
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Commands (1)", 1, true))
    assert.is_nil(text():find("node server.js", 1, true))
    local header
    for _, row in ipairs(clay.nodes(hollow.ui)) do
      if row.id and row.id:find("category:commands", 1, true) then
        header = row.id
      end
    end
    assert.is_truthy(header)
    emit("overlay:click", { id = header })
    assert.is_truthy(text():find("node server.js · Running", 1, true))
    local marker = assert(clay.text_node(hollow.ui, "▸ "))
    assert.equals("▸ ", marker.text)
    assert.equals(require("hollow.theme").resolve_widget("select").muted, marker.fg)
    assert.is_nil(text():find("Command · Working", 1, true))
    assert.is_nil(env.recorded.focus_pane_by_id)
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(1, #hollow.activity.running())
    emit("overlay:click", { id = header })
    assert.is_nil(text():find("node server.js", 1, true))
    assert.equals(1, #hollow.activity.list({ view = "running" }))
  end)

  it("expands Tasks by default and lets keyboard users toggle without acting on headers", function()
    report("working", 42)
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Tasks (1)", 1, true))
    assert.is_truthy(text():find("Compiler · Working", 1, true))
    env.get_key_handler()("arrow_up", 0)
    env.get_key_handler()("space", 0)
    assert.is_nil(text():find("Compiler · Working", 1, true))
    env.get_key_handler()("v", 0)
    env.get_key_handler()("y", 0)
    env.get_key_handler()("d", 0)
    assert.is_nil(env.recorded.clipboard)
    assert.is_nil(text():find("Activity details", 1, true))
    env.get_key_handler()("enter", 0)
    assert.is_truthy(text():find("Compiler · Working", 1, true))
    assert.is_nil(env.recorded.focus_pane_by_id)
    env.get_key_handler()("t", 0)
    assert.is_nil(text():find("Compiler · Working", 1, true))
    env.get_key_handler()("r", 0)
    assert.is_truthy(text():find("Compiler · Working", 1, true))
    assert.equals("working", hollow.activity.running()[1].state)
  end)

  it("keeps Tasks and Commands independently collapsed", function()
    hollow.activity.running = function()
      return {
        {
          id = "program:101:test",
          kind = "program",
          source = "program_status",
          state = "working",
          app = "Compiler",
          title = "Task",
        },
        {
          id = "command:102",
          kind = "program",
          source = "shell_command",
          state = "working",
          title = "node server.js",
        },
      }
    end
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Compiler · Working", 1, true))
    assert.is_nil(text():find("node server.js", 1, true))
    env.get_key_handler()("c", 0)
    assert.is_truthy(text():find("node server.js · Running", 1, true))
    env.get_key_handler()("t", 0)
    assert.is_nil(text():find("Compiler · Working", 1, true))
    assert.is_truthy(text():find("node server.js · Running", 1, true))
    env.get_key_handler()("tab", 0)
    assert.is_nil(text():find("Tasks (", 1, true))
    assert.is_nil(text():find("Commands (", 1, true))
    env.get_key_handler()("tab", 0)
    assert.is_nil(text():find("Compiler · Working", 1, true))
    assert.is_truthy(text():find("node server.js · Running", 1, true))
    env.get_key_handler()("escape", 0)
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Compiler · Working", 1, true))
    assert.is_nil(text():find("node server.js", 1, true))
  end)

  it("temporarily reveals collapsed Commands in search and preserves full command copy", function()
    hollow.htp._handle_emit(
      "command_started",
      { command = "node server.js --port 3000" },
      101,
      1000
    )
    hollow.ui.activity.open()
    env.get_key_handler()("slash", 0)
    for char in ("node"):gmatch(".") do
      env.get_key_handler()(char, 0)
    end
    assert.is_truthy(text():find("node server.js --port 3000 · Running", 1, true))
    env.get_key_handler()("escape", 0)
    assert.is_nil(text():find("node server.js", 1, true))
    env.get_key_handler()("enter", 0) -- Expand Commands header, without navigating.
    env.get_key_handler()("arrow_down", 0)
    env.get_key_handler()("c", 2)
    assert.equals("node server.js --port 3000", env.recorded.clipboard)
    env.get_key_handler()("v", 0)
    assert.is_truthy(text():find("node server.js --port 3000", 1, true))
    env.get_key_handler()("escape", 0)
    hollow.htp._handle_emit("command_ended", { exit_code = 0 }, 101, 2000)
    assert.is_nil(text():find("Commands (", 1, true))
    assert.is_truthy(text():find("All caught up", 1, true))
  end)

  for _, final_state in ipairs({ "idle", "done", "error", "cleared" }) do
    it("does not resurrect shell work after program status becomes " .. final_state, function()
      hollow.htp._handle_emit("command_started", { command = "agent" }, 101, 1000)
      report("working")
      assert.equals(1, #hollow.activity.running())
      if final_state == "cleared" then
        status[1] = nil
        emit("term:program_status_changed")
      else
        report(final_state)
      end
      assert.equals(0, #hollow.activity.running())
      status[1] = nil
      emit("term:program_status_changed")
      assert.equals(0, #hollow.activity.running())
      hollow.ui.activity.open()
      assert.is_nil(text():find("Command · Working", 1, true))
      hollow.htp._handle_emit("command_started", { command = "make test" }, 101, 2000)
      assert.equals(1, #hollow.activity.running())
      assert.equals("make test", hollow.activity.running()[1].title)
    end)
  end

  it("preserves suppressed shell fallback across config reload", function()
    hollow.htp._handle_emit("command_started", { command = "agent" }, 101, 1000)
    report("working")
    status[1] = nil
    emit("term:program_status_changed")
    local activity = hollow.activity._export()
    local commands = hollow.term._export_command_states()
    env = harness.boot()
    hollow, host = env.hollow, env.host_api
    host.get_pane_program_status = function()
      return status
    end
    hollow.term._restore_command_states(commands)
    hollow.activity._restore(activity)
    emit("config:reloaded", {})
    assert.equals(0, #hollow.activity.running())
    report("working")
    assert.equals(1, #hollow.activity.running())
  end)

  it("preserves dismissed blocked state without re-alerting on unchanged reports", function()
    emit("window:blurred", {})
    report("blocked")
    local id = hollow.activity.list()[1].id
    hollow.activity.dismiss(id)
    report("blocked", 20)
    assert.equals(0, hollow.activity.summary().count)
    assert.equals("blocked", hollow.activity.running()[1].state)
    assert.equals(1, #hollow.activity.list({ view = "history" }))
    report("working")
    report("blocked")
    assert.equals(1, hollow.activity.summary().count)
    assert.equals(2, #hollow.activity.list({ view = "history" }))
  end)

  it("archives resolved requests and records completion without progress spam", function()
    emit("window:blurred", {})
    report("blocked")
    report("working")
    assert.equals(0, hollow.activity.summary().count)
    report("done")
    assert.equals(1, hollow.activity.summary().count)
    assert.equals(2, #hollow.activity.list({ view = "history" }))
    status[1] = nil
    emit("term:program_status_changed")
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(2, #hollow.activity.list({ view = "history" }))
  end)

  for _, state in ipairs({ "blocked", "done", "error" }) do
    it("archives " .. state .. " when its status is cleared", function()
      emit("window:blurred", {})
      report(state)
      status[1] = nil
      emit("term:program_status_changed")
      assert.equals(0, hollow.activity.summary().count)
      assert.equals(1, #hollow.activity.list({ view = "history" }))
      assert.is_false(hollow.activity.list({ view = "history" })[1].pending)
    end)

    it("archives " .. state .. " when the same program starts new work", function()
      emit("window:blurred", {})
      report(state)
      report("working", 10)
      assert.equals(0, hollow.activity.summary().count)
      assert.equals("working", hollow.activity.running()[1].state)
      assert.equals(state, hollow.activity.list({ view = "history" })[1].state)
    end)
  end

  it("clears only the related program entry, not other reports, notifications, or bells", function()
    emit("window:blurred", {})
    notify("independent notification")
    emit("term:bell")
    report("done")
    status[2] = { id = "other-task", state = "error", title = "Other task" }
    emit("term:program_status_changed")
    assert.equals(4, hollow.activity.summary().count)
    table.remove(status, 1)
    emit("term:program_status_changed")
    assert.equals(3, hollow.activity.summary().count)
    for _, entry in ipairs(hollow.activity.list()) do
      assert.is_not.equals("build", entry.program_id)
    end
    assert.equals(4, #hollow.activity.list({ view = "history" }))
  end)

  it("reconciles stale completion entries on config reload", function()
    emit("window:blurred", {})
    report("done")
    local snapshot = hollow.activity._export()
    snapshot.statuses[1].records.build = { state = "working" }
    status[1].state = "working"
    env = harness.boot()
    hollow, host = env.hollow, env.host_api
    host.get_pane_program_status = function()
      return status
    end
    hollow.activity._restore(snapshot)
    emit("config:reloaded", {})
    assert.equals(0, hollow.activity.summary().count)
    assert.equals(1, #hollow.activity.list({ view = "history" }))
  end)

  it("returns isolated snapshots and retains pending entries when clearing history", function()
    notify("seen")
    emit("window:blurred", {})
    notify("unseen")
    local items = hollow.activity.list()
    items[1].message = "modified"
    assert.equals("unseen", hollow.activity.list()[1].message)
    hollow.activity.clear_history()
    assert.equals(1, #hollow.activity.list({ view = "history" }))
    assert.equals(1, hollow.activity.summary().count)
  end)

  it("queries activity views with exact combined filters without acknowledgement", function()
    emit("window:blurred", {})
    notify("full notification\nsecond line")
    emit("term:bell")
    report("error")
    local entries = hollow.activity.list({
      view = "inbox",
      pane_id = 101,
      workspace = "main",
      activity_kind = "program",
      level = "error",
    })
    assert.equals(1, #entries)
    assert.equals("Building project", entries[1].message)
    assert.equals(3, hollow.activity.summary().count)
    entries[1].message = "mutated"
    assert.equals(
      "Building project",
      hollow.activity.list({ activity_kind = "program" })[1].message
    )
    assert.equals(0, #hollow.activity.list({ workspace = "missing" }))
    assert.equals(0, #hollow.activity.list({ pane_id = 999 }))
    assert.equals(0, #hollow.activity.list({ activity_kind = "notification", level = "error" }))
    hollow.activity.dismiss_all()
    assert.equals(0, #hollow.activity.list())
    assert.equals(3, #hollow.activity.list({ view = "history" }))
    report("working", 50)
    local running = hollow.activity.list({
      view = "running",
      activity_kind = "program",
      level = "info",
      pane_id = 101,
    })
    assert.equals(1, #running)
    assert.equals(50, running[1].progress)
    assert.is_false(running[1].pending)
    assert.equals(0, #hollow.activity.list({ view = "running", level = "warn" }))
    report("blocked")
    assert.equals(1, #hollow.activity.list({ view = "running", level = "warn" }))
  end)

  it("keeps pane context after closure and never navigates to a recycled pane ID", function()
    emit("window:blurred", {})
    notify("remember me")
    emit("term:pane_closed")
    assert.is_true(hollow.activity.list()[1].pane_closed)
    hollow.ui.notify.clear() -- Close the toast without erasing its history.
    hollow.ui.activity.open({ view = "history" })
    assert.is_truthy(text():find("pane closed", 1, true))
    env.get_key_handler()("enter", 0)
    assert.is_nil(env.recorded.focus_pane_by_id)
  end)

  it("uses one row per item with a workspace pill, keeping paths in details only", function()
    emit("window:blurred", {})
    emit("term:bell")
    report("working", 63)
    hollow.ui.activity.open()
    local item_rows = 0
    for _, row in ipairs(clay.nodes(hollow.ui)) do
      if
        row.id
        and row.list_item
        and row.id:find("activity:item:", 1, true)
        and not row.id:find("category:", 1, true)
      then
        item_rows = item_rows + 1
        local pill = clay.label(hollow.ui, "main")
        assert.is_truthy(pill)
        assert.is_truthy(pill.bg)
        local colors = require("hollow.ui.shared").workspace_colors("main")
        assert.equals(colors.bg, pill.bg)
        assert.equals(colors.fg, clay.text_node(hollow.ui, "main").fg)
        assert.equals(4, pill.radius)
        assert.same({ left = 8, right = 8, top = 3, bottom = 3 }, pill.padding)
      end
    end
    assert.equals(2, item_rows)
    assert.is_nil(text():find("/tmp/project", 1, true))
    assert.is_nil(text():find("Needs acknowledgement", 1, true))
    assert.is_nil(text():find("live", 1, true))
    env.get_key_handler()("v", 0)
    assert.is_truthy(text():find("/tmp/project", 1, true))
  end)

  it("uses workspace selector custom colors for activity pills", function()
    local switcher = require("hollow.ui.workspace.source").switcher_state()
    switcher.workspace_color_fn = function(name)
      assert.equals("main", name)
      return { bg = "#123456", fg = "#fedcba" }
    end
    report("working")
    hollow.ui.activity.open()
    for _, segment in ipairs(clay.nodes(hollow.ui)) do
      if segment.label == "main" then
        assert.equals("#123456", segment.bg)
        assert.equals("#fedcba", clay.text_node(hollow.ui, "main").fg)
        return
      end
    end
    error("workspace pill missing")
  end)

  for _, state in ipairs({ "working", "blocked", "done", "error" }) do
    it("shows app and " .. state .. " instead of task title, retaining details and copy", function()
      emit("window:blurred", {})
      report(state)
      status[1].title = "Notification history widget and topbar bell states"
      emit("term:program_status_changed")
      hollow.ui.activity.open()
      assert.is_truthy(text():find("Compiler · " .. state:gsub("^%l", string.upper), 1, true))
      assert.is_nil(text():find(status[1].title, 1, true))
      env.get_key_handler()("v", 0)
      assert.is_truthy(text():find(status[1].title, 1, true))
      env.get_key_handler()("y", 0)
      assert.equals(status[1].title .. "\n\nBuilding project", env.recorded.clipboard)
    end)
  end

  it("opens Inbox without acknowledging it and switches to searchable history", function()
    emit("window:blurred", {})
    notify("needle")
    report("working", 63)
    hollow.ui.activity.open()
    assert.is_truthy(text():find("Tasks", 1, true))
    assert.is_truthy(text():find("63%", 1, true))
    assert.equals(1, hollow.activity.summary().count)
    env.get_key_handler()("d", 0)
    assert.equals(0, hollow.activity.summary().count)
    assert.is_nil(text():find("needle", 1, true))
    env.get_key_handler()("tab", 0)
    assert.is_truthy(text():find("needle", 1, true))
    env.get_key_handler()("slash", 0)
    env.get_key_handler()("z", 0)
    assert.is_nil(text():find("needle", 1, true))
    env.get_key_handler()("escape", 0)
    assert.is_truthy(text():find("needle", 1, true))
  end)

  it("highlights only the active view with a filled pill across key and mouse switches", function()
    hollow.ui.activity.open({
      theme = {
        selection_bg = "#123456",
        selection_fg = "#fedcba",
        muted = "#888888",
      },
    })
    local function assert_active(active)
      local found = 0
      for _, segment in ipairs(clay.nodes(hollow.ui)) do
        if segment.label == "Inbox" or segment.label == "History" then
          found = found + 1
          local selected = segment.label:lower() == active
          assert.equals(selected and "#123456" or nil, segment.bg)
          local label = clay.text_node(hollow.ui, segment.label)
          assert.equals(selected and "#fedcba" or "#888888", label.fg)
          assert.equals(selected, label.bold == true)
          assert.equals(4, segment.radius)
          assert.same({ left = 8, right = 8, top = 3, bottom = 3 }, segment.padding)
        end
      end
      assert.equals(2, found)
    end
    assert_active("inbox")
    env.get_key_handler()("tab", 0)
    assert_active("history")
    emit("overlay:click", { id = "activity:inbox" })
    assert_active("inbox")
  end)

  it("goes to the originating pane and acknowledges only the selected entry", function()
    emit("window:blurred", {})
    notify("first")
    notify("second")
    hollow.ui.activity.open()
    text()
    env.get_key_handler()("enter", 0)
    assert.equals(101, env.recorded.focus_pane_by_id)
    assert.equals(1, hollow.activity.summary().count)
    assert.equals("first", hollow.activity.list()[1].message)
  end)

  it("does not replace an unfinished modal", function()
    hollow.ui.input.open({ prompt = "Keep", on_confirm = function() end })
    assert.is_nil(hollow.ui.activity.open())
    assert.is_truthy(text():find("Keep", 1, true))
  end)

  it("starts a fresh history in a new runtime", function()
    notify("old runtime")
    env = harness.boot()
    assert.equals(0, #env.hollow.activity.list({ view = "history" }))
  end)

  it(
    "preserves history and acknowledgement across config reload without duplicate status events",
    function()
      emit("window:blurred", {})
      report("blocked")
      hollow.activity.dismiss_all()
      notify("keep me")
      local snapshot = hollow.activity._export()
      env = harness.boot()
      hollow, host = env.hollow, env.host_api
      host.get_pane_program_status = function()
        return status
      end
      hollow.ui.notify.info("startup toast")
      hollow.activity._restore(snapshot)
      assert.equals(3, #hollow.activity.list({ view = "history" }))
      assert.equals(1, hollow.activity.summary().count)
      report("blocked")
      assert.equals(3, #hollow.activity.list({ view = "history" }))
      local startup = hollow.activity.list({ view = "history" })[1]
      assert.equals("startup toast", startup.message)
      assert.equals(startup.id, require("hollow.state").get().ui.overlay_stack[1]._activity_id)
      require("hollow.state").get().ui.overlay_stack[1].on_key("escape")
      assert.equals(1, hollow.activity.summary().count)
      assert.equals("keep me", hollow.activity.list()[1].message)
    end
  )

  it("keeps selection stable when background activity arrives", function()
    emit("window:blurred", {})
    notify("selected")
    hollow.ui.activity.open()
    text()
    notify("newer")
    text()
    env.get_key_handler()("d", 0)
    assert.equals("newer", hollow.activity.list()[1].message)
    assert.equals(1, hollow.activity.summary().count)
  end)

  it("opens wrapped, scrollable details without dismissing the notification", function()
    emit("window:blurred", {})
    local message = "first line\n" .. string.rep("long body ", 100) .. "final-marker"
    notify(message)
    hollow.ui.activity.open({ width = 60, max_height = 16 })
    text()
    env.get_key_handler()("v", 0)
    assert.is_truthy(text():find("Activity details", 1, true))
    assert.is_truthy(text():find("first line", 1, true))
    env.get_key_handler()("end", 0)
    assert.is_truthy(text():find("final-marker", 1, true))
    assert.equals(1, hollow.activity.summary().count)
    env.get_key_handler()("escape", 0)
    assert.is_truthy(text():find("Inbox", 1, true))
  end)

  it("shows a blocked task once, moving it to live work after acknowledgement", function()
    emit("window:blurred", {})
    report("blocked")
    hollow.ui.activity.open()
    local _, count = text():gsub("Compiler · Blocked", "")
    assert.equals(1, count)
    env.get_key_handler()("d", 0)
    assert.is_truthy(text():find("Tasks", 1, true))
    assert.is_truthy(text():find("Compiler · Blocked", 1, true))
    assert.equals(0, hollow.activity.summary().count)
  end)

  it("dismisses with the row button without navigating or closing the center", function()
    emit("window:blurred", {})
    notify("click dismiss")
    local id = hollow.activity.list()[1].id
    hollow.ui.activity.open()
    text()
    emit("overlay:click", { id = "activity:dismiss:" .. id })
    assert.equals(0, hollow.activity.summary().count)
    assert.is_nil(env.recorded.focus_pane_by_id)
    assert.is_truthy(text():find("All caught up", 1, true))
  end)

  it("pads and highlights the dismiss button on hover", function()
    emit("window:blurred", {})
    notify("hover dismiss")
    local id = "activity:dismiss:" .. hollow.activity.list()[1].id
    hollow.ui.activity.open({ theme = { hover_fg = "#abcdef", hover_bg = "#123456" } })
    local function button()
      return assert(clay.label(hollow.ui, "×"))
    end
    assert.same({ left = 4, right = 4, top = 0, bottom = 0 }, button().padding)
    assert.is_nil(button().bg)
    assert.equals("#123456", button().hover_bg)
    emit("overlay:hover", { id = id })
    assert.equals("#123456", button().hover_bg)
    emit("overlay:leave", { id = id })
    assert.is_nil(button().bg)
  end)

  it("bounds retained entries and never reuses IDs", function()
    local store = require("hollow.activity.store").new(2)
    store:append({ title = "one", pending = false })
    store:append({ title = "two", pending = true })
    store:append({ title = "three", pending = true })
    assert.equals(2, #store:list("history"))
    assert.equals(3, store:list("history")[1].id)
    assert.is_nil(store:find(1))
  end)
end)
