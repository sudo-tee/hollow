package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("empty state snapshots", function()
  it("preserves empty select, mux, and activity views", function()
    local hollow = harness.boot().hollow
    local ui = hollow.ui
    local stack = require("hollow.state").get().ui.overlay_stack
    local ctx = { width = 800, height = 600, cell_w = 8, cell_h = 19 }
    local function snapshot()
      local nodes = json.decode(json.encode(stack[#stack]._layout_surface:snapshot(ctx)))
      for _, node in ipairs(nodes) do
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      return nodes
    end
    ui.select.open({ items = {} })
    local snapshots = { snapshot() }
    ui.overlay.clear()
    ui.mux_navigator.open()
    ui.dispatch_overlay_key("slash", 0)
    for _ = 1, 3 do
      ui.dispatch_overlay_key("z", 0)
    end
    snapshots[2] = snapshot()
    ui.overlay.clear()
    hollow.activity.list = function()
      return {}
    end
    hollow.activity.running = function()
      return {}
    end
    hollow.activity.summary = function()
      return { count = 0 }
    end
    ui.activity.open()
    snapshots[3] = snapshot()
    local file = assert(io.open("src/lua/tests/fixtures/empty_snapshots.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, snapshots)
  end)
end)
