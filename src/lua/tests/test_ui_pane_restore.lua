package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Lua pane factories", function()
  local env, ui, json, owners, created
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

  before_each(function()
    env = harness.boot()
    ui, json, owners, created = env.hollow.ui, env.hollow.json, {}, 0
    env.host_api.create_lua_pane = function(owner)
      created = created + 1
      owners[1000 + created] = owner
      return 1000 + created
    end
    env.host_api.invalidate_lua_pane = function() end
    env.host_api.title_lua_pane = function() end
  end)

  it("builds factory options from independent JSON args and saves creation-time args", function()
    ui.pane.register("tasks", function(args)
      args.nested.label = "factory copy"
      return {
        state = { label = args.nested.label },
        render = function()
          return ui.components.text("Tasks")
        end,
      }
    end)
    local args = { nested = { label = "original" }, list = { 1, false, "three" } }
    local pane = ui.pane.split({ module = "tasks", args = args, ratio = 0.4 })
    assert.are.equal("original", args.nested.label)
    assert.are.equal("factory copy", pane.opts.state.label)
    args.nested.label = "later mutation"
    local descriptor = json.decode(owners[pane.id]._descriptor)
    assert.are.equal("tasks", descriptor.module)
    assert.are.equal("original", descriptor.args.nested.label)
    assert.same({ 1, false, "three" }, descriptor.args.list)
    assert.are.equal(0.4, owners[pane.id].ratio)
    assert.is_nil(descriptor.render)
    assert.is_nil(descriptor.state)
  end)

  it(
    "restores the same ID with fresh state and callback namespace, without creating a native pane",
    function()
      local mounts, unmounts, calls = 0, 0, 0
      ui.pane.register("tasks", function(args)
        calls = calls + 1
        return {
          state = { count = args.count },
          render = function(context)
            return ui.components.text(context.state.count)
          end,
          on_mount = function()
            mounts = mounts + 1
          end,
          on_unmount = function()
            unmounts = unmounts + 1
          end,
        }
      end)
      local pane = ui.pane.split({ module = "tasks", args = { count = 7 } })
      local owner = owners[pane.id]
      owner:snapshot(ctx(pane.id))
      pane.opts.state.count = 99
      local descriptor, namespace = owner._descriptor, pane.surface.namespace
      owner:destroy()
      local restored = ui.pane._restore(pane.id, descriptor)
      local instance = ui.pane.get(pane.id)
      assert.are.equal(1, created)
      assert.are.equal(2, calls)
      assert.are.equal(7, instance.opts.state.count)
      assert.are_not.equal(namespace, instance.surface.namespace)
      restored:snapshot(ctx(pane.id))
      assert.are.equal(2, mounts)
      assert.are.equal(1, unmounts)
    end
  )

  it("restores an explicit creation title over the factory title", function()
    local titles = {}
    env.host_api.title_lua_pane = function(id, title)
      titles[id] = title
    end
    ui.pane.register("tasks", function()
      return {
        title = "Factory",
        render = function()
          return ui.components.text("Tasks")
        end,
      }
    end)
    local pane = ui.pane.split({ module = "tasks", title = "Custom" })
    local descriptor = owners[pane.id]._descriptor
    owners[pane.id]:destroy()
    titles[pane.id] = nil
    ui.pane._restore(pane.id, descriptor)
    assert.are.equal("Custom", titles[pane.id])
  end)

  it("restores one instance without disturbing another factory instance", function()
    ui.pane.register("tasks", function(args)
      return {
        state = { name = args.name },
        render = function()
          return ui.components.text(args.name)
        end,
      }
    end)
    local a = ui.pane.split({ module = "tasks", args = { name = "A" } })
    local b = ui.pane.split({ module = "tasks", args = { name = "B" } })
    local descriptor = owners[a.id]._descriptor
    owners[a.id]:destroy()
    ui.pane._restore(a.id, descriptor)
    assert.are.equal("A", ui.pane.get(a.id).opts.state.name)
    assert.are.equal(b, ui.pane.get(b.id))
    assert.are.equal("B", b.opts.state.name)
    assert.are.equal(2, created)
  end)

  it("rejects missing/broken factories without publishing an instance", function()
    assert.has_error(function()
      ui.pane.split({ module = "missing" })
    end)
    ui.pane.register("broken", function()
      return "not options"
    end)
    assert.has_error(function()
      ui.pane.split({ module = "broken" })
    end)
    ui.pane.register("no-render", function()
      return {}
    end)
    assert.has_error(function()
      ui.pane.split({ module = "no-render" })
    end)
    assert.has_error(function()
      ui.pane._restore(77, json.encode({ module = "missing" }))
    end)
    assert.is_nil(ui.pane.get(77))
    assert.are.equal(0, created)
  end)

  it("validates registration names and factory functions", function()
    assert.has_error(function()
      ui.pane.register("", function() end)
    end)
    assert.has_error(function()
      ui.pane.register("bad\0name", function() end)
    end)
    assert.has_error(function()
      ui.pane.register("tasks", {})
    end)
  end)

  it("rejects cycles, sparse/mixed arrays, metatables and non-JSON args", function()
    local cycle = {}
    cycle.self = cycle
    local values = {
      cycle,
      { fn = function() end },
      { n = 0 / 0 },
      { n = math.huge },
      { [2] = "sparse" },
      { [1] = 1, name = "mixed" },
      setmetatable({}, {}),
    }
    for _, args in ipairs(values) do
      assert.has_error(function()
        ui.pane.split({
          args = args,
          render = function()
            return ui.components.text("Bad")
          end,
        })
      end)
    end
    assert.are.equal(0, created)
  end)

  it("bounds descriptor size and nesting before native allocation", function()
    local deep = {}
    local root = deep
    for _ = 1, 40 do
      deep.next = {}
      deep = deep.next
    end
    local render = function()
      return ui.components.text("Bad")
    end
    assert.has_error(function()
      ui.pane.split({ render = render, args = root })
    end)
    assert.has_error(function()
      ui.pane.split({ render = render, args = { text = string.rep("x", 65536) } })
    end)
    assert.are.equal(0, created)
  end)

  it("keeps direct render panes usable without a registered factory", function()
    local pane = ui.pane.split({
      render = function()
        return ui.components.text("Transient")
      end,
    })
    assert.is_nil(json.decode(owners[pane.id]._descriptor).module)
    assert.are.equal(pane, ui.pane.get(pane.id))
  end)
end)
