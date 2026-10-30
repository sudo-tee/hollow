package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("activity snapshots", function()
  it("preserves list and detail hint nodes", function()
    local hollow = harness.boot().hollow
    local ui = hollow.ui
    local entries = {
      {
        id = "one",
        kind = "notification",
        title = "Example",
        message = "Details",
        pending = true,
        level = "info",
      },
    }
    hollow.activity.list = function()
      return entries
    end
    hollow.activity.running = function()
      return {}
    end
    hollow.activity.summary = function()
      return { count = 1 }
    end
    ui.activity.open()
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local function snapshot()
      local nodes = surface:snapshot({ width = 800, height = 600, cell_w = 8, cell_h = 19 })
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
    ui.dispatch_overlay_key("v", 0)
    snapshots[2] = snapshot()
    local file = assert(io.open("src/lua/tests/fixtures/activity_snapshot.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, snapshots)
  end)
end)
