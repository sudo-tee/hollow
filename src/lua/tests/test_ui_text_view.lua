package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("read-only text viewport", function()
  local ui

  before_each(function()
    ui = harness.boot().hollow.ui
  end)

  it("returns wrapped visible strings without legacy row nodes", function()
    local view = ui.text_view({
      text = "first\nsecond\nthird\nfourth",
      width = 20,
      row_budget = 2,
      id = "details",
    })
    local first = view.visible()
    assert.same({ "first", "second" }, first.lines)
    assert.is_table(first.scrollbar)
    assert.matches("^details:scrollbar:", first.scrollbar.id)
    assert.equals(0, first.scrollbar.ratio)
    assert.is_true(first.scrollbar.size > 0 and first.scrollbar.size < 1)
    for _, line in ipairs(first.lines) do
      assert.equals("string", type(line))
    end
    view.nav.index = 4
    local last = view.visible()
    assert.same({ "third", "fourth" }, last.lines)
    assert.equals(1, last.scrollbar.ratio)
  end)

  it("keeps the scroll controller and viewport in sync", function()
    local view = ui.text_view({ text = "one\ntwo\nthree", width = 20, row_budget = 2 })
    local bar = assert(view.visible().scrollbar)
    assert.is_true(view.on_event("overlay:scrollbar", { id = bar.id, ratio = 1 }))
    assert.same({ "two", "three" }, view.visible().lines)
    view.set("replacement")
    assert.same({ "replacement" }, view.visible().lines)
    assert.is_nil(view.visible().scrollbar)
  end)

  it("wraps long strings by display cells without losing graphemes", function()
    local view = ui.text_view({ text = "éé éé", width = 2, row_budget = 10 })
    assert.same({ "éé", "éé" }, view.visible().lines)
    assert.is_nil(view.visible().scrollbar)
  end)
end)
