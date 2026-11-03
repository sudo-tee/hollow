package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Lua pane keys and focus", function()
  local env, h, owners, active, on_key, invalidations
  local function ctx(focused)
    return {
      pane_id = active,
      cols = 40,
      rows = 10,
      width = 400,
      height = 200,
      cell_w = 10,
      cell_h = 20,
      focused = focused ~= false,
    }
  end
  local function pane(opts)
    opts = opts or {}
    opts.render = opts.render or function()
      return h.ui.components.text("Pane")
    end
    local instance = h.ui.pane.split(opts)
    active = instance.id
    owners[active]:snapshot(ctx())
    return instance, owners[active]
  end

  before_each(function()
    env = harness.boot()
    h, owners, active, invalidations = env.hollow, {}, 100, 0
    env.host_api.current_pane_id = function()
      return active
    end
    env.host_api.create_lua_pane = function(owner)
      local id = 101 + #owners
      while owners[id] do
        id = id + 1
      end
      owners[id] = owner
      return id
    end
    env.host_api.invalidate_lua_pane = function()
      invalidations = invalidations + 1
    end
    on_key = env.get_key_handler()
  end)

  it("gives plain keys to the focused pane before global bindings", function()
    local hits, globals = 0, 0
    local instance = pane({
      state = { marker = 7 },
      on_key = function(key, mods, context)
        assert.are.equal("x", key)
        assert.are.equal("", mods)
        assert.are.equal(7, context.state.marker)
        assert.is_true(context.focused)
        hits = hits + 1
        return true
      end,
    })
    h.keymap.set("x", function()
      globals = globals + 1
    end)
    assert.is_true(on_key("x", 0))
    assert.are.equal(1, hits)
    assert.are.equal(0, globals)
    assert.are.equal(1, invalidations)
    assert.is_true(instance.surface.dirty)
  end)

  it("runs modified global bindings first, then falls back to the pane", function()
    local hits, globals = 0, 0
    pane({
      on_key = function(_, mods)
        assert.are.equal("<C>", mods)
        hits = hits + 1
        return true
      end,
    })
    h.keymap.set("<C-x>", function()
      globals = globals + 1
    end)
    assert.is_true(on_key("x", 2))
    assert.are.equal(1, globals)
    assert.are.equal(0, hits)
    assert.is_true(on_key("y", 2))
    assert.are.equal(1, hits)
  end)

  it("falls through exactly once when pane declines or throws", function()
    local hits, globals = 0, 0
    pane({
      on_key = function(key)
        hits = hits + 1
        if key == "e" then
          error("pane key failed")
        end
        return false
      end,
    })
    h.keymap.set("x", function()
      globals = globals + 1
    end)
    h.keymap.set("e", function()
      globals = globals + 1
    end)
    assert.is_true(on_key("x", 0))
    assert.is_true(on_key("e", 0))
    assert.is_false(on_key("z", 0))
    assert.are.equal(3, hits)
    assert.are.equal(2, globals)
  end)

  it("does not route keys to background, blurred, closed or unmounted panes", function()
    local hits = 0
    local instance, owner = pane({
      on_key = function()
        hits = hits + 1
        return true
      end,
    })
    active = 999
    assert.is_false(on_key("z", 0))
    active = instance.id
    owner:focus(ctx(false), false)
    assert.is_false(on_key("z", 0))
    owner:focus(ctx(), true)
    assert.is_true(on_key("z", 0))
    owner:destroy()
    assert.is_false(on_key("z", 0))
    local pending = h.ui.pane.split({
      render = function() end,
      on_key = function()
        hits = hits + 1
        return true
      end,
    })
    active = pending.id
    assert.is_false(on_key("z", 0))
    assert.are.equal(1, hits)
  end)

  it("keeps overlays and pending global sequences ahead of pane keys", function()
    local hits, globals = 0, 0
    pane({
      on_key = function()
        hits = hits + 1
        return true
      end,
    })
    local dispatch = h.ui.dispatch_overlay_key
    h.ui.dispatch_overlay_key = function()
      return true
    end
    assert.is_true(on_key("x", 0))
    assert.are.equal(0, hits)
    h.ui.dispatch_overlay_key = dispatch
    h.keymap.set("<C-x>z", function()
      globals = globals + 1
    end)
    assert.is_true(on_key("x", 2))
    assert.is_true(on_key("z", 0))
    assert.are.equal(1, globals)
    assert.are.equal(0, hits)
  end)

  it("routes Tab and activation through pane-local surface focus", function()
    local clicks = 0
    local instance = pane({
      render = function()
        return h.ui.components.column({
          h.ui.components.button({
            id = "button",
            text = "Click",
            on_click = function()
              clicks = clicks + 1
            end,
          }),
        })
      end,
    })
    assert.is_true(on_key("tab", 0))
    assert.are.equal("button", instance.surface:focused_id())
    assert.is_true(on_key("enter", 0))
    assert.are.equal(1, clicks)
    assert.is_true(on_key("tab", 1))
  end)

  local function spatial_pane(opts)
    opts = opts or {}
    local input = h.ui.text_input({ initial = "text" })
    opts.render = function()
      local c = h.ui.components
      return c.column({
        c.button({ id = "first", text = "First", on_click = function() end }),
        c.button({ id = "diagonal", text = "Diagonal", on_click = function() end }),
        c.button({ id = "right", text = "Right", on_click = function() end }),
        c.button({ id = "below", text = "Below", on_click = function() end }),
        c.input({ id = "field", behavior = input }),
      })
    end
    local instance, owner = pane(opts)
    local bounds = {}
    local function rect(id, x, y)
      bounds[instance.surface.namespace .. id] = { x = x, y = y, width = 40, height = 20 }
    end
    rect("first", 0, 0)
    rect("diagonal", 45, 25)
    rect("right", 150, 0)
    rect("below", 0, 250)
    rect("field", 300, 0)
    owner:geometry(bounds)
    return instance, owner, input
  end

  it("navigates rendered positions, prefers alignment, and does not wrap", function()
    local instance = spatial_pane()
    assert.is_true(on_key("arrow_down", 0))
    assert.equals("first", instance.surface:focused_id())
    assert.is_true(instance.surface.focus_visible)
    assert.is_true(on_key("arrow_right", 0))
    assert.equals("right", instance.surface:focused_id())
    assert.is_true(on_key("arrow_left", 0))
    assert.equals("first", instance.surface:focused_id())
    assert.is_true(on_key("arrow_left", 0))
    assert.equals("first", instance.surface:focused_id())
    assert.is_true(on_key("arrow_down", 0))
    assert.equals("below", instance.surface:focused_id())
    assert.is_true(on_key("arrow_down", 0))
    assert.equals("below", instance.surface:focused_id())
  end)

  it("starts reverse navigation at the last control", function()
    local instance = spatial_pane()
    assert.is_true(on_key("arrow_up", 0))
    assert.equals("field", instance.surface:focused_id())
  end)

  it("focuses the first enabled control immediately on keyboard pane entry", function()
    local instance, owner = spatial_pane()
    owner:focus(ctx(false), false)
    local keyboard_ctx = ctx()
    keyboard_ctx.keyboard_focus = true
    owner:focus(keyboard_ctx, true)
    assert.equals("first", instance.surface:focused_id())
    assert.is_true(instance.surface.focus_visible)
    local nodes = owner:snapshot(keyboard_ctx)
    assert.is_truthy(nodes[2].border)
    assert.is_true(on_key("arrow_right", 0))
    assert.equals("right", instance.surface:focused_id())
    owner:snapshot(keyboard_ctx)
    assert.equals("right", instance.surface:focused_id())
    owner:focus(ctx(false), false)
    owner:focus(keyboard_ctx, true)
    assert.equals("first", instance.surface:focused_id())
  end)

  it("autofocuses after the first keyboard-mounted snapshot, skipping disabled controls", function()
    local c = h.ui.components
    local instance = h.ui.pane.split({
      render = function()
        return c.column({
          c.button({
            id = "disabled",
            text = "Disabled",
            disabled = true,
            on_click = function() end,
          }),
          c.button({ id = "enabled", text = "Enabled", on_click = function() end }),
        })
      end,
    })
    active = instance.id
    local keyboard_ctx = ctx()
    keyboard_ctx.keyboard_focus = true
    local nodes = owners[active]:snapshot(keyboard_ctx)
    assert.equals("enabled", instance.surface:focused_id())
    assert.is_true(instance.surface.focus_visible)
    assert.is_truthy(nodes[4].border)
  end)

  it("does not autofocus on mouse pane entry or repeated keyboard snapshots", function()
    local instance, owner = spatial_pane()
    assert.is_nil(instance.surface:focused_id())
    owner:focus(ctx(false), false)
    owner:focus(ctx(), true)
    assert.is_nil(instance.surface:focused_id())
    local keyboard_ctx = ctx()
    keyboard_ctx.keyboard_focus = true
    owner:snapshot(keyboard_ctx)
    assert.is_nil(instance.surface:focused_id())
    owner:pointer("click", instance.surface.namespace .. "right", "left")
    assert.equals("right", instance.surface:focused_id())
    assert.is_false(instance.surface.focus_visible)
    owner:focus(ctx(false), false)
    owner:focus(ctx(), true)
    assert.equals("right", instance.surface:focused_id())
    assert.is_false(instance.surface.focus_visible)
  end)

  it("reconciles keyboard entry with controls changed while the pane was inactive", function()
    local disabled = false
    local c = h.ui.components
    local instance, owner = pane({
      render = function()
        return c.column({
          c.button({ id = "first", text = "First", disabled = disabled, on_click = function() end }),
          c.button({ id = "second", text = "Second", on_click = function() end }),
        })
      end,
    })
    owner:focus(ctx(false), false)
    disabled = true
    local keyboard_ctx = ctx()
    keyboard_ctx.keyboard_focus = true
    owner:focus(keyboard_ctx, true)
    owner:snapshot(keyboard_ctx)
    assert.equals("second", instance.surface:focused_id())
    assert.is_true(instance.surface.focus_visible)
  end)

  it("keeps keyboard moves made before the entry snapshot", function()
    local instance, owner = spatial_pane()
    owner:focus(ctx(false), false)
    local keyboard_ctx = ctx()
    keyboard_ctx.keyboard_focus = true
    owner:focus(keyboard_ctx, true)
    assert.is_true(on_key("arrow_right", 0))
    owner:snapshot(keyboard_ctx)
    assert.equals("right", instance.surface:focused_id())
  end)

  it("does not autofocus controls that appear after a control-less entry", function()
    local show = false
    local c = h.ui.components
    local instance, owner = pane({
      render = function()
        return c.column({
          show and c.button({ id = "late", text = "Late", on_click = function() end })
            or c.text("none"),
        })
      end,
    })
    owner:focus(ctx(false), false)
    local keyboard_ctx = ctx()
    keyboard_ctx.keyboard_focus = true
    owner:focus(keyboard_ctx, true)
    owner:snapshot(keyboard_ctx)
    show = true
    instance.surface:invalidate()
    owner:snapshot(keyboard_ctx)
    assert.is_nil(instance.surface:focused_id())
  end)

  it("uses diagonal candidates when none align and ignores disabled or removed nodes", function()
    local instance = spatial_pane()
    local s = instance.surface
    s:focus("first")
    s.focus_bounds[s.namespace .. "right"] = nil
    s.focus_bounds[s.namespace .. "field"] = nil
    s.focus_bounds[s.namespace .. "disabled"] = { x = 45, y = 0, width = 40, height = 20 }
    assert.is_true(on_key("arrow_right", 0))
    assert.equals("diagonal", s:focused_id())
    s:focus("first")
    s.focus_order = { s.namespace .. "first", s.namespace .. "below" }
    assert.is_true(on_key("arrow_right", 0))
    assert.equals("first", s:focused_id())
  end)

  it("preserves input arrows, including unhandled directions and cursor boundaries", function()
    local instance, _, input = spatial_pane()
    instance.surface:focus("field")
    input.cursor = 0
    assert.is_true(on_key("arrow_left", 0))
    assert.equals(0, input.cursor)
    assert.equals("field", instance.surface:focused_id())
    assert.is_false(on_key("arrow_down", 0))
    assert.equals("field", instance.surface:focused_id())
    assert.is_true(on_key("tab", 0))
    assert.equals("first", instance.surface:focused_id())
  end)

  it("lets pane handlers override spatial navigation and ignores modified arrows", function()
    local instance = spatial_pane({
      on_key = function(key)
        return key == "arrow_right"
      end,
    })
    instance.surface:focus("first")
    assert.is_true(on_key("arrow_right", 0))
    assert.equals("first", instance.surface:focused_id())
    on_key("arrow_down", 1)
    assert.equals("first", instance.surface:focused_id())
  end)

  it("hides rings on deliberate motion, not hover-only layout changes or jitter", function()
    local instance, owner = spatial_pane()
    local id = instance.surface.namespace .. "first"
    owner:pointer("hover", id, nil, 10, 10)
    instance.surface:focus("first")
    owner:pointer("hover", nil, nil, 10, 10)
    owner:pointer("hover", id, nil, 12, 11)
    assert.is_true(instance.surface.focus_visible)
    owner:pointer("hover", id, nil, 14, 10)
    assert.is_false(instance.surface.focus_visible)
    assert.equals("first", instance.surface:focused_id())
    owner:snapshot(ctx())
    assert.is_false(owner:pointer("hover", id, nil, 20, 10))
    assert.is_false(instance.surface.dirty)
    assert.is_true(on_key("arrow_left", 0))
    assert.is_true(instance.surface.focus_visible)
    owner:pointer("hover", id, nil, 20, 10)
    assert.is_true(instance.surface.focus_visible)
    owner:pointer("scroll", nil, 1)
    assert.is_false(instance.surface.focus_visible)
    assert.equals("first", instance.surface:focused_id())
  end)

  it("keeps clicked inputs editable without pointer focus decoration", function()
    local instance, owner, input = spatial_pane()
    owner:pointer("click", instance.surface.namespace .. "field", "left")
    assert.is_false(instance.surface.focus_visible)
    assert.equals("field", instance.surface:focused_id())
    assert.is_true(on_key("x", 0))
    assert.equals("textx", input.value)
    assert.is_true(instance.surface.focus_visible)
    owner:pointer("click", nil, "right")
    assert.is_false(instance.surface.focus_visible)
    assert.equals("field", instance.surface:focused_id())
  end)

  it("reveals offscreen spatial targets in their scroll viewport", function()
    local c = h.ui.components
    local instance, owner = pane({
      render = function()
        return c.column({
          c.button({ id = "top", text = "Top", on_click = function() end }),
          c.button({ id = "bottom", text = "Bottom", on_click = function() end }),
        }, { id = "viewport", scroll = true })
      end,
    })
    local ns = instance.surface.namespace
    owner:geometry({
      [ns .. "top"] = { x = 0, y = 0, width = 40, height = 20 },
      [ns .. "bottom"] = { x = 0, y = 1000, width = 40, height = 20 },
    })
    instance.surface:focus("top")
    assert.is_true(on_key("arrow_down", 0))
    local nodes = owner:snapshot(ctx())
    assert.equals(ns .. "bottom", nodes[1].reveal)
  end)

  it("notifies initial focus and transitions once, then blurs before unmount", function()
    local events = {}
    local _, owner = pane({
      on_mount = function()
        events[#events + 1] = "mount"
      end,
      on_focus = function(context, focused)
        assert.are.equal(focused, context.focused)
        events[#events + 1] = focused and "focus" or "blur"
      end,
      on_unmount = function(context)
        assert.is_false(context.focused)
        events[#events + 1] = "unmount"
      end,
    })
    owner:focus(ctx(), true)
    owner:focus(ctx(false), false)
    owner:snapshot(ctx(false))
    owner:focus(ctx(), true)
    owner:destroy()
    owner:destroy()
    assert.same({ "mount", "focus", "blur", "focus", "blur", "unmount" }, events)
  end)

  it("cleans up and unmounts even when blur callback fails", function()
    local unmounted = 0
    local instance, owner = pane({
      on_focus = function(_, focused)
        if not focused then
          error("blur failed")
        end
      end,
      on_unmount = function()
        unmounted = unmounted + 1
      end,
    })
    assert.has_error(function()
      owner:destroy()
    end)
    assert.are.equal(1, unmounted)
    assert.is_true(instance.surface.destroyed)
    assert.is_nil(h.ui.pane.get(instance.id))
  end)

  it("lets capture_keys panes take modified keys while the leader escapes", function()
    local hits, globals, leader = {}, 0, 0
    h.keymap.set_leader("<C-b>")
    h.keymap.set("<leader>x", function()
      leader = leader + 1
    end)
    h.keymap.set("<C-v>", function()
      globals = globals + 1
    end)
    pane({
      capture_keys = true,
      on_key = function(key, mods)
        hits[#hits + 1] = mods .. key
        return true
      end,
    })
    assert.is_true(on_key("v", 2))
    assert.are.equal(0, globals)
    assert.same({ "<C>v" }, hits)
    assert.is_true(on_key("b", 2))
    assert.is_true(on_key("x", 0))
    assert.are.equal(1, leader)
    assert.same({ "<C>v" }, hits)
  end)

  it("decodes send-keys bytes into canonical key events", function()
    local decode = h.ui.pane._decode_input
    assert.same({
      { "arrow_down", 0 },
      { "enter", 0 },
      { "a", 1 },
      { "minus", 0 },
      { "space", 0 },
      { "tab", 1 },
      { "arrow_up", 2 },
      { "r", 2 },
      { "x", 4 },
      { "page_down", 0 },
      { "backspace", 0 },
      { "escape", 0 },
    }, decode("\27[B\rA- \27[Z\27[1;5A\18\27x\27[6~\127\27"))
    assert.same({ { "arrow_left", 0 } }, decode("\27[99q\27OD"))
  end)

  it("routes send_text to Lua panes as keys, focused or not", function()
    local keys = {}
    local instance = pane({
      on_key = function(key, mods)
        keys[#keys + 1] = mods .. key
        return true
      end,
    })
    env.host_api.get_pane_content = function(id)
      return { kind = owners[id] and "lua" or "terminal" }
    end
    owners[active]:focus(ctx(false), false)
    h.term.send_text("q\27[A", instance.id)
    assert.same({ "q", "arrow_up" }, keys)
    assert.is_true(owners[active].input(owners[active], "\r"))
    assert.same({ "q", "arrow_up", "enter" }, keys)
    assert.is_false(h.ui.pane._send_input(999, "x"))
  end)
end)
