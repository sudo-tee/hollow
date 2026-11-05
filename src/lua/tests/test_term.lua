package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("term test suite", function()
  local env
  local hollow
  local recorded

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  describe("pane snapshots", function()
    it("returns the focused pane", function()
      local current_pane = hollow.term.current_pane()
      harness.assert_equal(current_pane.id, 101, "current_pane should return the focused pane")
      harness.assert_equal(#current_pane.tags, 0, "current_pane should expose pane tags")
    end)

    it("returns pane text", function()
      harness.assert_equal(
        hollow.term.get_pane_text(101),
        "line one\nline two",
        "get_pane_text should return pane text"
      )
    end)
  end)

  describe("pane tags", function()
    it("defaults to an empty list", function()
      harness.assert_equal(
        #hollow.term.get_pane_tags(101),
        0,
        "get_pane_tags should default to an empty list"
      )
    end)

    it("attaches tags to panes", function()
      hollow.term.add_pane_tag("test-runner", 101)
      harness.assert_equal(
        hollow.term.get_pane_tags(101)[1],
        "test-runner",
        "add_pane_tag should attach tags to panes"
      )
    end)

    it("deletes a single tag", function()
      hollow.term.add_pane_tag("build", 101)
      hollow.term.remove_pane_tag("build", 101)
      harness.assert_equal(
        #hollow.term.get_pane_tags(101),
        1,
        "remove_pane_tag should delete a single tag"
      )
      harness.assert_equal(
        hollow.term.pane_by_id(101).tags[1],
        "test-runner",
        "pane snapshots should include tags"
      )
    end)

    it("stores tags in the host so they are shared and survive reloads", function()
      hollow.term.set_pane_tags({ "zeta", " alpha ", "zeta" }, 101)
      assert.same({ "zeta", "alpha" }, recorded.host_tags[101], "tags are written to the host")
      recorded.host_tags[101] = { "from-cli", "beta" }
      assert.same(
        { "beta", "from-cli" },
        hollow.term.get_pane_tags(101),
        "host tags read back sorted"
      )
      hollow.term.add_pane_tag("beta", 101)
      hollow.term.remove_pane_tag("from-cli", 101)
      assert.same({ "beta" }, recorded.host_tags[101])
      hollow.term.set_pane_tags(nil, 101)
      harness.assert_equal(recorded.host_tags[101], nil, "clearing removes the host entry")
      hollow.term.add_pane_tag("test-runner", 101)
    end)
  end)

  describe("domain snapshots", function()
    it("snapshots the focused pane domain", function()
      local current_domain = hollow.term.current_domain()
      harness.assert_equal(
        current_domain.name,
        "main",
        "current_domain should snapshot the focused pane domain"
      )
      harness.assert_equal(
        current_domain.is_active,
        true,
        "current_domain should mark the active domain"
      )
    end)
  end)

  describe("workspace snapshots", function()
    it("exposes persistent session ids without changing ordinary snapshots", function()
      local old = env.host_api.get_workspace_session_id
      env.host_api.get_workspace_session_id = function(index)
        harness.assert_equal(index, 0, "session lookup uses native workspace index")
        return "session-123"
      end
      harness.assert_equal(hollow.term.current_workspace().session_id, "session-123")
      env.host_api.get_workspace_session_id = nil
      harness.assert_equal(hollow.term.current_workspace().session_id, nil)
      env.host_api.get_workspace_session_id = function()
        return nil
      end
      harness.assert_equal(hollow.term.current_workspace().session_id, nil)
      env.host_api.get_workspace_session_id = old
    end)

    it("snapshots workspace state", function()
      harness.assert_equal(
        hollow.term.current_workspace().name,
        "main",
        "current_workspace should snapshot workspace state"
      )
      harness.assert_equal(
        hollow.term.current_workspace().domain,
        "main",
        "current_workspace should expose its active domain"
      )
    end)

    it("forwards workspace ids when closing a workspace", function()
      hollow.term.close_workspace(41)
      harness.assert_equal(
        recorded.close_workspace,
        41,
        "close_workspace should forward workspace ids"
      )
    end)

    it("allows closing the active workspace", function()
      hollow.term.close_workspace()
      harness.assert_equal(
        recorded.close_workspace,
        nil,
        "close_workspace should allow closing the active workspace"
      )
    end)
  end)

  describe("process helpers", function()
    it("infers the current domain for run_domain_process", function()
      local process_result = hollow.term.run_domain_process({ "echo", "ok" })
      harness.assert_equal(
        process_result.domain,
        "main",
        "run_domain_process should infer the current domain"
      )
      harness.assert_equal(
        recorded.domain_process.args[1],
        "echo",
        "run_domain_process should pass through arguments"
      )
    end)

    it("forwards opts to run_child_process", function()
      hollow.process.run_child_process({ "echo", "ok" }, { hide_window = true })
      harness.assert_equal(
        recorded.child_process.opts.hide_window,
        true,
        "run_child_process should forward opts"
      )
    end)

    it("forwards opts to run_domain_process", function()
      hollow.term.run_domain_process({ "echo", "ok" }, "main", { hide_window = true })
      harness.assert_equal(
        recorded.domain_process.opts.hide_window,
        true,
        "run_domain_process should forward opts"
      )
    end)
  end)

  describe("pane visibility", function()
    it("forwards visibility without closing the pane", function()
      local previous = env.host_api.set_pane_visible
      env.host_api.set_pane_visible = function(id, visible)
        recorded.visibility = { id = id, visible = visible }
      end
      hollow.term.set_pane_visible(101, false)
      harness.assert_equal(
        recorded.visibility.id,
        101,
        "visibility should target the existing pane"
      )
      harness.assert_equal(recorded.visibility.visible, false, "visibility should be forwarded")
      hollow.term.set_pane_visible(101, true)
      harness.assert_equal(recorded.visibility.visible, true, "show should be forwarded")
      env.host_api.set_pane_visible = previous
    end)

    it("rejects malformed visibility arguments", function()
      harness.assert_true(not pcall(hollow.term.set_pane_visible, "101", false))
      harness.assert_true(not pcall(hollow.term.set_pane_visible, 101, "false"))
      harness.assert_true(not pcall(hollow.term.set_pane_visible, -1, false))
      harness.assert_true(not pcall(hollow.term.set_pane_visible, 101.5, false))
      harness.assert_true(not pcall(hollow.term.set_pane_visible, 0 / 0, false))
      harness.assert_true(not pcall(hollow.term.set_pane_visible, math.huge, false))
    end)
  end)

  describe("pane docks", function()
    it("docks, lists, and undocks panes", function()
      hollow.term.dock_pane(101, { edge = "right" })
      harness.assert_equal(recorded.dock_pane.id, 101, "dock targets the pane")
      harness.assert_equal(recorded.dock_pane.edge, "right", "dock forwards the edge")
      harness.assert_equal(recorded.dock_pane.scope, "global", "scope defaults to global")
      harness.assert_equal(recorded.dock_pane.ratio, 0.3, "ratio defaults to 0.3")
      local docks = hollow.term.docks()
      harness.assert_equal(#docks, 1, "docks lists the docked pane")
      harness.assert_equal(docks[1].id, 101, "docks returns pane snapshots")
      harness.assert_equal(docks[1].dock.edge, "right", "snapshot reports the dock edge")
      harness.assert_equal(
        hollow.term.pane_by_id(101).dock.scope,
        "global",
        "get_pane reports dock"
      )
      hollow.term.undock_pane(101)
      harness.assert_equal(recorded.undock_pane, 101, "undock targets the pane")
      harness.assert_equal(#hollow.term.docks(), 0, "undocked panes leave the dock list")
      harness.assert_equal(hollow.term.pane_by_id(101).dock, nil, "undocked panes have no dock")
    end)

    it("forwards scope and ratio and rejects bad arguments", function()
      hollow.term.dock_pane(101, { edge = "top", scope = "workspace", ratio = 0.4 })
      harness.assert_equal(recorded.dock_pane.scope, "workspace", "scope is forwarded")
      harness.assert_equal(recorded.dock_pane.ratio, 0.4, "ratio is forwarded")
      hollow.term.undock_pane(101)
      harness.assert_true(not pcall(hollow.term.dock_pane, 101))
      harness.assert_true(not pcall(hollow.term.dock_pane, 101, { edge = "diagonal" }))
      harness.assert_true(not pcall(hollow.term.dock_pane, 101, { edge = "left", scope = "tab" }))
      harness.assert_true(not pcall(hollow.term.dock_pane, 101, { edge = "left", ratio = 1 }))
      harness.assert_true(not pcall(hollow.term.dock_pane, "101", { edge = "left" }))
      harness.assert_true(not pcall(hollow.term.undock_pane, -1))
    end)

    it("split_pane forwards dock with an edge", function()
      hollow.term.split_pane({ edge = "bottom", dock = "workspace", command = "htop" })
      harness.assert_equal(recorded.split_pane.dock, "workspace", "dock should be forwarded")
      harness.assert_true(not pcall(hollow.term.split_pane, { dock = "global" }))
      harness.assert_true(not pcall(hollow.term.split_pane, { edge = "left", dock = "tab" }))
    end)
  end)

  describe("attach_session", function()
    local requests
    local old_attach

    before_each(function()
      requests = {}
      old_attach = env.host_api.attach_session
      env.host_api.attach_session = function(opts)
        requests[#requests + 1] = opts
      end
    end)

    after_each(function()
      env.host_api.attach_session = old_attach
    end)

    it("copies request fields and dispatches completion unchanged", function()
      local result
      local opts = {
        domain = "guest",
        name = "restored",
        session_id = "ignored",
        on_complete = function(value)
          result = value
        end,
      }
      hollow.term.attach_session("session-123", opts)
      harness.assert_true(requests[1] ~= opts)
      harness.assert_equal(opts.session_id, "ignored")
      harness.assert_equal(requests[1].session_id, "session-123")
      harness.assert_equal(requests[1].domain, "guest")
      harness.assert_equal(requests[1].name, "restored")
      harness.assert_equal(result, nil)
      local completion = { success = true, workspace_index = 2 }
      requests[1].on_complete(completion)
      harness.assert_equal(result, completion)
      requests[1].on_complete({ success = false })
      harness.assert_equal(result.success, false)
    end)

    it("accepts omitted options and the maximum id length", function()
      hollow.term.attach_session(string.rep("s", 128))
      harness.assert_equal(requests[1].session_id, string.rep("s", 128))
      harness.assert_equal(requests[1].domain, nil)
      harness.assert_equal(requests[1].on_complete, nil)
    end)

    it("rejects invalid ids before native dispatch", function()
      for _, id in ipairs({ false, 1, {}, "", "bad\0id", string.rep("s", 129) }) do
        harness.assert_equal(pcall(hollow.term.attach_session, id), false)
      end
      harness.assert_equal(pcall(hollow.term.attach_session), false)
      harness.assert_equal(#requests, 0)
    end)

    it("rejects invalid options before native dispatch", function()
      for _, opts in ipairs({
        false,
        1,
        "guest",
        { domain = false },
        { name = 1 },
        { on_complete = true },
      }) do
        harness.assert_equal(pcall(hollow.term.attach_session, "session-123", opts), false)
      end
      harness.assert_equal(#requests, 0)
    end)
  end)

  describe("split_pane", function()
    local split_result = nil

    it("calls on_complete with a success result", function()
      hollow.term.split_pane({
        direction = "vertical",
        on_complete = function(result)
          split_result = result
        end,
      })
      harness.assert_true(
        split_result ~= nil and split_result.success == true,
        "split_pane on_complete should receive a success result"
      )
    end)

    it("accepts PTY edge placement and rejects incompatible floating mode", function()
      hollow.term.split_pane({
        edge = "right",
        ratio = 0.3,
        command = "lazygit",
        command_mode = "spawn",
      })
      harness.assert_equal(recorded.split_pane.edge, "right", "edge should be forwarded")
      harness.assert_true(not pcall(hollow.term.split_pane, { edge = "right", floating = true }))
      harness.assert_true(not pcall(hollow.term.split_pane, { edge = "diagonal" }))
    end)

    it("reports the created pane id", function()
      harness.assert_true(
        type(split_result.pane_id) == "number",
        "split_pane on_complete should receive the created pane id"
      )
    end)

    it("tags the new pane before on_complete runs", function()
      local seen
      hollow.term.split_pane({
        tags = { "build", " logs " },
        on_complete = function(result)
          seen = hollow.term.get_pane_tags(result.pane_id)
        end,
      })
      harness.assert_equal(recorded.split_pane.tags, nil, "tags are not forwarded to the host")
      assert.same({ "build", "logs" }, seen)

      local single
      hollow.term.split_pane({ tag = "lazygit" })
      single = hollow.term.get_pane_tags(hollow.term.current_pane().id)
      assert.same({ "lazygit" }, single)
    end)

    it("rejects invalid tag options", function()
      harness.assert_true(not pcall(hollow.term.split_pane, { tag = "a", tags = { "b" } }))
      harness.assert_true(not pcall(hollow.term.split_pane, { tags = "a" }))
      harness.assert_true(not pcall(hollow.term.split_pane, { tags = { "" } }))
      harness.assert_true(not pcall(hollow.term.split_pane, { tag = 3 }))
    end)
  end)
end)
