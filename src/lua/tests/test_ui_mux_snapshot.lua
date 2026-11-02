package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("mux navigator snapshots", function()
  it("preserves the navigator and measured scrollbar", function()
    local hollow = harness.boot().hollow
    local ui = hollow.ui
    local base = hollow.term.mux_tree()
    local original, panes = base[1].tabs[1].panes[1], {}
    for i = 1, 8 do
      local pane = {}
      for key, value in pairs(original) do
        pane[key] = value
      end
      pane.id, pane.title = i, "pane " .. i
      panes[i] = pane
    end
    base[1].tabs[1].panes = panes
    hollow.term.mux_tree = function()
      return base
    end
    ui.mux_navigator.open()
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local ctx = { width = 800, height = 600, cell_w = 10, cell_h = 20 }
    local function snapshot()
      local nodes = json.decode(json.encode(surface:snapshot(ctx)))
      for _, node in ipairs(nodes) do
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      return nodes
    end
    local snapshots = { snapshot() }
    surface.metrics["mux:viewport"] = { width = 400, height = 48 }
    surface:invalidate()
    snapshots[2] = snapshot()
    harness.fixture("src/lua/tests/fixtures/mux_snapshots.json", snapshots)
  end)
end)
