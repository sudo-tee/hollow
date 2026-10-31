package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("REPL snapshots", function()
  it("preserves idle and completion views", function()
    local env = harness.boot()
    local ui = env.hollow.ui
    ui.lua_repl.open()
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local function snapshot()
      local nodes = surface:snapshot({ width = 1000, height = 700, cell_w = 8, cell_h = 19 })
      local normalized = json.decode(json.encode(nodes))
      for _, node in ipairs(normalized) do
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      return normalized
    end
    local snapshots = { snapshot() }
    require("hollow.state").get().host_api.clipboard_read = function()
      return "hollow.config."
    end
    assert.is_true(ui.dispatch_overlay_key("v", 2))
    assert.is_true(ui.dispatch_overlay_key("tab", 0))
    snapshots[2] = snapshot()
    harness.fixture("src/lua/tests/fixtures/repl_snapshot.json", snapshots)
  end)

  it("preserves a scrolled transcript viewport", function()
    local ui = harness.boot().hollow.ui
    ui.lua_repl.open()
    require("hollow.state").get().host_api.clipboard_read = function()
      return "for i = 1, 50 do print('line-' .. i) end"
    end
    assert.is_true(ui.dispatch_overlay_key("v", 2))
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local nodes = json.decode(
      json.encode(surface:snapshot({ width = 1000, height = 700, cell_w = 10, cell_h = 20 }))
    )
    local found
    for _, node in ipairs(nodes) do
      if node.scrollbar_id and node.scrollbar_id:match("repl:output:scrollbar$") then
        found = true
      end
      for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
        if node[field] then
          node[field] = node[field]:gsub("^layout:%d+:", "test:")
        end
      end
    end
    assert.is_true(found)
    harness.fixture("src/lua/tests/fixtures/repl_scroll_snapshot.json", nodes)
  end)
end)
