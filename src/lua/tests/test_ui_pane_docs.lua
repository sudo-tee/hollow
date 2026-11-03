package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

local function example(path, heading)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local start = assert(text:find(heading, 1, true))
  return assert(text:sub(start):match("```lua\n(.-)\n```"))
end

describe("Lua pane documentation examples", function()
  local env, owners, next_id
  local function context(id)
    return {
      pane_id = id,
      cols = 40,
      rows = 10,
      width = 400,
      height = 200,
      cell_w = 10,
      cell_h = 20,
      focused = true,
    }
  end

  before_each(function()
    env, owners, next_id = harness.boot(), {}, 1000
    env.host_api.create_lua_pane = function(owner)
      next_id = next_id + 1
      owners[next_id] = owner
      return next_id
    end
    env.host_api.invalidate_lua_pane = function() end
    env.host_api.title_lua_pane = function() end
  end)

  it("runs the reference factory example and restores fresh state", function()
    assert(loadstring(example("docs/reference/lua/ui.md", "### Factories and persistence")))()
    env.get_gui_ready_handler()()
    local pane = env.hollow.ui.pane.get(next_id)
    local owner = owners[next_id]
    assert.are.equal("Build", pane.opts.title)
    assert.are.equal(0.4, owner.ratio)
    assert.is_table(owner:snapshot(context(next_id)))
    local descriptor = owner._descriptor
    pane.opts.state.count = 99
    owner:destroy()
    local restored = env.hollow.ui.pane._restore(next_id, descriptor)
    assert.is_table(restored:snapshot(context(next_id)))
    assert.are.equal(0, env.hollow.ui.pane.get(next_id).opts.state.count)
  end)

  it("runs the guide counter example with isolated component callbacks", function()
    assert(loadstring(example("docs/custom-ui.md", "### Lua panes")))()
    env.get_gui_ready_handler()()
    local a = env.hollow.ui.pane.get(next_id)
    local ao = owners[a.id]
    local b = env.hollow.ui.pane.split({ module = "counter" })
    ao:snapshot(context(a.id))
    owners[b.id]:snapshot(context(b.id))
    ao:pointer("click", a.surface.namespace .. "increment")
    assert.are.equal(1, a.opts.state.count)
    assert.are.equal(0, b.opts.state.count)
  end)
end)
