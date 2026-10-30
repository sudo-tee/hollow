package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("hierarchical Clay layout", function()
  local ui, layout, c
  before_each(function()
    ui = harness.boot().hollow.ui
    layout = ui.layout
    c = ui.components
  end)

  it("toggles the surface and grid inspectors independently", function()
    layout.debug(true)
    layout.debug_grid(1)
    assert.is_true(ui._layout_debug)
    assert.is_false(ui._layout_debug_grid)
    layout.debug_grid(true)
    layout.debug(false)
    assert.is_false(ui._layout_debug)
    assert.is_true(ui._layout_debug_grid)
    layout.debug_grid(false)
    assert.is_false(ui._layout_debug_grid)
  end)

  it("stores the inspector width and rejects non-numbers", function()
    ui._layout_debug_width = nil
    assert.equals(400, layout.debug_width())
    layout.debug_width(640)
    assert.equals(640, layout.debug_width())
    assert.has_error(function()
      layout.debug_width("wide")
    end)
    assert.has_error(function()
      layout.debug_width(0 / 0)
    end)
    ui._layout_debug_width = nil
  end)

  it("preserves invalidations raised while constructing a snapshot", function()
    local surface, renders
    renders = 0
    surface = layout.new({
      render = function()
        renders = renders + 1
        if renders == 1 then
          surface:invalidate()
        end
        return c.text("snapshot " .. renders)
      end,
    })
    local first = surface:snapshot()
    local second = surface:snapshot()
    assert.not_equals(first, second)
    assert.equals(2, renders)
    assert.equals(second, surface:snapshot())
    surface:destroy()
  end)

  it("preserves nested containers and splices fragments without flattening boxes", function()
    layout.show(c.row({
      c.column({ c.text("left") }, { width = 120 }),
      false,
      { c.column({ c.text("right") }, { width = "grow" }) },
    }, { width = "grow", height = "grow" }))
    local tree = ui._layout_tree
    assert.equals(5, #tree)
    assert.equals(2, tree[1].children)
    assert.equals(1, tree[2].children)
    assert.equals(120, tree[2].width)
    assert.equals("left", tree[3].text)
    assert.equals(-1, tree[4].width)
    assert.equals("right", tree[5].text)
  end)

  it("serializes fit/grow bounds, per-side borders and text alignment", function()
    layout.show(c.column({
      c.text("Aligned", nil, { text_align = "right" }),
    }, {
      width = "grow",
      height = "fit",
      min_width = 20,
      max_width = 200,
      min_height = 10,
      max_height = 100,
      style = { border = "#123456" },
      border_width = { left = 1, right = 2, top = 3, bottom = 4, between_children = 5 },
    }))
    local root, text = ui._layout_tree[1], ui._layout_tree[2]
    assert.equals(20, root.min_width)
    assert.equals(200, root.max_width)
    assert.equals(10, root.min_height)
    assert.equals(100, root.max_height)
    assert.same(
      { left = 1, right = 2, top = 3, bottom = 4, between_children = 5 },
      root.border_width
    )
    assert.equals(2, text.text_align)
  end)

  it("serializes scrollbar metadata and maps its event ID to the local ID", function()
    local surface = layout.new({
      render = function()
        return c.column({}, {
          scrollbar_id = "picker:scrollbar",
          scrollbar_thumb_ratio = 0.25,
          scrollbar_thumb_size = 0.5,
          scrollbar_track_color = "#123456",
          scrollbar_thumb_color = "#abcdef",
        })
      end,
    })
    local node = surface:snapshot()[1]
    assert.equals(surface.namespace .. "picker:scrollbar", node.scrollbar_id)
    assert.equals("picker:scrollbar", surface:local_id(node.scrollbar_id))
    assert.equals(0.25, node.scrollbar_thumb_ratio)
    assert.equals(0.5, node.scrollbar_thumb_size)
    assert.equals("#123456", node.scrollbar_track_color)
    assert.equals("#abcdef", node.scrollbar_thumb_color)
  end)

  it("resolves scrollbar defaults per snapshot and preserves nested overrides", function()
    local serialize = require("hollow.ui.layout.serialize")
    local palette = {
      fg = "#111111",
      panel_border = "#222222",
      parts = {
        scrollbar = { track = "#333333", thumb = "#444444" },
      },
    }
    local root = c.column({
      c.column(
        {},
        { scrollbar_id = "bar", scrollbar_track_color = "fg", scrollbar_thumb_color = "#abcdef" }
      ),
      c.text("label", { fg = "fg" }),
    }, { scrollbar_id = "root" })
    local first = serialize(root, palette, "test:")
    assert.equals("#333333", first[1].scrollbar_track_color)
    assert.equals("#444444", first[1].scrollbar_thumb_color)
    assert.equals("#111111", first[2].scrollbar_track_color)
    assert.equals("#abcdef", first[2].scrollbar_thumb_color)
    assert.equals("#111111", first[3].fg)
    palette.parts.scrollbar.track = "#555555"
    palette.fg = "#666666"
    local second = serialize(root, palette, "test:")
    assert.equals("#555555", second[1].scrollbar_track_color)
    assert.equals("#666666", second[2].scrollbar_track_color)
    assert.equals("#666666", second[3].fg)
  end)

  it("reuses button recipes, padding, tokens and click callbacks", function()
    local clicked
    layout.show(c.button({
      id = "save",
      text = "Save",
      size = "md",
      variant = "primary",
      on_click = function(event)
        clicked = event.id
      end,
    }))
    assert.equals(8, ui._layout_tree[1].padding.left)
    assert.equals(3, ui._layout_tree[1].padding.top)
    assert.matches("^#%x%x%x%x%x%x$", ui._layout_tree[1].bg)
    assert.equals("Save", ui._layout_tree[2].text)
    ui._layout_click("save")
    assert.equals("save", clicked)
  end)

  it("does not register disabled buttons and clears callbacks on hide", function()
    local clicks = 0
    layout.show(c.button({
      id = "disabled",
      disabled = true,
      text = "No",
      on_click = function()
        clicks = clicks + 1
      end,
    }))
    ui._layout_click("disabled")
    assert.equals(0, clicks)
    layout.show(c.button({
      id = "enabled",
      text = "Yes",
      on_click = function()
        clicks = clicks + 1
      end,
    }))
    layout.hide()
    ui._layout_click("enabled")
    assert.is_nil(ui._layout_tree)
    assert.equals(0, clicks)
  end)

  it("rejects duplicate IDs, invalid sizes and oversized trees atomically", function()
    layout.show(c.text("previous"))
    local previous = ui._layout_tree
    assert.has_error(function()
      layout.show(c.row({ c.column({}, { id = "same" }), c.column({}, { id = "same" }) }))
    end)
    assert.equals(previous, ui._layout_tree)
    assert.has_error(function()
      layout.show(c.column({}, { width = math.huge }))
    end)
    local nodes = {}
    for i = 1, 512 do
      nodes[i] = c.text(i)
    end
    assert.has_error(function()
      layout.show(c.column(nodes))
    end)
    assert.equals(previous, ui._layout_tree)
  end)

  it("caches demo until interaction and keeps custom paint and scroll nodes", function()
    c.demo()
    local tree = ui._layout_tree
    local scrolls, custom = 0, 0
    for _, node in ipairs(tree) do
      if node.scroll then
        scrolls = scrolls + 1
      end
      if node.kind == 3 then
        custom = custom + 1
      end
    end
    assert.equals(1, scrolls)
    assert.equals(41, custom)
    ui._layout_click("clay.count")
    assert.not_equals(tree, ui._layout_tree)
    local found = false
    for _, node in ipairs(ui._layout_tree) do
      if node.text == "Clicked 1 times" then
        found = true
      end
    end
    assert.is_true(found)
    ui._layout_click("clay.close")
    assert.is_nil(ui._layout_tree)
  end)

  it("isolates identical local IDs and invalidates only the owning snapshot", function()
    local renders, clicks = { 0, 0 }, { 0, 0 }
    local surfaces = {}
    for i = 1, 2 do
      surfaces[i] = layout.new({
        render = function()
          renders[i] = renders[i] + 1
          return c.button({
            id = "same",
            text = "Action",
            on_click = function(event)
              assert.equals("same", event.id)
              clicks[i] = clicks[i] + 1
            end,
          })
        end,
      })
    end
    local ctx = { width = 800, height = 600, cell_w = 8, cell_h = 19 }
    local first, second = surfaces[1]:snapshot(ctx), surfaces[2]:snapshot(ctx)
    assert.not_equals(first[1].id, second[1].id)
    surfaces[1]:dispatch(first[1].id)
    surfaces[2]:dispatch(first[1].id)
    assert.same({ 1, 0 }, clicks)
    assert.equals(first, surfaces[1]:snapshot(ctx))
    assert.same({ 1, 1 }, renders)
    surfaces[1]:invalidate()
    assert.not_equals(first, surfaces[1]:snapshot(ctx))
    assert.same({ 2, 1 }, renders)
    surfaces[1]:destroy()
    surfaces[1]:dispatch(first[1].id)
    assert.same({ 1, 0 }, clicks)
    assert.has_error(function()
      surfaces[1]:snapshot(ctx)
    end)
  end)

  it("invalidates on viewport or font metrics changes but not idle preparation", function()
    local renders = 0
    local surface = layout.new({
      render = function()
        renders = renders + 1
        return c.column({ c.text("Hello") })
      end,
    })
    surface:snapshot({ width = 800, cell_w = 8 })
    surface:snapshot({ width = 800, cell_w = 8 })
    assert.equals(1, renders)
    surface:snapshot({ width = 600, cell_w = 8 })
    surface:snapshot({ width = 600, cell_w = 10 })
    assert.equals(3, renders)
    require("hollow.ui.shared").invalidate_palettes()
    surface:snapshot({ width = 600, cell_w = 10 })
    assert.equals(4, renders)
  end)

  it("namespaces reveal targets and rejects targets outside the scroll subtree", function()
    layout.show(c.row({ c.column({}, { id = "caret", width = 8, height = 19 }) }, {
      scroll_x = true,
      reveal = "caret",
      width = "grow",
      height = 19,
    }))
    assert.equals(ui._layout_tree[2].id, ui._layout_tree[1].reveal)
    assert.has_error(function()
      layout.show(c.column({}, { scroll_x = true, reveal = "missing" }))
    end)
    assert.has_error(function()
      layout.show(c.column({
        c.column({}, { id = "sibling" }),
        c.column({}, { scroll_x = true, reveal = "sibling" }),
      }))
    end)
    assert.has_error(function()
      layout.show(c.text("Bad", {}, { wrap = "invalid" }))
    end)
  end)
end)
