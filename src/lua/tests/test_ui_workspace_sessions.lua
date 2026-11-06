package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("workspace switcher sessions", function()
  local env
  local hollow
  local calls
  local select_opts

  local function pane(cwd, exited)
    return { id = 1, title = "sh", cwd = cwd, cols = 80, rows = 24, exited = exited == true }
  end

  local function open_switcher()
    hollow.ui.workspace.open_switcher()
    select_opts.on_mount()
    return select_opts
  end

  local function rows(source_name)
    local out = {}
    for _, item in ipairs(select_opts.items()) do
      if source_name == nil or item.source == source_name then
        out[#out + 1] = item
      end
    end
    return out
  end

  local function action(name)
    for _, entry in ipairs(select_opts.actions) do
      if entry.name == name then
        return entry.fn
      end
    end
    error("missing action " .. name)
  end

  local function list_calls(domain)
    local out = {}
    for _, opts in ipairs(calls.list) do
      if opts.domain == domain then
        out[#out + 1] = opts
      end
    end
    return out
  end

  local function complete_list(domain, sessions)
    local pending = list_calls(domain)
    pending[#pending].on_complete({ success = true, domain = domain, sessions = sessions })
  end

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    hollow.config.set({
      default_domain = "main",
      domains = {
        main = { shell = "sh", persist = true },
        plain = { shell = "sh" },
        remote = { persist = true, host = { type = "ssh", destination = "box" } },
      },
    })
    require("hollow.ui.workspace.sessions")._reset()
    calls = { list = {}, attach = {}, kill = {}, new = {}, notify = {}, confirm = {}, closed = 0 }
    hollow.term.list_sessions = function(opts)
      calls.list[#calls.list + 1] = opts
      return true
    end
    hollow.term.attach_session = function(id, opts)
      calls.attach[#calls.attach + 1] = { id = id, opts = opts }
      return true
    end
    hollow.term.kill_session = function(id, opts)
      calls.kill[#calls.kill + 1] = { id = id, opts = opts }
      return true
    end
    hollow.term.new_workspace = function(opts)
      calls.new[#calls.new + 1] = opts
    end
    hollow.ui.notify.show = function(message, opts)
      calls.notify[#calls.notify + 1] = { message = message, opts = opts }
    end
    hollow.ui.confirm.open = function(opts)
      calls.confirm[#calls.confirm + 1] = opts
    end
    hollow.ui.select.open = function(opts)
      select_opts = opts
    end
    hollow.ui.select.close = function()
      calls.closed = calls.closed + 1
    end
  end)

  it("lists local hosts on open and shows detached sessions", function()
    open_switcher()
    harness.assert_equal(#list_calls("main"), 1, "local persist domain should be listed")
    harness.assert_equal(#list_calls("remote"), 0, "SSH domain must not be listed on open")
    harness.assert_equal(#list_calls("plain"), 0, "non-persist domain should not be listed")

    complete_list("main", {
      {
        id = "aaaaaaaaaaaa",
        attached = false,
        open = false,
        name = "build",
        panes = { pane("/src") },
      },
      { id = "bbbb", attached = true, open = true, panes = { pane("/here") } },
      {
        id = "cccccccccccc",
        attached = false,
        open = false,
        panes = { pane("/x"), pane("/y", true) },
      },
    })
    local sessions = rows("session")
    harness.assert_equal(#sessions, 2, "sessions open in this window should be hidden")
    harness.assert_equal(sessions[1].name, "build", "named session should keep its name")
    harness.assert_equal(sessions[1].cwd, "/src", "first pane cwd should be shown")
    harness.assert_equal(sessions[1].session_badge, "1 pane", "pane count badge")
    harness.assert_equal(sessions[2].name, "session cccccccc", "unnamed session uses its id")
    harness.assert_equal(sessions[2].session_badge, "2 panes, 1 exited", "exited panes are counted")

    local loads = rows("session_load")
    harness.assert_equal(#loads, 1, "SSH domain should get a load row")
    harness.assert_equal(loads[1].domain, "remote", "load row should target the SSH domain")
  end)

  it("loads an SSH host only when its row is activated", function()
    open_switcher()
    local load = rows("session_load")[1]
    action("select")(load)
    harness.assert_equal(calls.closed, 0, "load row should keep the switcher open")
    harness.assert_equal(#list_calls("remote"), 1, "activating the load row should list the host")
    harness.assert_equal(rows("session_load")[1].name, "Loading sessions…", "row shows progress")

    list_calls("remote")[1].on_complete({ success = false, error = "unreachable" })
    local failed = rows("session_load")[1]
    harness.assert_equal(failed.name, "Sessions unavailable", "failure should be shown")
    harness.assert_equal(failed.cwd, "unreachable", "failure reason should be shown")

    action("select")(failed)
    complete_list("remote", { { id = "r1", attached = false, open = false, panes = {} } })
    harness.assert_equal(#rows("session_load"), 0, "loaded host should drop its status row")
    harness.assert_equal(rows("session")[1].session_id, "r1", "remote session should be listed")

    open_switcher()
    harness.assert_equal(#list_calls("remote"), 3, "a loaded SSH host is re-listed on next open")
  end)

  it("attaches detached sessions and drops the row on success", function()
    open_switcher()
    complete_list("main", { { id = "s1", attached = false, open = false, panes = {} } })
    action("select")(rows("session")[1])
    harness.assert_equal(calls.closed, 1, "attaching should close the switcher")
    harness.assert_equal(#calls.confirm, 0, "detached sessions attach without asking")
    harness.assert_equal(calls.attach[1].id, "s1", "attach should target the session")
    harness.assert_equal(calls.attach[1].opts.domain, "main", "attach should target its domain")
    harness.assert_equal(#rows("session"), 0, "pending attach should hide the row")

    calls.attach[1].opts.on_complete({ success = true })
    harness.assert_equal(#rows("session"), 0, "attached session should stay hidden")
  end)

  it("restores the row when an attach fails", function()
    open_switcher()
    complete_list("main", { { id = "s1", attached = false, open = false, panes = {} } })
    action("select")(rows("session")[1])
    calls.attach[1].opts.on_complete({ success = false, status = "session_open_failed" })
    harness.assert_equal(#rows("session"), 1, "failed attach should show the row again")
  end)

  it("asks before taking over a session attached elsewhere", function()
    open_switcher()
    complete_list("main", { { id = "s1", attached = true, open = false, panes = {} } })
    local item = rows("session")[1]
    harness.assert_equal(item.session_badge, "attached elsewhere", "row should be marked")
    action("select")(item)
    harness.assert_equal(#calls.attach, 0, "take-over must wait for confirmation")
    harness.assert_equal(#calls.confirm, 1, "take-over should ask first")
    calls.confirm[1].on_confirm(false)
    harness.assert_equal(#calls.attach, 0, "declining should not attach")

    action("select")(item)
    calls.confirm[2].on_confirm(true)
    harness.assert_equal(calls.attach[1].id, "s1", "confirming should attach")
  end)

  it("kills a session after confirmation and drops the row", function()
    open_switcher()
    complete_list("main", { { id = "s1", attached = false, open = false, panes = {} } })
    action("close")(rows("session")[1])
    harness.assert_equal(#calls.kill, 0, "kill must wait for confirmation")
    calls.confirm[1].on_confirm(true)
    harness.assert_equal(calls.kill[1].id, "s1", "kill should target the session")
    calls.kill[1].opts.on_complete({ success = true, domain = "main", session = "s1" })
    harness.assert_equal(#rows("session"), 0, "killed session should be dropped")
  end)

  it("reports a failed kill and re-lists the host", function()
    open_switcher()
    complete_list("main", { { id = "s1", attached = false, open = false, panes = {} } })
    action("close")(rows("session")[1])
    calls.confirm[1].on_confirm(true)
    calls.kill[1].opts.on_complete({ success = false, outcome = "uncertain", error = "timeout" })
    harness.assert_equal(#calls.notify, 1, "failed kill should notify")
    harness.assert_true(
      calls.notify[1].message:find("refresh to check", 1, true) ~= nil,
      "uncertain kill should suggest a refresh"
    )
    harness.assert_equal(#list_calls("main"), 2, "failed kill should re-list the host")
  end)

  it("refreshes hosts and creates sessions in the row's domain", function()
    open_switcher()
    complete_list("main", { { id = "s1", attached = false, open = false, panes = {} } })
    action("refresh")()
    harness.assert_equal(#list_calls("main"), 2, "refresh should re-list local hosts")
    harness.assert_equal(#list_calls("remote"), 0, "refresh must not list unloaded SSH hosts")

    complete_list("main", { { id = "s1", attached = false, open = false, panes = {} } })
    local input
    hollow.ui.input.open = function(opts)
      input = opts
    end
    action("new")(rows("session")[1])
    input.on_confirm("fresh")
    harness.assert_equal(calls.new[1].name, "fresh", "new session should use the typed name")
    harness.assert_equal(calls.new[1].domain, "main", "new session should use the row's domain")
  end)

  it("adds no rows without persist domains", function()
    hollow.config.set({
      domains = {
        main = { shell = "sh", persist = false },
        remote = { persist = false, host = { type = "ssh", destination = "box" } },
      },
    })
    open_switcher()
    harness.assert_equal(#calls.list, 0, "nothing should be listed")
    harness.assert_equal(#rows("session") + #rows("session_load"), 0, "no session rows")
    for _, entry in ipairs(select_opts.actions) do
      harness.assert_true(entry.name ~= "refresh", "refresh hint should be hidden")
    end
  end)
end)
