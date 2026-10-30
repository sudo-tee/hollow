package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("command palette snapshot", function()
  it("preserves palette and hint nodes", function()
    local ui = harness.boot().hollow.ui
    ui.command_palette.open({
      entries = {
        {
          name = "open",
          display_name = "Open",
          desc = "Open item",
          category = "general",
          category_label = "General",
          chords = {},
        },
        {
          name = "close",
          display_name = "Close",
          desc = "Close item",
          category = "general",
          category_label = "General",
          chords = {},
        },
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
    local file = assert(io.open("src/lua/tests/fixtures/palette_snapshot.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, normalized)
  end)
end)
