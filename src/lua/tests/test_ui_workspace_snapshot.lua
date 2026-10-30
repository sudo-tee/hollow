package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("workspace switcher snapshot", function()
  it("preserves workspace rows and accessibility labels", function()
    local ui = harness.boot().hollow.ui
    ui.workspace.open_switcher()
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local nodes = json.decode(
      json.encode(surface:snapshot({ width = 800, height = 600, cell_w = 10, cell_h = 20 }))
    )
    local found
    for _, node in ipairs(nodes) do
      if node.list_item then
        found = true
      end
      for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
        if node[field] then
          node[field] = node[field]:gsub("^layout:%d+:", "test:")
        end
      end
    end
    assert.is_true(found)
    local file = assert(io.open("src/lua/tests/fixtures/workspace_snapshot.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, nodes)
  end)
end)
