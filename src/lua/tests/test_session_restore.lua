package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

local FILE = "/tmp/hollow-test-data/sessions.json"

describe("session restore", function()
  local env
  local hollow
  local restore
  local calls

  local function remembered(entries)
    env.recorded.files[FILE] = hollow.json.encode({ version = 1, sessions = entries })
  end

  local function ids()
    local out = {}
    for _, entry in ipairs(hollow.term.remembered_sessions()) do
      out[#out + 1] = entry.domain .. ":" .. entry.id
    end
    return table.concat(out, ",")
  end

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    restore = require("hollow.session_restore")
    hollow.config.set({
      default_domain = "main",
      domains = {
        main = { shell = "sh", persist = true },
        other = { shell = "sh", persist = true },
        plain = { shell = "sh" },
        off = { shell = "sh", persist = true, restore = false },
        remote = { persist = true, host = { type = "ssh", destination = "box" } },
      },
    })
    calls = { list = {}, attach = {}, new = {}, notify = {}, confirm = {} }
    hollow.term.list_sessions = function(opts)
      calls.list[#calls.list + 1] = opts
      return true
    end
    hollow.term.attach_session = function(id, opts)
      calls.attach[#calls.attach + 1] = { id = id, opts = opts }
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
  end)

  local function new_workspace(domain, id, host)
    hollow.term.workspaces = function()
      return { { domain = domain, session_id = id, session_host = host } }
    end
    hollow._emit_builtin_event("workspace:new", { workspace_index = 0 })
  end

  it("remembers sessions only in domains with restore enabled", function()
    new_workspace("main", "a", "host-1")
    new_workspace("plain", "b")
    new_workspace("off", "c")
    new_workspace("main", nil)
    new_workspace("main", "a", "host-1")
    harness.assert_equal(ids(), "main:a", "only one restorable entry should be kept")
    harness.assert_equal(hollow.term.remembered_sessions()[1].host, "host-1", "host should be kept")
  end)

  it("forgets ended sessions but keeps detached ones", function()
    new_workspace("main", "a")
    new_workspace("main", "b")
    hollow._emit_builtin_event("workspace:closed", { session_id = "a", session_ended = false })
    hollow._emit_builtin_event("workspace:closed", { session_id = "b", session_ended = true })
    harness.assert_equal(ids(), "main:a", "only the ended session should be forgotten")
  end)

  it("bounds the remembered list and drops the oldest", function()
    for index = 1, restore.max_entries + 3 do
      new_workspace("main", "s" .. index)
    end
    local entries = hollow.term.remembered_sessions()
    harness.assert_equal(#entries, restore.max_entries, "list should be bounded")
    harness.assert_equal(entries[1].id, "s4", "oldest entries should be dropped")
  end)

  it("ignores a corrupt state file", function()
    env.recorded.files[FILE] = "{not json"
    harness.assert_equal(#hollow.term.remembered_sessions(), 0, "corrupt file should read as empty")
    new_workspace("main", "a")
    harness.assert_equal(ids(), "main:a", "a corrupt file should be replaced")
  end)

  it("forgets a session after a successful kill", function()
    local kill_callback
    env.host_api.term_session_request = function(_fields, callback)
      kill_callback = callback
      return true
    end
    new_workspace("main", "a")
    local seen
    hollow.term.kill_session("a", {
      on_complete = function(result)
        seen = result.success
      end,
    })
    kill_callback({ success = true, payload = { domain = "main" } })
    harness.assert_equal(seen, true, "the caller callback should still run")
    harness.assert_equal(ids(), "", "killed session should be forgotten")
  end)

  it("reattaches local sessions at startup and forgets missing ones", function()
    remembered({
      { domain = "main", id = "live", host = "h" },
      { domain = "main", id = "gone", host = "h" },
      { domain = "main", id = "moved", host = "old" },
      { domain = "main", id = "busy", host = "h" },
    })
    harness.assert_equal(
      hollow._session_startup("main"),
      true,
      "Lua should own the default session"
    )
    harness.assert_equal(#calls.list, 1, "one list per domain")
    harness.assert_equal(calls.list[1].domain, "main", "list should target the domain")
    calls.list[1].on_complete({
      success = true,
      host = "h",
      sessions = {
        { id = "live", attached = false },
        { id = "moved", attached = false },
        { id = "busy", attached = true },
      },
    })
    harness.assert_equal(#calls.attach, 1, "only the unattached session should attach")
    harness.assert_equal(calls.attach[1].id, "live", "live session should attach")
    harness.assert_equal(calls.attach[1].opts.domain, "main", "attach should name the domain")
    harness.assert_equal(
      ids(),
      "main:live,main:moved,main:busy",
      "missing session should be forgotten"
    )
    harness.assert_equal(#calls.confirm, 1, "attached session should prompt")

    calls.attach[1].opts.on_complete({ success = true, workspace_index = 1 })
    calls.confirm[1].on_confirm(true)
    harness.assert_equal(#calls.attach, 2, "confirmation should take over")
    harness.assert_equal(calls.attach[2].id, "busy", "attached session should be taken over")
    calls.attach[2].opts.on_complete({ success = true })
    harness.assert_equal(#calls.new, 0, "restored sessions must not create a fresh one")
  end)

  it("refocuses the last active session once every restore settles", function()
    new_workspace("main", "a")
    new_workspace("main", "b")
    new_workspace("main", "a")
    hollow._emit_builtin_event("workspace:changed", { workspace_index = 0 })
    local switched = {}
    hollow.term.switch_workspace = function(index)
      switched[#switched + 1] = index
    end
    hollow._session_startup("main")
    calls.list[1].on_complete({ success = true, sessions = { { id = "a" }, { id = "b" } } })
    hollow.term.workspaces = function()
      return {
        { index = 1, domain = "main", session_id = "a" },
        { index = 2, domain = "main", session_id = "b", is_active = true },
      }
    end
    calls.attach[1].opts.on_complete({ success = true })
    hollow._emit_builtin_event("workspace:changed", { workspace_index = 1 })
    harness.assert_equal(#switched, 0, "focus waits for every attach")
    calls.attach[2].opts.on_complete({ success = true })
    harness.assert_equal(switched[1], 1, "the last active session should be refocused")
  end)

  it("creates one fresh session once nothing survives", function()
    remembered({ { domain = "main", id = "gone" }, { domain = "main", id = "stale" } })
    harness.assert_equal(
      hollow._session_startup("main"),
      true,
      "Lua should own the default session"
    )
    calls.list[1].on_complete({ success = true, sessions = { { id = "stale" } } })
    calls.attach[1].opts.on_complete({ success = false, status = "session_not_found" })
    harness.assert_equal(#calls.new, 1, "one fresh session should be created")
    harness.assert_equal(calls.new[1].domain, "main", "fresh session should use the default domain")
    harness.assert_equal(ids(), "", "missing sessions should be forgotten")
  end)

  it("creates a fresh session when the user declines a take-over", function()
    remembered({ { domain = "main", id = "busy" } })
    hollow._session_startup("main")
    calls.list[1].on_complete({ success = true, sessions = { { id = "busy", attached = true } } })
    harness.assert_equal(#calls.new, 0, "no session should be created while prompting")
    calls.confirm[1].on_confirm(false)
    harness.assert_equal(#calls.attach, 0, "declining should not attach")
    harness.assert_equal(#calls.new, 1, "declining should fall back to a fresh session")
    harness.assert_equal(ids(), "main:busy", "declined sessions stay remembered")
  end)

  it("never creates after an uncertain attach or a failed list", function()
    remembered({ { domain = "main", id = "a" } })
    hollow._session_startup("main")
    calls.list[1].on_complete({ success = true, sessions = { { id = "a" } } })
    calls.attach[1].opts.on_complete({
      success = false,
      status = "session_open_failed",
      outcome = "uncertain",
    })
    harness.assert_equal(#calls.new, 0, "uncertain attach must not create")

    env = harness.boot()
    hollow = env.hollow
    hollow.config.set({ default_domain = "main", domains = { main = { persist = true } } })
    local lists, created, notices = {}, 0, 0
    hollow.term.list_sessions = function(opts)
      lists[#lists + 1] = opts
      return true
    end
    hollow.term.new_workspace = function()
      created = created + 1
    end
    hollow.ui.notify.show = function()
      notices = notices + 1
    end
    remembered({ { domain = "main", id = "a" } })
    hollow._session_startup("main")
    lists[1].on_complete({ success = false, status = "session_query_failed" })
    harness.assert_equal(created, 0, "failed list must not create")
    harness.assert_equal(notices, 1, "failed list should warn")
    harness.assert_equal(ids(), "main:a", "unreachable sessions stay remembered")
  end)

  it("leaves the default session to the app without remembered entries", function()
    remembered({ { domain = "other", id = "x" } })
    harness.assert_equal(hollow._session_startup("main"), false, "app should create the default")
    calls.list[1].on_complete({ success = true, sessions = {} })
    harness.assert_equal(#calls.new, 0, "extra domains never create")
  end)

  it("offers remote sessions without contacting them at startup", function()
    remembered({ { domain = "remote", id = "r1" }, { domain = "remote", id = "r2" } })
    harness.assert_equal(hollow._session_startup("main"), false, "remote entries never own startup")
    harness.assert_equal(#calls.list, 0, "remote hosts must not be contacted at startup")
    env.flush_deferred()
    harness.assert_equal(#calls.notify, 1, "a restore notice should be shown")
    harness.assert_equal(
      calls.notify[1].opts.action.label,
      "Restore",
      "notice should offer restore"
    )
    calls.notify[1].opts.action.fn()
    harness.assert_equal(#calls.list, 1, "restore should list the remote domain")
    calls.list[1].on_complete({ success = true, sessions = { { id = "r1" }, { id = "r2" } } })
    harness.assert_equal(#calls.attach, 2, "remote sessions should attach on demand")
    harness.assert_equal(#calls.new, 0, "explicit restore never creates")
  end)
end)
