package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay selectable list", function()
  local hollow, ui, stack
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
  end)

  local function prepare()
    ui._layout_prepare(800, 600, 8, 19)
    return ui._layout_tree
  end

  local function viewport()
    for _, node in ipairs(prepare()) do
      if node.id and node.id:match(":select:viewport$") then
        return node
      end
    end
    error("missing viewport")
  end

  local function text()
    local out = {}
    for _, node in ipairs(prepare()) do
      if node.kind == 2 then
        out[#out + 1] = node.text
      end
    end
    return table.concat(out, "|")
  end

  local function row(source_index)
    for _, node in ipairs(prepare()) do
      if node.id and node.id:match(":select:item:" .. source_index .. "$") then
        return node
      end
    end
  end

  local function measure(rows)
    local view = viewport()
    ui._layout_measure(ui._layout_surface_id, view.id, 400, rows * 23)
    prepare()
  end

  local function items(n)
    local values = {}
    for i = 1, n do
      values[i] = "item " .. i
    end
    return values
  end

  it("insets accents without moving select or adapted row content", function()
    ui.select.open({ items = { "one", "two" } })
    local tree = prepare()
    local selected, other
    for index, node in ipairs(tree) do
      if node.id and node.id:match(":select:item:1$") then
        selected = index
      elseif node.id and node.id:match(":select:item:2$") then
        other = index
      end
    end
    local gutter, bar, content = tree[selected + 1], tree[selected + 2], tree[selected + 3]
    assert.equals(2, gutter.width)
    assert.same({ left = 0, right = 0, top = 4, bottom = 4 }, gutter.padding)
    assert.equals(2, bar.width)
    assert.equals(-1, bar.height)
    assert.equals(1, bar.radius)
    assert.is_not_nil(bar.bg)
    assert.equals(tree[other + 1].width, gutter.width)
    assert.is_nil(tree[other + 1].bg)
    assert.equals(content.padding.left, tree[other + 2].padding.left)

    local adapter = require("hollow.ui.builder.components.layout_select")
    local theme = require("hollow.ui.shared").palette("select")
    local function adapted(radius, color)
      return adapter.from_row(
        ui.row({ ui.text("palette") }, {
          fill_radius = radius,
          accent_bar = color,
        }),
        "palette:item",
        "palette",
        theme,
        { cell_h = 19 },
        function() end
      )
    end
    local rounded = adapted(4, "#123456")
    assert.equals(2, rounded.children[1].width)
    assert.same({ left = 0, right = 0, top = 4, bottom = 4 }, rounded.children[1].padding)
    assert.equals(1, rounded.children[1].children[1].style.radius)
    local square = adapted(0, "#123456")
    assert.equals(0, square.children[1].padding.top)
    assert.equals(0, square.children[1].children[1].style.radius)
    local absent = adapted(4, nil)
    assert.equals(2, absent.children[1].width)
    assert.equals(0, #absent.children[1].children)
    assert.equals(rounded.height, absent.height)
  end)

  it("adds horizontal shell padding while preserving custom chrome padding", function()
    local function dialog()
      for _, node in ipairs(prepare()) do
        if node.id and node.id:match(":dialog$") then
          return node
        end
      end
      error("missing dialog")
    end

    ui.select.open({ items = { "one" }, width = 60 })
    local shell = dialog()
    assert.same({ left = 13, right = 13, top = 19, bottom = 9 }, shell.padding)
    assert.equals(60, ui._layout_frame.width)
    ui.select.close()

    ui.select.open({
      items = { "one" },
      width = 60,
      chrome = { padding = { left = 3, right = 5, top = 2, bottom = 4 } },
    })
    shell = dialog()
    assert.same({ left = 15, right = 17, top = 21, bottom = 13 }, shell.padding)
    assert.equals(60, ui._layout_frame.width)
  end)

  it("renders a bounded scroll viewport and reveals keyboard selection", function()
    ui.select.open({ items = items(1000), width = 60 })
    local tree = prepare()
    assert.is_true(ui._overlay_state()[1].clay)
    assert.is_nil(ui._overlay_state()[1].rows)
    assert.is_true(#tree <= 512)
    assert.equals((4 * 19 + 10 * 23 + 1.5 * 19) / 19, ui._layout_frame.height)
    assert.equals(0, ui._layout_frame.align_y)
    assert.is_true(viewport().scroll)
    assert.equals(row(1).id, viewport().reveal)
    local count = 0
    for _, node in ipairs(tree) do
      if node.id and node.id:match(":select:item:%d+$") then
        count = count + 1
      end
    end
    assert.is_true(count <= 24)
    ui.dispatch_overlay_key("end", 0)
    assert.equals(row(1000).id, viewport().reveal)
    assert.is_nil(row(1))
    ui.dispatch_overlay_key("home", 0)
    assert.equals(row(1).id, viewport().reveal)
  end)

  it("fits short lists, reserves divider rows, and leaves the filter unpainted", function()
    ui.select.open({ items = { "one" }, max_height = 24 })
    local tree = prepare()
    assert.equals((4 * 19 + 23 + 1.5 * 19) / 19, ui._layout_frame.height)
    local divider_rows, filter_view = 0, nil
    for _, node in ipairs(tree) do
      if node.height == 19 and node.padding and node.padding.top == 9 then
        divider_rows = divider_rows + 1
      end
      if node.id and node.id:match(":input:viewport$") then
        filter_view = node
      end
    end
    assert.equals(2, divider_rows)
    assert.is_not_nil(filter_view)
    for index, node in ipairs(tree) do
      if node == filter_view then
        assert.is_nil(tree[index - 1].bg)
        assert.is_nil(tree[index - 1].padding)
      end
    end
    ui.select.close()
    ui.select.open({ items = { "one" }, height = 12 })
    prepare()
    assert.equals(12, ui._layout_frame.height)
  end)

  it("uses measured viewport capacity for pages and wheel navigation", function()
    ui.select.open({ items = items(50) })
    measure(4)
    ui.dispatch_overlay_key("page_down", 0)
    assert.is_truthy(text():find("5/50", 1, true))
    ui.dispatch_overlay_key("home", 0)
    prepare()
    ui.dispatch_overlay_key("arrow_down", 0)
    ui.dispatch_overlay_key("arrow_down", 0)
    prepare()
    ui.dispatch_widget_event("overlay:scroll", { delta = -1 })
    assert.is_truthy(text():find("3/50", 1, true))
    assert.is_true(viewport().reveal_start)
    assert.equals(row(2).id, viewport().reveal)
    ui.dispatch_overlay_key("arrow_down", 0)
    assert.is_nil(viewport().reveal_start)
    assert.equals(row(4).id, viewport().reveal)
  end)

  it("publishes full-list scrollbar ratios and routes namespaced drag events", function()
    ui.select.open({ items = items(1000) })
    measure(4)
    local view = viewport()
    assert.is_string(view.scrollbar_id)
    assert.equals(8, view.padding.right)
    assert.equals(0, view.padding.left)
    assert.is_nil(view.scrollbar_thumb_ratio)
    assert.is_true(view.scrollbar_thumb_size < 0.01)
    assert.is_not_nil(view.scrollbar_track_color)
    assert.is_not_nil(view.scrollbar_thumb_color)
    ui.dispatch_widget_event("overlay:scrollbar", { id = view.scrollbar_id, index = 1, ratio = 1 })
    view = viewport()
    assert.equals(1, view.scrollbar_thumb_ratio)
    assert.is_true(view.reveal_start)
    assert.is_not_nil(row(1000))
    ui.dispatch_overlay_key("home", 0)
    assert.is_nil(viewport().reveal_start)
    assert.is_nil(viewport().scrollbar_thumb_ratio)
  end)

  it("omits scrollbar gutter for lists that fit", function()
    ui.select.open({ items = { "one" } })
    assert.is_nil(viewport().scrollbar_id)
    assert.equals(0, (viewport().padding or {}).right or 0)
  end)

  it("preserves plain ranking, query highlighting and filter caret editing", function()
    local selected
    ui.select.open({
      items = { "gamer-profile-app", "ost-propagate", "product-details" },
      fuzzy = false,
      actions = { {
        fn = function(item)
          selected = item
        end,
      } },
    })
    for _, key in ipairs({ "p", "r", "o" }) do
      ui.dispatch_overlay_key(key, 0)
    end
    assert.equals(row(3).id, viewport().reveal)
    local highlighted = false
    for _, node in ipairs(prepare()) do
      if node.text == "pro" and node.bold then
        highlighted = true
      end
    end
    assert.is_true(highlighted)
    ui.dispatch_overlay_key("enter", 0)
    assert.equals("product-details", selected)
    assert.equals(1, #stack) -- Actions retain ownership of closing the select.
    ui.dispatch_overlay_key("arrow_left", 0)
    ui.dispatch_overlay_key("x", 0)
    assert.is_truthy(text():find("prx", 1, true))
  end)

  it("renders rich label/detail paint and routes namespaced row clicks", function()
    local chosen
    ui.select.open({
      items = { { name = "alpha", info = "details" }, { name = "beta", info = "more" } },
      label = function(item)
        return { ui.text(item.name, { fg = "#123456", bold = true }) }
      end,
      detail = function(item)
        return { ui.text(item.info, { fg = "#abcdef", bg = "#112233" }) }
      end,
      actions = { {
        fn = function(item)
          chosen = item.name
        end,
      } },
    })
    local found_label, found_detail = false, false
    for _, node in ipairs(prepare()) do
      if node.text == "alpha" then
        found_label = node.fg == "#123456" and node.bold
      end
      if node.bg == "#112233" then
        found_detail = true
      end
    end
    assert.is_true(found_label)
    assert.is_true(found_detail)
    local beta = row(2)
    ui.dispatch_widget_event("overlay:hover", { id = beta.id, index = 1 })
    prepare()
    ui.dispatch_widget_event("overlay:click", { id = beta.id, index = 1 })
    assert.equals("beta", chosen)
  end)

  it("ignores stale row clicks after the filter removed that source entry", function()
    local calls = 0
    ui.select.open({
      items = { "alpha", "beta" },
      fuzzy = false,
      actions = { {
        fn = function()
          calls = calls + 1
        end,
      } },
    })
    local old = row(2).id
    ui.dispatch_overlay_key("l", 0) -- Only alpha matches, before the next paint.
    ui.dispatch_widget_event("overlay:click", { id = old, index = 1 })
    assert.equals(0, calls)
    assert.is_nil(row(2))
  end)

  it("allows existing button components inside labels without activating the parent row", function()
    local nested, selected
    ui.select.open({
      items = { "alpha", "beta" },
      label = function(value)
        return {
          ui.text(value),
          ui.action_button({
            id = "inspect",
            text = "Inspect",
            on_click = function(event)
              nested = event.id
            end,
          }),
        }
      end,
      actions = { {
        fn = function(value)
          selected = value
        end,
      } },
    })
    local ids = {}
    for _, node in ipairs(prepare()) do
      if node.clickable and node.label == "Inspect" then
        ids[#ids + 1] = node.id
      end
    end
    assert.equals(2, #ids)
    assert.not_equals(ids[1], ids[2])
    ui.dispatch_widget_event("overlay:click", { id = ids[2], index = 1 })
    assert.equals("inspect", nested)
    assert.is_nil(selected)
    assert.is_true(row(1).list_item)
  end)

  it("refreshes callable item sources without discarding query or selection", function()
    local values = { "alpha one", "alpha two" }
    local chosen
    ui.select.open({
      query = "alpha",
      fuzzy = false,
      items = function()
        return values
      end,
      actions = { {
        fn = function(item)
          chosen = item
        end,
      } },
    })
    prepare()
    ui.dispatch_overlay_key("arrow_down", 0)
    values[2] = "alpha updated"
    assert.is_truthy(text():find("updated", 1, true))
    ui.dispatch_overlay_key("enter", 0)
    assert.equals("alpha updated", chosen)
    assert.is_true(stack[1]._layout_live)
  end)

  it("handles empty results, custom action chords and cancellation", function()
    local got, cancelled
    ui.select.open({
      items = { "alpha" },
      query = "zzz",
      fuzzy = false,
      actions = { {
        fn = function(item)
          got = item == nil
        end,
      } },
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.is_nil(viewport().reveal)
    assert.is_truthy(text():find("No matches", 1, true))
    ui.dispatch_overlay_key("enter", 0)
    assert.is_true(got)
    ui.dispatch_overlay_key("escape", 0)
    assert.is_true(cancelled)
    assert.equals(0, #stack)
    ui.select.open({
      items = { "beta" },
      actions = {
        {
          name = "Refresh",
          key = "<C-r>",
          fn = function(item)
            got = item
            ui.select.close()
          end,
        },
      },
    })
    assert.is_truthy(text():find("Refresh", 1, true))
    local key, mods = hollow.keymap.parse_chord("<C-r>")
    ui.dispatch_overlay_key(key, mods)
    assert.equals("beta", got)
    assert.equals(0, #stack)
  end)

  it("degrades extremely fragmented rows instead of exceeding the arena", function()
    ui.select.open({
      items = items(1000),
      label = function(item)
        local fragments = {}
        for i = 1, 100 do
          fragments[i] = ui.text(item .. i, { fg = "#123456" })
        end
        return fragments
      end,
    })
    assert.is_true(#prepare() <= 512)
    ui.dispatch_overlay_key("end", 0)
    assert.is_true(#prepare() <= 512)
    assert.is_not_nil(row(1000))
  end)

  it("does not rebuild static snapshots for unchanged viewport measurements", function()
    ui.select.open({ items = items(50) })
    measure(4)
    local view = viewport()
    local tree = prepare()
    local revision = ui._layout_revision
    ui._layout_measure(ui._layout_surface_id, view.id, 400, 92)
    assert.equals(tree, prepare())
    assert.equals(revision, ui._layout_revision)
    ui._layout_measure(-1, view.id, 200, 46)
    assert.equals(tree, prepare())
  end)

  it("keeps the full rich overscan window within the node limit", function()
    local function rich(value)
      return {
        ui.text(value .. " A", { bg = "#112233" }),
        ui.text(" B", { bg = "#223344" }),
        ui.text(" C", { bg = "#334455" }),
      }
    end
    ui.select.open({
      items = items(1000),
      height = 28,
      label = rich,
      detail = rich,
    })
    local count, styled = 0, 0
    local nodes = prepare()
    assert.is_true(#nodes <= 512)
    for _, node in ipairs(nodes) do
      if node.list_item then
        count = count + 1
      end
      if node.bg == "#112233" then
        styled = styled + 1
      end
    end
    assert.equals(24, count)
    assert.is_true(styled >= 24 * 2) -- Both label and detail stay rich.
  end)

  it("destroys native callbacks on close", function()
    ui.select.open({ items = { "native" } })
    prepare()
    local surface = stack[1]._layout_surface
    ui.select.close()
    assert.is_true(surface.destroyed)
    assert.same({}, surface.metrics)
    prepare()
    assert.is_nil(ui._layout_tree)
  end)
end)
