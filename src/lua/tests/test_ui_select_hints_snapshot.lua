package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("select hints snapshot", function()
  it("preserves the rendered select with multiple hints", function()
    local ui = harness.boot().hollow.ui
    ui.select.open({
      prompt = "Choose",
      items = { "one", "two" },
      actions = {
        { name = "open", key = "<CR>", desc = "open", action = function() end },
        { name = "remove", key = "<C-d>", desc = "remove", action = function() end },
      },
    })
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local nodes = surface:snapshot({ width = 800, height = 600, cell_w = 8, cell_h = 19 })
    local normalized = json.decode(json.encode(nodes))
    for _, node in ipairs(normalized) do
      for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
        if node[field] then
          node[field] = node[field]:gsub("^layout:%d+:", "test:")
        end
      end
    end
    local file = assert(io.open("src/lua/tests/fixtures/select_hints_snapshot.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, normalized)
  end)
end)
