package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("select search and paint", function()
  local ui
  before_each(function()
    ui = harness.boot().hollow.ui
  end)

  it("prioritizes full-label prefixes in fuzzy scores", function()
    local shared = require("hollow.ui.shared")
    assert.is_true(
      shared.fuzzy_match_score("product-details", "pro")
        > shared.fuzzy_match_score("gamer-profile-app", "pro")
    )
  end)

  it("uses custom search text instead of matching every displayed path", function()
    ui.select.open({
      items = {
        { name = "hollow", cwd = "/home/projects/hollow" },
        { name = "alpha", cwd = "/home/projects/alpha" },
      },
      fuzzy = false,
      label = function(item)
        return item.name .. " " .. item.cwd
      end,
      search_text = function(item)
        return item.name
      end,
    })
    assert.is_true(ui.dispatch_overlay_key("h", 0))
    assert.is_true(ui.dispatch_overlay_key("o", 0))
    assert.is_truthy(clay.text(ui):find("hollow", 1, true))
    assert.is_nil(clay.find(ui, ":select:item:2"))
  end)

  it("preserves custom panel paint and explicit backdrop opt-out", function()
    ui.select.open({
      items = { "alpha" },
      chrome = { bg = "#112233", alpha = 123 },
      backdrop = false,
    })
    local panel = assert(clay.find(ui, ":dialog"))
    assert.equals("#112233", panel.bg)
    assert.equals(123, panel.alpha)
    assert.is_nil(ui._overlay_state()[1].backdrop)
  end)
end)
