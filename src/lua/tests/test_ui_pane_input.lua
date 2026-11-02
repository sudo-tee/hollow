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
end)
