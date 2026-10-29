package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("built-in declarative authoring parity", function()
  local hollow, ui
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
  end)

  it("preserves copy search fragments, selection markers and padding", function()
    local state = require("hollow.state").get()
    local modes = require("hollow.ui.widgets.bars.bottombar")
    local serialize = require("hollow.ui.widgets.bars.bar_serialize")
    local cache = require("hollow.ui.widgets.bars.bar_cache")
    for _, case in ipairs({
      { query = "", count = 0, text = "/search " },
      { query = "query", count = 0, text = "/query  0/0 " },
      { query = "query", count = 3, text = "/query  2/3 " },
      { query = "query", count = 3, selecting = true, text = "/query  2/3  SEL " },
      { query = "query", count = 3, selecting = true, block = true, text = "/query  2/3  BLK " },
    }) do
      state.copy_mode = {
        active = true,
        query = case.query,
        match_count = case.count,
        match_index = 2,
        selecting = case.selecting,
        block = case.block,
      }
      cache.invalidate("bottombar")
      local widget = modes.widget()
      -- Exercise render directly too: the bar adapter intentionally drops errors.
      assert.is_table(widget.render()[2].render())
      local bar = serialize.serialize(widget, "bottombar")
      local search = bar.items[2]
      assert.equals(case.text, search.text)
      assert.equals(" COPY ", bar.items[1].text)
      assert.same({ top = 0, right = 1, bottom = 0, left = 1 }, search.segments[1].padding)
      assert.same({ top = 1, right = 2, bottom = 1, left = 2 }, search.segments[2].padding)
      assert.equals(4, search.segments[1].radius)
      assert.is_true(search.segments[1].bold)
      local text = search.text
      search.segments[1].text = "mutated"
      cache.invalidate("bottombar")
      assert.equals(text, serialize.serialize(modes.widget(), "bottombar").items[2].text)
    end
  end)

  it("retains optional input paint and independent styles with partial palettes", function()
    local input = ui.text_input({ initial = "abc" })
    input.set("abc", 1)
    local theme = { input_fg = "#123456", cursor_bg = "#234567" }
    local nodes = input.render(theme)
    assert.equals("a", nodes[1].text)
    assert.equals("b", nodes[2].text)
    assert.equals("c", nodes[3].text)
    assert.same({ fg = "#123456" }, nodes[1].style)
    assert.same({ bg = "#234567", bold = true }, nodes[2].style)
    nodes[1].style.fg = "#ffffff"
    assert.equals("#123456", nodes[3].style.fg)
    assert.equals("#123456", input.render(theme)[1].style.fg)
  end)

  it("keeps workspace domain colors separate from pill geometry and identity", function()
    local source = require("hollow.ui.workspace.source")
    source.items = function()
      return {
        { name = "one", domain = "local", cwd = "/local", workspace_id = 1 },
        { name = "two", domain = "remote", cwd = "/remote", workspace_id = 2 },
      }
    end
    local colors =
      { fg = "#123456", bg = "#234567", radius = 99, padding = 42, id = "not-a-button" }
    source.switcher_state().workspace_color_fn = function()
      return colors
    end
    ui.workspace.open_switcher()
    local found = false
    for _, row in ipairs(ui._overlay_state()[1].rows) do
      for index, segment in ipairs(row.segments) do
        if segment.text == " remote " then
          found = true
          assert.equals("#123456", segment.fg)
          assert.equals("#234567", segment.bg)
          assert.equals(4, segment.radius)
          assert.is_nil(segment.padding)
          assert.is_nil(segment.id)
          assert.is_true(row.segments[index - 1].spacer)
        end
      end
    end
    assert.is_true(found)
    assert.equals(99, colors.radius)
    assert.equals(42, colors.padding)
  end)

  it("keeps detail rows conditional without losing explicit partial-theme paint", function()
    ui.select.open({
      items = { "one", "two" },
      detail = function(item)
        return item == "one" and "detail" or ""
      end,
      theme = { selection_fg = "#123456", selected_muted = "#234567" },
    })
    local rows = ui._overlay_state()[1].rows
    assert.equals("one", rows[5].segments[2].text)
    assert.equals("#123456", rows[5].segments[2].fg)
    assert.equals("detail", rows[6].segments[2].text)
    assert.equals("#234567", rows[6].segments[2].fg)
    assert.equals("two", rows[7].segments[2].text)
    assert.is_nil(rows[8])
  end)
end)
