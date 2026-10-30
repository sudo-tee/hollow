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
    local file = assert(io.open("src/lua/tests/fixtures/repl_snapshot.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, snapshots)
  end)
end)
