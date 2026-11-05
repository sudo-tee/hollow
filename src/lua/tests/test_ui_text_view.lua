package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("read-only text view", function()
  local hollow, theme
  before_each(function()
    hollow = harness.boot().hollow
    theme = hollow.theme.resolve_widget("select")
  end)

  local function lines(view)
    return view.visible().lines
  end

  it("wraps words and preserves paragraph breaks", function()
    local view = hollow.ui.text_view({ text = "one two three\n\nfour", width = 7 })
    assert.same({ "one two", "three", "", "four" }, lines(view))
  end)

  it("breaks long words without splitting UTF-8 sequences", function()
    local view = hollow.ui.text_view({ text = "ééééé", width = 2 })
    assert.same({ "éé", "éé", "é" }, lines(view))
  end)

  it("wraps by display width and never splits grapheme clusters", function()
    local saved_host = rawget(_G, "host_api")
    -- Provider fixture: ASCII is one cell, every other code point two.
    _G.host_api = {
      text_graphemes = function(value)
        local clusters = {}
        for text in value:gmatch("[^\128-\193][\128-\191]*") do
          clusters[#clusters + 1] = { text = text, width = #text == 1 and 1 or 2 }
        end
        return clusters
      end,
    }
    local ok, err = pcall(function()
      assert.same(
        { "中文", "ab 中" },
        lines(hollow.ui.text_view({ text = "中文 ab 中", width = 5 }))
      )
      assert.same(
        { "中文", "中" },
        lines(hollow.ui.text_view({ text = "中文中", width = 5 }))
      )
      -- A cluster wider than the view still gets its own line.
      assert.same({ "中", "中" }, lines(hollow.ui.text_view({ text = "中中", width = 1 })))
    end)
    _G.host_api = saved_host
    assert(ok, err)
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

  it("returns viewport metadata instead of legacy row nodes", function()
    local view = hollow.ui.text_view({
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
    view.nav.index = 4
    local last = view.visible()
    assert.same({ "third", "fourth" }, last.lines)
    assert.equals(1, last.scrollbar.ratio)
  end)

  it("keeps the scrollbar controller and viewport synchronized", function()
    local view = hollow.ui.text_view({ text = "one\ntwo\nthree", width = 20, row_budget = 2 })
    local bar = assert(view.visible().scrollbar)
    assert.is_true(view.on_event("overlay:scrollbar", { id = bar.id, ratio = 1 }))
    assert.same({ "two", "three" }, lines(view))
    view.set("replacement")
    assert.same({ "replacement" }, lines(view))
    assert.is_nil(view.visible().scrollbar)
  end)
end)
