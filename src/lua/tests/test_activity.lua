package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("activity center", function()
  local env, hollow, host, status

  local function emit(name, payload)
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
    local lines = {}
    for _, overlay in ipairs(hollow.ui._overlay_state() or {}) do
      if overlay.rows then
        for _, row in ipairs(overlay.rows) do
          local segments = {}
          for _, segment in ipairs(row.segments or {}) do
            segments[#segments + 1] = segment.text or ""
          end
          lines[#lines + 1] = table.concat(segments)
        end
      end
    end
    return table.concat(lines, "\n")
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

  it("copies status details with Ctrl-C and the Copy button", function()
    report("working", 42)
    hollow.ui.activity.open()
    env.get_key_handler()("v", 0)
    env.get_key_handler()("c", 2)
    assert.equals("Build\n\nBuilding project", env.recorded.clipboard)
    env.recorded.clipboard = nil
    hollow.ui._overlay_state()
    hollow.ui.dispatch_widget_event("overlay:click", { id = "activity:copy" })
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
    report("working", 10)
    assert.equals(1, #hollow.activity.running()) -- Do not duplicate a protocol-aware task.
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
    for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
      if row.id and row.id:find("activity:item:", 1, true) then
        item_rows = item_rows + 1
        local pill
        for _, segment in ipairs(row.segments) do
          if segment.text == "main" then
            pill = segment
          end
          assert.is_nil((segment.text or ""):find("/tmp/project", 1, true))
        end
        assert.is_truthy(pill)
        assert.is_truthy(pill.bg)
        local colors = require("hollow.ui.shared").workspace_colors("main")
        assert.equals(colors.bg, pill.bg)
        assert.equals(colors.fg, pill.fg)
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
    for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
      for _, segment in ipairs(row.segments or {}) do
        if segment.text == "main" then
          assert.equals("#123456", segment.bg)
          assert.equals("#fedcba", segment.fg)
          return
        end
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
    assert.is_truthy(text():find("Running", 1, true))
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
      for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
        for _, segment in ipairs(row.segments or {}) do
          if segment.id == "activity:inbox" or segment.id == "activity:history" then
            found = found + 1
            local selected = segment.id == "activity:" .. active
            assert.equals(selected and "#123456" or nil, segment.bg)
            assert.equals(selected and "#fedcba" or "#888888", segment.fg)
            assert.equals(selected, segment.bold)
            assert.equals(4, segment.radius)
            assert.same({ left = 8, right = 8, top = 3, bottom = 3 }, segment.padding)
          end
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
    assert.is_truthy(text():find("Running", 1, true))
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
