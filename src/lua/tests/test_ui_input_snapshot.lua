package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("input overlay snapshots", function()
  it("preserves titled and untitled input overlays", function()
    local ui = harness.boot().hollow.ui
    local stack = require("hollow.state").get().ui.overlay_stack
    local function snapshot()
      local surface = stack[#stack]._layout_surface
      local nodes = json.decode(
        json.encode(surface:snapshot({ width = 800, height = 600, cell_w = 10, cell_h = 20 }))
      )
      for _, node in ipairs(nodes) do
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      return nodes
    end
    ui.input.open({ prompt = "Rename", default = "workspace" })
    local snapshots = { snapshot() }
    ui.input.close()
    ui.input.open({ default = "value" })
    snapshots[2] = snapshot()
    harness.fixture("src/lua/tests/fixtures/input_snapshots.json", snapshots)
  end)
end)
