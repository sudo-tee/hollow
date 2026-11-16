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

  local function load_row(domain)
    for _, item in ipairs(rows("session_load")) do
      if item.domain == domain then
        return item
      end
    end
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
    local load = load_row("remote")
    action("select")(load)
    harness.assert_equal(calls.closed, 0, "load row should keep the switcher open")
    harness.assert_equal(#list_calls("remote"), 1, "activating the load row should list the host")
    harness.assert_equal(load_row("remote").name, "Loading sessions…", "row shows progress")

    list_calls("remote")[1].on_complete({ success = false, error = "unreachable" })
    local failed = load_row("remote")
    harness.assert_equal(failed.name, "Sessions unavailable", "failure should be shown")
    harness.assert_equal(failed.cwd, "unreachable", "failure reason should be shown")

    action("select")(failed)
    complete_list("remote", { { id = "r1", attached = false, open = false, panes = {} } })
    harness.assert_equal(
      load_row("remote"),
      nil,
      "loaded host with sessions should drop its status row"
    )
    harness.assert_equal(rows("session")[1].session_id, "r1", "remote session should be listed")

    open_switcher()
    harness.assert_equal(
      #list_calls("remote"),
      2,
      "opening again must not reconnect a loaded SSH host"
    )
  end)

  local function remember(entries)
    env.recorded.files["/tmp/hollow-test-data/sessions.json"] =
      hollow.json.encode({ version = 1, sessions = entries })
  end

  local function remembered_rows()
    local out = {}
    for _, item in ipairs(rows("session")) do
      if item.session_remembered then
        out[#out + 1] = item
      end
    end
    return out
  end

  it("shows remembered SSH sessions without contacting the host", function()
    remember({ { domain = "remote", id = "r1", name = "api" }, { domain = "remote", id = "r2" } })
    open_switcher()
    harness.assert_equal(#list_calls("remote"), 0, "remembered rows must not list the host")
    local remembered = remembered_rows()
    harness.assert_equal(#remembered, 2, "each remembered session gets a row")
    harness.assert_equal(remembered[1].name, "api", "remembered name is shown")
    harness.assert_equal(remembered[1].session_badge, "not connected", "rows say not connected")
    harness.assert_equal(remembered[2].name, "session r2", "unnamed rows use the id")
    local all = rows("session")[1]
    harness.assert_equal(all.session_restore_all, true, "several rows offer restore all")
    harness.assert_equal(load_row("remote").name, "Load sessions", "the load row stays")
    harness.assert_equal(select_opts.group_by(all), "0:RESTORE", "restore all follows OPENED")
    harness.assert_equal(
      select_opts.group_by(remembered[1]),
      "0:RESTORE",
      "remembered rows follow OPENED"
    )
    harness.assert_equal(
      select_opts.group_by(load_row("remote")),
      "1:remote",
      "the load row stays under its domain"
    )
    harness.assert_equal(select_opts.group_label("0:RESTORE"), "RESTORE", "section is labelled")

    local restored
    hollow.term.restore_sessions = function(opts)
      restored = opts.domain
    end
    action("select")(all)
    harness.assert_equal(restored, "remote", "restore all restores that domain")
  end)

  it("reconnects a remembered session after listing its host", function()
    remember({ { domain = "remote", id = "r1" }, { domain = "remote", id = "r2" } })
    open_switcher()
    action("select")(remembered_rows()[1])
    harness.assert_equal(#list_calls("remote"), 1, "reconnecting lists the host first")
    harness.assert_equal(#calls.attach, 0, "attach waits for the list")
    harness.assert_equal(#remembered_rows(), 0, "rows hide while the host is loading")
    complete_list("remote", { { id = "r1", attached = false, open = false, panes = {} } })
    harness.assert_equal(#calls.attach, 1, "the listed session attaches")
    harness.assert_equal(calls.attach[1].id, "r1", "the chosen session attaches")
  end)

  it("asks before taking over a remembered session attached elsewhere", function()
    remember({ { domain = "remote", id = "r1" } })
    open_switcher()
    action("select")(remembered_rows()[1])
    complete_list("remote", { { id = "r1", attached = true, open = false, panes = {} } })
    harness.assert_equal(#calls.attach, 0, "take-over must not attach without asking")
    harness.assert_equal(#calls.confirm, 1, "take-over asks first")
  end)

  it("forgets a remembered session the host no longer has", function()
    remember({ { domain = "remote", id = "r1" } })
    open_switcher()
    action("select")(remembered_rows()[1])
    complete_list("remote", {})
    harness.assert_equal(#calls.attach, 0, "missing sessions are not attached")
    harness.assert_equal(#hollow.term.remembered_sessions(), 0, "missing sessions are forgotten")
    harness.assert_equal(
      calls.notify[#calls.notify].message,
      "Session r1 on remote has ended.",
      "the user is told it ended"
    )
  end)

  it("keeps remembered rows when the host cannot be reached", function()
    remember({ { domain = "remote", id = "r1" } })
    open_switcher()
    action("select")(remembered_rows()[1])
    list_calls("remote")[1].on_complete({ success = false, error = "unreachable" })
    harness.assert_equal(#calls.attach, 0, "an unreachable host attaches nothing")
    harness.assert_equal(#remembered_rows(), 1, "the row comes back for a retry")
    harness.assert_equal(
      calls.notify[#calls.notify].message,
      "Could not reach remote: unreachable",
      "the failure is reported"
    )
  end)

  it("retains distinct empty and all-open states", function()
    open_switcher()
    complete_list("main", {})
    harness.assert_equal(load_row("main").name, "No sessions", "empty result remains visible")
    action("select")(load_row("main"))
    complete_list("main", { { id = "s1", open = true, panes = {} } })
    harness.assert_equal(
      load_row("main").name,
      "All sessions already open",
      "open sessions are not missing"
    )
  end)

  it("times out loading and ignores late replies after an explicit retry", function()
    open_switcher()
    action("select")(load_row("remote"))
    local first = list_calls("remote")[1]
    env.recorded.now_ms = env.recorded.now_ms + 16000
    select_opts.items()
    local failed = load_row("remote")
    harness.assert_equal(failed.cwd, "Connection timed out", "loading must terminate")
    action("select")(failed)
    first.on_complete({ success = true, sessions = { { id = "stale", panes = {} } } })
    harness.assert_equal(
      load_row("remote").load_state,
      "loading",
      "old callback cannot overwrite retry"
    )
    complete_list("remote", {})
    harness.assert_equal(load_row("remote").name, "No sessions", "retry completes normally")
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

  it("creates in a captured domain from the category keyboard action and plus button", function()
    open_switcher()
    local input
    hollow.ui.input.open = function(value)
      input = value
    end
    local header = select_opts.group_item("1:remote")
    action("new")(header)
    input.on_confirm("from-keyboard")
    harness.assert_equal(calls.new[1].domain, "remote", "header action captures domain")
    select_opts.group_create("1:remote")
    input.on_confirm("from-plus")
    harness.assert_equal(calls.new[2].domain, "remote", "plus captures domain")
    harness.assert_equal(#list_calls("remote"), 0, "creation does not preemptively list SSH")
  end)
end)
