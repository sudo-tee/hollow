package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("docked sidebar", function()
  local env, ui, owners, closes, next_id, focused
  local function context(id, hovered)
    return {
      pane_id = id,
      cols = 30,
      rows = 20,
      width = 300,
      height = 400,
      cell_w = 10,
      cell_h = 20,
      focused = true,
      hovered_id = hovered,
    }
  end

  before_each(function()
    env = harness.boot()
    ui, owners, closes, next_id, focused = env.hollow.ui, {}, {}, 600, nil
    env.host_api.create_lua_pane = function(owner)
      next_id = next_id + 1
      owners[next_id] = owner
      return next_id
    end
    env.host_api.invalidate_lua_pane = function() end
    env.host_api.title_lua_pane = function() end
    env.host_api.focus_pane_by_id = function(id)
      focused = id
      return true
    end
    env.host_api.close_pane_by_id = function(id)
      closes[#closes + 1] = id
      return true
    end
  end)

  local function mount(log)
    ui.sidebar.mount(ui.sidebar.new({
      width = 24,
      style = { bg = "#101010", border = "#ff00ff" },
      render = function()
        return ui.column({
          ui.row({
            ui.text("HEAD", { bold = true }),
            ui.spacer(),
            ui.button({
              id = "go",
              text = "go",
              style = { bg = "#222222", hover = { bg = "#333333" } },
              on_click = function(event)
                log[#log + 1] = "click " .. event.id
              end,
              on_mouse_enter = function()
                log[#log + 1] = "enter"
              end,
              on_mouse_leave = function()
                log[#log + 1] = "leave"
              end,
            }),
          }),
          ui.divider("#444444"),
          ui.row({ ui.text("docked? " .. tostring(ui.sidebar.is_docked())) }),
        })
      end,
    }))
  end

  local function texts(nodes)
    local out = {}
    for _, node in ipairs(nodes) do
      if node.text then
        out[#out + 1] = node.text
      end
    end
    return table.concat(out, "|")
  end

  local function find(nodes, local_id)
    for _, node in ipairs(nodes) do
      if node.id and node.id:sub(-#local_id - 1) == ":" .. local_id then
        return node
      end
    end
  end

  it("moves between the native overlay and a split Lua pane", function()
    local log = {}
    mount(log)
    assert.is_table(ui._sidebar_state())
    local pane = assert(ui.sidebar.dock())
    local owner = assert(owners[pane.id])
    local descriptor = env.hollow.json.decode(owner._descriptor)
    assert.are.equal("hollow.sidebar", descriptor.module)
    assert.are.equal("left", descriptor.edge)
    assert.is_true(ui.sidebar.is_docked())
    assert.is_nil(ui._sidebar_state())
    owner:complete(true)
    assert.are.equal(env.hollow.term.current_pane().id, focused)

    local nodes = owner:snapshot(context(pane.id))
    assert.matches("HEAD|go|docked? true", texts(nodes), 1, true)
    local go = assert(find(nodes, "go"))
    assert.are.equal("#333333", go.hover_bg)
    assert.is_true(go.clickable)
    owner:pointer("click", go.id, "left")
    assert.same({ "click go" }, log)
    owner:pointer("hover", go.id)
    owner:snapshot(context(pane.id, "go"))
    owner:pointer("hover", nil)
    owner:snapshot(context(pane.id))
    assert.same({ "click go", "enter", "leave" }, log)

    assert.is_nil(ui.sidebar.dock())
    assert.same({ pane.id }, closes)
    owner:destroy()
    assert.is_false(ui.sidebar.is_docked())
    assert.is_table(ui._sidebar_state())
  end)

  it("hides instead of undocking when toggled or unmounted", function()
    mount({})
    local pane = assert(ui.sidebar.dock())
    owners[pane.id]:snapshot(context(pane.id))
    assert.is_false(ui.sidebar.toggle())
    owners[pane.id]:destroy()
    assert.is_false(ui.sidebar.is_docked())
    assert.is_nil(ui._sidebar_state())
    assert.is_true(ui.sidebar.toggle())
    assert.is_table(ui._sidebar_state())

    pane = assert(ui.sidebar.dock())
    owners[pane.id]:snapshot(context(pane.id))
    ui.sidebar.unmount()
    owners[pane.id]:destroy()
    assert.is_nil(ui._sidebar_state())
    assert.is_nil(ui.sidebar.dock())
  end)

  it("docks on the window edge matching the sidebar side", function()
    ui.sidebar.mount(ui.sidebar.new({
      side = "right",
      render = function()
        return ui.row({ ui.text("x") })
      end,
    }))
    local pane = assert(ui.sidebar.dock())
    assert.are.equal("right", env.hollow.json.decode(owners[pane.id]._descriptor).edge)
    assert.has_error(function()
      ui.pane.split({ edge = "middle", render = function() end })
    end)
  end)

  it("accepts component-native content on the edge and in the docked pane", function()
    local hits = {}
    local c = ui.components
    ui.sidebar.mount(ui.sidebar.new({
      width = 27,
      style = { bg = "#112233" },
      render = function()
        return c.column({
          c.button({
            id = "native",
            text = "Native",
            on_click = function()
              hits[#hits + 1] = "native"
            end,
          }),
        })
      end,
    }))
    assert.equals(27, ui._sidebar_state().width)
    ui._sidebar_layout_prepare(800, 600, 10, 20)
    assert.is_table(ui._sidebar_layout_tree)
    local sidebar = require("hollow.state").get().ui.mounted_sidebar
    local surface = assert(sidebar._sidebar_surface)
    local button = assert(find(ui._sidebar_layout_tree, "native"))
    assert.is_true(button.clickable)
    env.hollow._emit_builtin_event("sidebar:click", { id = button.id })
    assert.same({ "native" }, hits)

    local pane = assert(ui.sidebar.dock())
    assert.is_nil(ui._sidebar_state())
    local owner = assert(owners[pane.id])
    local nodes = owner:snapshot(context(pane.id))
    assert.is_truthy(find(nodes, "native"))
    assert.matches("Native", texts(nodes), 1, true)
    owner:destroy()
    assert.is_table(ui._sidebar_state())
    ui._sidebar_layout_prepare(800, 600, 10, 20)
    assert.equals(surface, sidebar._sidebar_surface)
  end)

  it("destroys the edge surface and removes callbacks on unmount", function()
    local clicks = 0
    ui.sidebar.mount(ui.sidebar.new({
      render = function()
        return ui.row({
          ui.button({
            id = "old",
            text = "Old",
            on_click = function()
              clicks = clicks + 1
            end,
          }),
        })
      end,
    }))
    ui._sidebar_layout_prepare(800, 600, 10, 20)
    local widget = require("hollow.state").get().ui.mounted_sidebar
    local surface = assert(widget._sidebar_surface)
    local id = surface.namespace .. "old"
    env.hollow._emit_builtin_event("sidebar:click", { id = id })
    assert.equals(1, clicks)
    ui.sidebar.unmount()
    assert.is_true(surface.destroyed)
    assert.is_nil(widget._sidebar_surface)
    assert.is_nil(ui._sidebar_state())
    ui._sidebar_layout_prepare(800, 600, 10, 20)
    assert.is_nil(ui._sidebar_layout_tree)
    env.hollow._emit_builtin_event("sidebar:click", { id = id })
    assert.equals(1, clicks)
  end)

  it("dispatches edge clicks by authored span id and keeps row accent bars", function()
    local clicks = 0
    ui.sidebar.mount(ui.sidebar.new({
      render = function()
        return ui.row({
          ui.button({
            id = "authored",
            text = "Authored",
            on_click = function()
              clicks = clicks + 1
            end,
          }),
        }, { accent_bar = "#ff0000" })
      end,
    }))
    ui._sidebar_layout_prepare(800, 600, 10, 20)
    env.hollow._emit_builtin_event("sidebar:click", { id = "authored" })
    assert.equals(1, clicks)
    local accented
    for _, node in ipairs(ui._sidebar_layout_tree) do
      if node.border == "#ff0000" then
        accented = node
      end
    end
    assert.is_table(accented)
    assert.equals(2, accented.border_width.left)
  end)

  it("restores the overlay when docking fails", function()
    mount({})
    local pane = assert(ui.sidebar.dock())
    owners[pane.id]:complete(false)
    assert.is_false(ui.sidebar.is_docked())
    assert.is_table(ui._sidebar_state())
  end)
end)
