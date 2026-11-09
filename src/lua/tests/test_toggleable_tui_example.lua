package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
describe("toggleable TUI example test suite", function()
  it("docks the split and toggles it by tag", function()
    local env = harness.boot()
    local h, recorded = env.hollow, env.recorded
    local bound
    local set = h.keymap.set
    h.keymap.set = function(lhs, fn, opts)
      bound = fn
      return set(lhs, fn, opts)
    end
    dofile("examples/toggleable-tui.lua")
    bound()
    env.flush_deferred()
    local call = recorded.split_pane
    assert.equals("right", call.edge)
    assert.equals("global", call.dock)
    local id = h.term.docks()[1].id
    assert.same({ "lazygit-dock" }, h.term.get_pane_tags(id))
    h.term.focus_pane_by_id(101)
    bound()
    assert.same({ id = id, visible = false }, recorded.set_pane_visible)
    bound()
    assert.same({ id = id, visible = true }, recorded.set_pane_visible)
    assert.equals(1, #recorded.split_pane_calls)
  end)
end)
