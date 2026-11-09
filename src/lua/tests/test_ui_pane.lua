package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Lua UI panes", function()
  local env, ui, owners, next_id, invalidations, titles, closes
  local function context()
    return {
      pane_id = next_id,
      cols = 40,
      rows = 10,
      width = 400,
      height = 200,
      cell_w = 10,
      cell_h = 20,
      focused = true,
    }
  end

  before_each(function()
    env = harness.boot()
    ui, owners, next_id, invalidations, titles, closes = env.hollow.ui, {}, 100, 0, {}, 0
    env.host_api.create_lua_pane = function(owner)
      next_id = next_id + 1
      owners[next_id] = owner
      return next_id
    end
    env.host_api.invalidate_lua_pane = function()
      invalidations = invalidations + 1
    end
    env.host_api.title_lua_pane = function(id, title)
      titles[id] = title
    end
    env.host_api.close_pane_by_id = function()
      closes = closes + 1
      return true
    end
  end)

  it("creates split and floating panes with independent state and namespaces", function()
    local render = function(ctx)
      ctx.state.calls = (ctx.state.calls or 0) + 1
      return ui.components.column({
        ui.components.button({ id = "same", text = "Hello", on_click = function() end }),
      })
    end
    local a = ui.pane.split({ render = render, title = "Tasks", ratio = 0.4 })
    local b = ui.pane.float({ render = render })
    assert.are.equal(a, ui.pane.get(a.id))
    assert.are.equal("Tasks", titles[a.id])
    assert.is_false(owners[a.id].floating)
    assert.is_true(owners[b.id].floating)
    local an = owners[a.id]:snapshot(context())
    local bn = owners[b.id]:snapshot(context())
    assert.are_not.equal(an[1].id, bn[1].id)
    assert.are.equal(1, a.opts.state.calls)
    assert.are.equal(1, b.opts.state.calls)
  end)

  it("caches snapshots until invalidated and supplies complete render context", function()
    local calls = 0
    local state = {}
    local pane = ui.pane.split({
      state = state,
      render = function(ctx)
        calls = calls + 1
        assert.are.equal(state, ctx.state)
        assert.are.equal(next_id, ctx.pane_id)
        assert.are.equal(40, ctx.cols)
        assert.are.equal(10, ctx.rows)
        assert.is_true(ctx.focused)
        assert.is_table(ctx.theme)
        return ui.components.text("Hello")
      end,
    })
    local owner = owners[pane.id]
    owner:snapshot(context())
    owner:snapshot(context())
    assert.are.equal(1, calls)
    pane:invalidate()
    owner:snapshot(context())
    assert.are.equal(2, calls)
    assert.are.equal(1, invalidations)
    assert.are.equal(nil, ui._layout_tree)
  end)

  it("mounts once, resizes with new context, unmounts and destroys once", function()
    local mounts, resizes, unmounts = 0, 0, 0
    local pane = ui.pane.split({
      render = function()
        return ui.components.text("Hello")
      end,
      on_mount = function(ctx)
        mounts = mounts + 1
        assert.are.equal(40, ctx.cols)
      end,
      on_resize = function(ctx)
        resizes = resizes + 1
        assert.are.equal(30, ctx.cols)
      end,
      on_unmount = function(ctx)
        unmounts = unmounts + 1
        assert.are.equal(30, ctx.cols)
      end,
    })
    local owner = owners[pane.id]
    owner:snapshot(context())
    owner:snapshot(context())
    local resized = context()
    resized.cols, resized.width = 30, 300
    owner:invalidate()
    owner:snapshot(resized)
    assert.is_true(pane:close())
    assert.is_false(pane:close())
    assert.are.equal(1, closes)
    owner:destroy()
    owner:destroy()
    assert.are.equal(1, mounts)
    assert.are.equal(1, resizes)
    assert.are.equal(1, unmounts)
    assert.is_nil(ui.pane.get(pane.id))
    assert.is_true(pane.surface.destroyed)
    pane:invalidate()
    assert.are.equal(0, invalidations)
  end)

  it("replaces render failures with visible error rows and can recover", function()
    local fail = true
    local pane = ui.pane.split({
      render = function()
        if fail then
          error("broken render")
        end
        return ui.components.text("Recovered")
      end,
    })
    local owner = owners[pane.id]
    local nodes = owner:snapshot(context())
    assert.matches("broken render", nodes[2].text)
    assert.is_string(nodes[2].fg)
    fail = false
    pane:invalidate()
    nodes = owner:snapshot(context())
    assert.are.equal("Recovered", nodes[1].text)
  end)

  it("renders lifecycle hook failures as error rows instead of blanking", function()
    local pane = ui.pane.split({
      on_mount = function()
        error("broken mount")
      end,
      render = function()
        return ui.components.text("Hello")
      end,
    })
    local nodes = owners[pane.id]:snapshot(context())
    assert.matches("broken mount", nodes[2].text)
  end)

  it("keeps unknown-token errors strict", function()
    local pane = ui.pane.split({
      render = function()
        return ui.components.text("Bad token", { fg = "@not_a_pane_token" })
      end,
    })
    assert.has_error(function()
      owners[pane.id]:snapshot(context())
    end)
  end)

  it("cleans up even if unmount fails", function()
    local pane = ui.pane.split({
      render = function()
        return ui.components.text("Hello")
      end,
      on_unmount = function()
        error("unmount failed")
      end,
    })
    local owner = owners[pane.id]
    owner:snapshot(context())
    assert.has_error(function()
      owner:destroy()
    end)
    assert.is_nil(ui.pane.get(pane.id))
    assert.is_true(pane.surface.destroyed)
    owner:destroy()
  end)

  it("rejects invalid options before native allocation", function()
    assert.has_error(function()
      ui.pane.split({})
    end)
    local render = function()
      return ui.components.text("Hello")
    end
    assert.has_error(function()
      ui.pane.split({ render = render, ratio = 0 / 0 })
    end)
    assert.has_error(function()
      ui.pane.split({ render = render, direction = "diagonal" })
    end)
    assert.has_error(function()
      ui.pane.split({ render = render, dock = "global" })
    end)
    assert.has_error(function()
      ui.pane.split({ render = render, edge = "left", dock = "tab" })
    end)
    assert.has_error(function()
      ui.pane.float({ render = render, edge = "left", dock = "global" })
    end)
    assert.are.equal(100, next_id)
  end)

  it("returns nil when host cannot enqueue creation", function()
    env.host_api.create_lua_pane = function()
      return nil
    end
    assert.is_nil(ui.pane.split({ render = function() end }))
  end)
end)
