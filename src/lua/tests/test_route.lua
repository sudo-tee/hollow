package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("link routing", function()
  local hollow
  local recorded

  setup(function()
    local env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  it("passes link context and lets handlers perform arbitrary actions", function()
    local seen_request
    local unsubscribe = hollow.route.link(function(request)
      seen_request = request
      hollow.term.send_text("open " .. request.text .. "\r", request.pane.id)
      return { handled = true }
    end)

    local result = recorded.link_route_handler({
      url = "file:///tmp/project/main.zig:42",
      text = "src/main.zig:42",
      pane_id = 101,
      mods = 1,
      source = "quick_select",
      kind = "filename",
    })

    harness.assert_true(result.handled, "route handler should suppress default opener")
    harness.assert_equal(seen_request.url, "file:///tmp/project/main.zig:42")
    harness.assert_equal(seen_request.text, "src/main.zig:42")
    harness.assert_equal(seen_request.pane_id, 101)
    harness.assert_equal(seen_request.pane.id, 101)
    harness.assert_equal(seen_request.pane.cwd, "/tmp/project")
    harness.assert_equal(seen_request.mods, "<S>")
    harness.assert_equal(seen_request.source, "quick_select")
    harness.assert_equal(seen_request.kind, "filename")
    harness.assert_equal(recorded.send_text[1], "open src/main.zig:42\r")
    harness.assert_true(unsubscribe(), "unsubscribe should remove registered handler")
    harness.assert_equal(unsubscribe(), false, "unsubscribe should be idempotent")
  end)

  it("tries handlers in order until one rewrites target", function()
    local order = {}
    local remove_first = hollow.route.link(function()
      order[#order + 1] = "first"
      return nil
    end)
    local remove_second = hollow.route.link(function(request)
      order[#order + 1] = "second"
      if request.url:match("^jira://") then
        return { url = "https://jira.example/browse/ISSUE-42" }
      end
      return nil
    end)
    local remove_third = hollow.route.link(function()
      order[#order + 1] = "third"
      return { handled = true }
    end)

    local result = recorded.link_route_handler({
      url = "jira://ISSUE-42",
      pane_id = 101,
      mods = 0,
      source = "click",
      kind = "url",
    })

    harness.assert_equal(table.concat(order, ","), "first,second")
    harness.assert_equal(result.url, "https://jira.example/browse/ISSUE-42")

    remove_first()
    remove_second()
    order = {}
    local handled = recorded.link_route_handler({
      url = "https://example.com",
      pane_id = 101,
      mods = 0,
      source = "click",
      kind = "url",
    })
    harness.assert_equal(table.concat(order, ","), "third")
    harness.assert_true(handled.handled)
    remove_third()
  end)

  it("falls through when every handler declines", function()
    local unsubscribe = hollow.route.link(function()
      return false
    end)

    local result = recorded.link_route_handler({
      url = "https://example.com",
      pane_id = 101,
      mods = 0,
      source = "click",
      kind = "url",
    })

    harness.assert_equal(result, nil)
    unsubscribe()
  end)
end)
