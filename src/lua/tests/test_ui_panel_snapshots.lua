package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("overlay panel snapshots", function()
  it("preserves modal, direct overlay, and toast chrome", function()
    local ui = harness.boot().hollow.ui
    local stack = require("hollow.state").get().ui.overlay_stack
    local ctx = { width = 800, height = 600, cell_w = 10, cell_h = 20 }
    local function snapshot()
      local surface = stack[#stack]._layout_surface
      local nodes = json.decode(json.encode(surface:snapshot(ctx)))
      for _, node in ipairs(nodes) do
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      return { nodes = nodes, frame = json.decode(json.encode(surface.frame)) }
    end
    local chrome = {
      bg = "#112233",
      border = "#445566",
      radius = 5,
      padding = { left = 3, right = 4, top = 2, bottom = 1 },
      margin = { x = 2, y = 3 },
    }
    ui.confirm.open({ title = "Confirm", prompt = "Continue?", chrome = chrome })
    local snapshots = { snapshot() }
    ui.overlay.clear()
    ui.overlay.push(ui.overlay.new({
      chrome = chrome,
      render = function()
        return ui.components.text("Overlay")
      end,
    }))
    snapshots[2] = snapshot()
    ui.overlay.clear()
    ui.notify.info("Notice", { ttl = 0, chrome = chrome })
    snapshots[3] = snapshot()
    harness.fixture("src/lua/tests/fixtures/panel_snapshots.json", snapshots)
  end)
end)
