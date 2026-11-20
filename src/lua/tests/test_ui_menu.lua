package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("context menus", function()
  local env, ui, ctx

  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    ctx = { width = 300, height = 68, cell_w = 10, cell_h = 20 }
  end)

  it(
    "opens a cascade, returns without dismissal, and closes both levels before dispatch",
    function()
      local ran, reason
      local stack = require("hollow.state").get().ui.overlay_stack
      ui.menu({
        anchor = { x = 670, y = 240 },
        on_close = function(value)
          reason = value
        end,
        items = {
          {
            label = "Dock",
            submenu = {
              { label = "Left", disabled = true },
              {
                label = "Right",
                action = function()
                  assert.equals(0, ui.overlay.depth())
                  ran = true
                end,
              },
            },
          },
        },
      })
      ui._layout_prepare(800, 300, 10, 20)
      ui.dispatch_overlay_key("down", 0)
      ui.dispatch_overlay_key("right", 0)
      assert.equals(2, ui.overlay.depth())
      ui._layout_prepare(800, 300, 10, 20)
      assert.equals(
        stack[1]._layout_surface.frame.margin.left - 160,
        stack[2]._layout_surface.frame.margin.left
      )
      ui.dispatch_overlay_key("escape", 0)
      assert.equals(1, ui.overlay.depth())
      assert.is_nil(reason)
      local root = stack[1]._layout_surface
      ui.dispatch_widget_event("overlay:click", { index = 1, id = root.namespace .. "row-1" })
      assert.equals(2, ui.overlay.depth())
      ui.dispatch_overlay_key("enter", 0)
      assert.is_true(ran)
      assert.equals("selection", reason)
    end
  )

  it(
    "shows occupied Dock edges disabled and dispatches the chosen edge for the clicked pane",
    function()
      local called
      local h = env.hollow
      h.config.set({ terminal_menu_items = { "dock" } })
      local host = {
        menu_query = function(id, action)
          assert.equals(7, id)
          return (action == "target" or action == "dock" or action == "dock_top") and 1 or nil
        end,
        menu_action = function(...)
          called = { ... }
        end,
      }
      require("hollow.ui.widgets.terminal_menu").open(h, host, { pane_id = 7, x = 30, y = 30 })
      ui._layout_prepare(800, 300, 10, 20)
      ui.dispatch_overlay_key("down", 0)
      ui.dispatch_overlay_key("enter", 0)
      ui._layout_prepare(800, 300, 10, 20)
      local children = require("hollow.state").get().ui.overlay_stack[2]._layout_surface
      assert.is_nil(children.callbacks[children.namespace .. "row-1"])
      assert.is_nil(children.callbacks[children.namespace .. "row-2"])
      assert.is_not_nil(children.callbacks[children.namespace .. "row-3"])
      ui.dispatch_widget_event("overlay:click", { index = 2, id = children.namespace .. "row-3" })
      assert.same({ 7, "dock_top", 1 }, called)
    end
  )

  it("places anchors in content coordinates, flipping and clamping at the edges", function()
    local place = require("hollow.ui.widgets.menu").place
    local area = { x = 40, y = 20, width = 300, height = 160 }
    assert.same({ 10, 10 }, { place({ x = 50, y = 30 }, area, 100, 50) })
    assert.same({ 194, 100 }, { place({ x = 325, y = 170, width = 9, height = 8 }, area, 100, 50) })
    assert.same({ 0, 0 }, { place({ x = 10, y = 2 }, area, 100, 50) })
  end)

  it("truncates long labels with an ellipsis", function()
    local fit = require("hollow.ui.widgets.menu").fit
    assert.equals("Split", fit("Split", 5))
    assert.equals("Spl…", fit("Split Right", 4))
    assert.equals("…", fit("Split", 1))
    assert.equals("", fit("Split", 0))
  end)

  it("skips disabled rows, virtualizes scrolling, and closes before activation", function()
    local ran
    local items = {
      { label = "Disabled", disabled = true },
      { separator = true },
    }
    for i = 3, 15 do
      items[i] = {
        label = "Item " .. i,
        action = function()
          assert.equals(0, ui.overlay.depth())
          ran = i
        end,
      }
    end
    ui.menu({ anchor = { x = 10, y = 10 }, items = items })
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    surface:snapshot(ctx)
    assert.is_true(surface.frame.pixels)
    assert.equals(270, surface.frame.width)
    assert.equals(49, surface.frame.height)
    assert.is_nil(next(surface.callbacks))
    ui.dispatch_overlay_key("down", 0)
    surface:snapshot(ctx)
    local function rendered(i)
      return surface.callbacks[surface.namespace .. "row-" .. i] ~= nil
    end
    assert.is_true(rendered(3))
    assert.is_false(rendered(4))
    for _ = 1, 10 do
      ui.dispatch_widget_event("overlay:scroll", { index = 1, delta = -1 })
    end
    surface:snapshot(ctx)
    assert.is_true(rendered(15))
    assert.is_false(rendered(3))
    ui.dispatch_overlay_key("up", 0)
    ui.dispatch_overlay_key("enter", 0)
    assert.equals(15, ran)
  end)

  it(
    "pads rows, aligns optional icons, and dims disabled labels without using the muted accent",
    function()
      local palette = require("hollow.ui.shared").palette("select")
      ui.menu({
        anchor = { x = 0, y = 0 },
        items = {
          { label = "Unavailable", disabled = true, icon = "X" },
          { label = "Available", action = function() end },
        },
      })
      local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
      local nodes = surface:snapshot(ctx)
      assert.equals(5, nodes[1].padding.top)
      assert.equals(10, nodes[2].padding.left)
      assert.equals(28, nodes[3].width)
      assert.equals(nodes[3].width, nodes[7].width)
      assert.equals(nodes[4].fg, nodes[5].fg)
      assert.not_equals(palette.fg, nodes[5].fg)
      assert.not_equals(palette.muted, nodes[5].fg)
      assert.equals(palette.fg, nodes[9].fg)
      assert.is_nil(nodes[2].hover_bg)
      assert.is_true(nodes[6].clickable)
    end
  )

  it("stays open and on top when a notification arrives", function()
    local reason
    local stack = require("hollow.state").get().ui.overlay_stack
    ui.menu({
      anchor = { x = 0, y = 0 },
      items = { { label = "Action", action = function() end } },
      on_close = function(value)
        reason = value
      end,
    })
    local menu = stack[1]
    ui.notify.info("Background event")
    assert.is_nil(reason)
    assert.equals(2, ui.overlay.depth())
    assert.equals(menu, stack[2])
    assert.is_true(stack[1]._notify)
  end)

  it("does not displace an exclusive modal or dispatch to an invalid target", function()
    local reason
    local spec = {
      anchor = { x = 0, y = 0 },
      items = {
        {
          label = "Action",
          action = function()
            error("stale action")
          end,
        },
      },
      on_close = function(value)
        reason = value
      end,
    }
    local modal = ui.modal({
      title = "Exclusive",
      render = function()
        return ui.components.text("Dialog")
      end,
    })
    assert.is_nil(ui.menu(spec))
    modal.close()
    local valid = true
    spec.valid = function()
      return valid
    end
    ui.menu(spec)
    valid = false
    ui.dispatch_widget_event("overlay:outside")
    assert.equals("invalidated", reason)
  end)

  it("uses the opening pane and selection token only on dismiss", function()
    local present, selection = true, 40
    local copies, focused = 0, 1
    local h = env.hollow
    local host = {
      menu_query = function(id, action)
        assert.equals(2, id)
        if present then
          if action == "copy" then
            return selection
          end
          return 1
        end
      end,
      menu_action = function(id, action, expected)
        assert.equals(2, id)
        if action == "copy" and selection == expected then
          copies = copies + 1
        end
      end,
    }
    h.term.pane_by_id = function(id)
      return { id = id }
    end
    local function open()
      return require("hollow.ui.widgets.terminal_menu").open(h, host, { pane_id = 2, x = 3, y = 4 })
    end
    h.config.set({
      terminal_menu_items = {
        {
          label = "Custom",
          action = function(pane)
            assert.equals(2, pane.id)
            assert.equals(1, focused)
          end,
        },
      },
    })
    open()
    ui.dispatch_overlay_key("down", 0)
    ui.dispatch_overlay_key("enter", 0)
    assert.equals(0, copies)
    open()
    selection = 41
    ui.dispatch_overlay_key("escape", 0)
    assert.equals(0, copies)
    open()
    ui.dispatch_widget_event("overlay:outside")
    assert.equals(1, copies)
    open()
    present = false
    ui.dispatch_widget_event("overlay:outside")
    assert.equals(1, copies)
  end)

  it("does nothing for zero domains, opens one directly, and lists multiple", function()
    local h = env.hollow
    local function open()
      ui._open_domain_menu({ x = 0, y = 0, width = 10, height = 10 })
    end
    h.config.set({ domains = {} })
    open()
    assert.equals(0, ui.overlay.depth())
    assert.equals(0, env.recorded.new_tab_calls)
    h.config.set({ domains = { one = { shell = "sh" } } })
    open()
    assert.equals(0, ui.overlay.depth())
    assert.equals("one", env.recorded.new_tab.domain)
    assert.is_true(env.recorded.new_tab.insert_at_end)
    h.config.set({ domains = { two = { shell = "sh" } } })
    open()
    assert.equals(1, ui.overlay.depth())
    assert.equals(1, env.recorded.new_tab_calls)
  end)
end)
