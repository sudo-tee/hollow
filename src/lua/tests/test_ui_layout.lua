package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("hierarchical Clay layout", function()
  local ui, layout, c
  before_each(function()
    ui = harness.boot().hollow.ui
    layout = ui.layout
    c = ui.components
  end)

  it("splits props and preserves sparse fragments and legacy options", function()
    local props = require("hollow.ui.components.props")
    local child = c.text("child")
    local p, children = props.split({ [1] = child, [3] = false, width = "grow" })
    assert.equals("grow", p.width)
    assert.equals(child, children[1])
    assert.is_false(children[3])
    local old = { child }
    local options = { width = 12 }
    p, children = props.split(old, options)
    assert.equals(options, p)
    assert.equals(old, children)
    local node = c.row({ width = "grow", child, { c.text({ "nested", wrap = "none" }) } })
    assert.equals("grow", node.width)
    assert.equals("nested", node.children[2][1].text)
    assert.equals("none", node.children[2][1].wrap)
    assert.equals(ui.each, c.each)
    assert.equals(ui.when, c.when)
    assert.equals(ui.join, c.join)
  end)

  it("renders text atoms with scoped recipes and one node each", function()
    local theme = {
      fg = "#111111",
      title = "#222222",
      muted = "#333333",
      styles = { label = { root = { variants = { muted = { fg = "title" } } } } },
    }
    local surface = layout.new({
      theme = theme,
      render = function()
        return c.column({
          c.label({ "hint", tone = "muted" }),
          c.title("heading"),
          c.icon({ name = "bell", style = { fg = "#abcdef" } }),
        })
      end,
    })
    local nodes = surface:snapshot()
    assert.equals(4, #nodes)
    assert.equals("#222222", nodes[2].fg)
    assert.equals(2, nodes[2].wrap)
    assert.equals("#222222", nodes[3].fg)
    assert.is_true(nodes[3].bold)
    assert.equals(require("hollow.ui.icons").bell, nodes[4].text)
    assert.equals("#abcdef", nodes[4].fg)
    assert.has_error(function()
      c.icon("unknown")
    end, "unknown icon: unknown")
  end)

  it("renders painted atoms in two nodes with theme and prop overrides", function()
    local clicked = 0
    local theme = {
      fg = "#111111",
      panel_bg = "#222222",
      input_bg = "#333333",
      styles = { badge = { root = { radius = 7, fg = "fg" } } },
    }
    local surface = layout.new({
      theme = theme,
      render = function()
        return c.column({
          c.badge({
            text = "busy",
            color = "#444444",
            id = "badge",
            label = "status",
            on_click = function()
              clicked = clicked + 1
            end,
          }),
          c.pill({ "domain", fg = "#555555", bg = "#666666", width = 30 }),
          c.kbd({
            key = "<CR>",
            style = { bg = "#777777" },
            disabled = true,
            id = "key",
            on_click = function()
              error("disabled")
            end,
          }),
        })
      end,
    })
    local nodes = surface:snapshot()
    assert.equals(7, #nodes)
    assert.equals(7, nodes[2].radius)
    assert.equals("#444444", nodes[2].bg)
    assert.equals("status", nodes[2].label)
    assert.equals("#111111", nodes[3].fg)
    assert.is_true(nodes[3].bold)
    assert.equals(30, nodes[4].width)
    assert.equals("#666666", nodes[4].bg)
    assert.equals("#555555", nodes[5].fg)
    assert.equals("#777777", nodes[6].bg)
    assert.is_nil(nodes[6].clickable)
    local key, mods = hollow.keymap.parse_chord("<CR>")
    assert.equals(hollow.keymap.format_chord(key, mods), nodes[7].text)
    surface:dispatch(nodes[2].id)
    assert.equals(1, clicked)
  end)

  it("resolves cell units and reports invalid fields", function()
    local surface = layout.new({
      render = function()
        return c.column({
          width = "2ch",
          height = "1lh",
          min_width = "0.5ch",
          gap = "0.5lh",
          padding = { x = "1ch", y = "0.5lh" },
          c.gap({ height = "1lh" }),
        })
      end,
    })
    local nodes = surface:snapshot({ cell_w = 10, cell_h = 20 })
    assert.equals(20, nodes[1].width)
    assert.equals(20, nodes[1].height)
    assert.equals(5, nodes[1].min_width)
    assert.equals(10, nodes[1].gap)
    assert.same({ top = 10, right = 10, bottom = 10, left = 10 }, nodes[1].padding)
    assert.equals(20, nodes[2].height)
    local serialize = require("hollow.ui.layout.serialize")
    local palette = require("hollow.ui.shared").palette("select")
    assert.has_error(function()
      serialize(c.column({ gap = "2em" }), palette, "test:")
    end, "invalid gap unit: 2em")
    local defaults = serialize(c.column({ width = "1ch", height = "1lh" }), palette, "test:")
    assert.equals(8, defaults[1].width)
    assert.equals(19, defaults[1].height)
  end)

  it("restores render scope after nested snapshots and errors", function()
    local props = require("hollow.ui.components.props")
    local outer_theme, inner_theme = { fg = "#111111" }, { fg = "#222222" }
    local inner = layout.new({
      theme = inner_theme,
      render = function(ctx)
        assert.equals(inner_theme, props.scope().theme)
        assert.equals(ctx, props.scope().ctx)
        error("render failure")
      end,
    })
    local outer = layout.new({
      theme = outer_theme,
      render = function()
        assert.equals(outer_theme, props.scope().theme)
        assert.has_error(function()
          inner:snapshot()
        end)
        assert.equals(outer_theme, props.scope().theme)
        return c.text("ok")
      end,
    })
    outer:snapshot()
    assert.is_nil(props._scope)
    assert.not_nil(props.scope().theme)
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
