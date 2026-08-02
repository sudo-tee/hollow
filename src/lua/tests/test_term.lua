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

    it("reports the created pane id", function()
      harness.assert_true(
        type(split_result.pane_id) == "number",
        "split_pane on_complete should receive the created pane id"
      )
    end)
  end)
end)
