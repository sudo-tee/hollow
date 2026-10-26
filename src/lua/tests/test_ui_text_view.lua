package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("read-only text view", function()
  local hollow, theme
  before_each(function()
    hollow = harness.boot().hollow
    theme = hollow.theme.resolve_widget("select")
  end)

  local function lines(view)
    local result = {}
    for _, row in ipairs(view.render(theme)) do
      result[#result + 1] = row.children[1].text
    end
    return result
  end

  it("wraps words and preserves paragraph breaks", function()
    local view = hollow.ui.text_view({ text = "one two three\n\nfour", width = 7 })
    assert.same({ "one two", "three", "", "four" }, lines(view))
  end)

  it("breaks long words without splitting UTF-8 sequences", function()
    local view = hollow.ui.text_view({ text = "ééééé", width = 2 })
    assert.same({ "éé", "éé", "é" }, lines(view))
  end)

  it("scrolls via keyboard and mouse and resets when text changes", function()
    local view = hollow.ui.text_view({ text = "1\n2\n3\n4\n5", row_budget = 2 })
    assert.same({ "1", "2" }, lines(view))
    view.keys("end", "")
    assert.same({ "4", "5" }, lines(view))
    view.on_event("overlay:scroll", { delta = 1 })
    assert.same({ "3", "4" }, lines(view))
    view.set("new")
    assert.same({ "new" }, lines(view))
  end)
end)
