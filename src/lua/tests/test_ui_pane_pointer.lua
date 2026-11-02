package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Lua pane pointer namespaces", function()
  local env, ui, owners, next_id
  local function ctx(id)
    return {
      pane_id = id,
      cols = 40,
      rows = 10,
      width = 400,
      height = 200,
      cell_w = 10,
      cell_h = 20,
      focused = true,
    }
  end
  local function create(render)
    local pane = ui.pane.split({
      state = { hits = 0 },
      render = render or function(context)
        return ui.components.column({
          ui.components.button({
            id = "same",
            text = "Click",
            on_click = function(event)
              context.state.hits = context.state.hits + 1
              context.state.event_id = event.id
            end,
          }),
        })
      end,
    })
    local owner = owners[pane.id]
    owner:snapshot(ctx(pane.id))
    return pane, owner, pane.surface.namespace .. "same"
  end

  before_each(function()
    env = harness.boot()
    ui, owners, next_id = env.hollow.ui, {}, 100
    env.host_api.create_lua_pane = function(owner)
      next_id = next_id + 1
      owners[next_id] = owner
      return next_id
    end
    env.host_api.invalidate_lua_pane = function() end
    env.host_api.close_pane_by_id = function()
      return true
    end
  end)

  it("dispatches identical local IDs only within the owning pane", function()
    local a, ao, aid = create()
    local b, bo, bid = create()
    assert.are_not.equal(aid, bid)
    ao:pointer("click", aid)
    assert.are.equal(1, a.opts.state.hits)
    assert.are.equal(0, b.opts.state.hits)
    assert.are.equal("same", a.opts.state.event_id)
    bo:pointer("click", aid)
    assert.are.equal(0, b.opts.state.hits)
    bo:pointer("click", bid)
    assert.are.equal(1, b.opts.state.hits)
    assert.are.equal(1, a.opts.state.hits)
  end)

  it("exposes pane-local hover in context, without activating callbacks", function()
    local a, ao, aid = create()
    local b, bo = create()
    ao:pointer("hover", aid)
    ao:snapshot(ctx(a.id))
    bo:snapshot(ctx(b.id))
    assert.are.equal("same", a.context.hovered_id)
    assert.is_nil(b.context.hovered_id)
    assert.are.equal(0, a.opts.state.hits)
    ao:pointer("hover", nil)
    ao:snapshot(ctx(a.id))
    assert.is_nil(a.context.hovered_id)
    assert.is_nil(ui._layout_tree)
  end)

  it("takes local keyboard focus on pointer activation", function()
    local pane, owner, id = create()
    owner:pointer("click", id)
    assert.are.equal("same", pane.surface:focused_id())
    assert.is_false(pane.surface.focus_visible)
    assert.is_true(pane.surface.dirty)
    owner:pointer("click", nil)
    assert.are.equal(1, pane.opts.state.hits)
  end)

  it("supports a clickable root node", function()
    local pane, owner = create(function(context)
      return ui.components.button({
        id = "root-button",
        text = "Root",
        on_click = function()
          context.state.hits = context.state.hits + 1
        end,
      })
    end)
    owner:pointer("click", pane.surface.namespace .. "root-button")
    assert.are.equal(1, pane.opts.state.hits)
  end)

  it("releases callbacks and ignores queued input after closing", function()
    local pane, owner, id = create()
    local state = pane.opts.state
    assert.is_true(pane:close())
    owner:pointer("click", id)
    assert.are.equal(0, state.hits)
    owner:destroy()
    owner:pointer("click", id)
    owner:pointer("hover", id)
    assert.are.equal(0, state.hits)
    assert.is_nil(ui.pane.get(pane.id))
    assert.same({}, pane.surface.callbacks)
  end)

  it("does not dispatch retired callbacks after render fails", function()
    local fail = false
    local pane, owner = create(function(context)
      if fail then
        error("broken")
      end
      return ui.components.button({
        id = "old",
        text = "Old",
        on_click = function()
          context.state.hits = context.state.hits + 1
        end,
      })
    end)
    fail = true
    pane:invalidate()
    owner:snapshot(ctx(pane.id))
    owner:pointer("click", pane.surface.namespace .. "old")
    assert.are.equal(0, pane.opts.state.hits)
  end)

  it("allows recovery after a callback error without mixing instances", function()
    local fail = true
    local pane, owner = create(function(context)
      return ui.components.button({
        id = "bad",
        text = "Retry",
        on_click = function()
          if fail then
            error("click failed")
          end
          context.state.hits = context.state.hits + 1
        end,
      })
    end)
    local id = pane.surface.namespace .. "bad"
    assert.has_error(function()
      owner:pointer("click", id)
    end)
    fail = false
    owner:pointer("click", id)
    assert.are.equal(1, pane.opts.state.hits)
  end)

  it("routes buttons and wheel through on_pointer with local IDs", function()
    local events = {}
    local pane = ui.pane.split({
      state = { hits = 0 },
      on_pointer = function(event, context)
        events[#events + 1] = event
        return event.kind == "scroll" and context.state.consume_scroll
      end,
      render = function(context)
        return ui.components.column({
          ui.components.button({
            id = "same",
            text = "Click",
            on_click = function()
              context.state.hits = context.state.hits + 1
            end,
          }),
        }, { id = "list", scroll = true })
      end,
    })
    local owner = owners[pane.id]
    owner:snapshot(ctx(pane.id))
    local id = pane.surface.namespace .. "same"
    assert.is_false(owner:pointer("click", id, "right"))
    assert.are.equal(0, pane.opts.state.hits)
    assert.same({ kind = "click", id = "same", button = "right" }, events[1])
    owner:pointer("click", id, "left")
    assert.are.equal(1, pane.opts.state.hits)
    assert.is_false(owner:pointer("scroll", pane.surface.namespace .. "list", -1))
    assert.same({ kind = "scroll", id = "list", delta = -1 }, events[3])
    pane.opts.state.consume_scroll = true
    assert.is_true(owner:pointer("scroll", nil, 2))
  end)
end)
