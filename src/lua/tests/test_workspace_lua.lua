package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("workspace Lua leaves", function()
  local env, h, owners, requests, workspaces, active, next_id, titles
  local function workspace()
    return workspaces[active]
  end
  local function tab()
    return workspace().tabs[workspace().active_tab]
  end
  local function current()
    for _, pane in ipairs(tab().panes) do
      if pane.id == tab().active_id then
        return pane
      end
    end
  end
  local function snapshot_tabs()
    for _, t in ipairs(workspace().tabs) do
      for _, p in ipairs(t.panes) do
        p.is_focused = p.id == tab().active_id
      end
    end
    return workspace().tabs
  end

  before_each(function()
    env = harness.boot()
    h, owners, requests, active, next_id, titles = env.hollow, {}, {}, 1, 1000, {}
    workspaces = {
      {
        name = "original",
        active_tab = 1,
        tabs = {
          {
            title = "shell",
            active_id = 101,
            panes = {
              {
                id = 101,
                kind = "terminal",
                cwd = "/tmp/project",
                domain = "wsl",
                title = "shell",
                tags = {},
              },
            },
          },
        },
      },
    }
    h.term.current_pane = current
    h.term.tabs = snapshot_tabs
    h.term.current_workspace = function()
      return { index = active, name = workspace().name }
    end
    h.term.workspaces = function()
      local snapshot = {}
      for index, ws in ipairs(workspaces) do
        snapshot[index] = { index = index, name = ws.name }
      end
      return snapshot
    end
    h.term.switch_workspace = function(index)
      active = index
    end
    h.term.close_workspace = function()
      local old = table.remove(workspaces, active)
      for _, t in ipairs(old.tabs) do
        for _, p in ipairs(t.panes) do
          if owners[p.id] then
            owners[p.id]:destroy()
          end
        end
      end
      active = math.min(active, #workspaces)
    end
    h.term.set_pane_tags = function(tags, id)
      for _, p in ipairs(tab().panes) do
        if p.id == (id or tab().active_id) then
          p.tags = tags
        end
      end
    end
    h.term.focus_pane_by_id = function(id)
      for i, t in ipairs(workspace().tabs) do
        for _, p in ipairs(t.panes) do
          if p.id == id then
            workspace().active_tab = i
            t.active_id = id
            return true
          end
        end
      end
      return false
    end
    h.term.set_title = function(title)
      tab().title = title
    end
    h.term.set_workspace_default_cwd = function() end
    h.term.send_text = function()
      error("Lua leaves must not send terminal input")
    end
    h.term.new_workspace = function()
      error("must not spawn a seed terminal")
    end
    h.term.new_tab = function()
      error("must not spawn a seed terminal")
    end
    h.term.split_pane = function()
      error("must not spawn a terminal split")
    end
    env.host_api.title_lua_pane = function(id, title)
      titles[id] = title
    end
    env.host_api.invalidate_lua_pane = function() end
    env.host_api.create_lua_pane = function(owner)
      next_id = next_id + 1
      local id = next_id
      local descriptor = h.json.decode(owner._descriptor)
      requests[#requests + 1] = descriptor
      owners[id] = owner
      env.host_api.defer(function()
        if descriptor.placement == "workspace" then
          workspaces[#workspaces + 1] = { name = descriptor.name, tabs = {}, active_tab = 0 }
          active = #workspaces
        end
        if descriptor.placement ~= "split" then
          workspace().tabs[#workspace().tabs + 1] =
            { title = descriptor.name or "Lua tab", panes = {} }
          workspace().active_tab = #workspace().tabs
        end
        tab().panes[#tab().panes + 1] = {
          id = id,
          kind = "lua",
          module = descriptor.module,
          args = descriptor.args,
          title = titles[id] or "Tasks",
          tags = {},
          is_floating = descriptor.floating,
          direction = descriptor.placement == "split" and owner.direction or nil,
          split_ratio = descriptor.placement == "split" and owner.ratio or nil,
          floating_bounds = descriptor.floating and {
            x = descriptor.x,
            y = descriptor.y,
            width = descriptor.width,
            height = descriptor.height,
          } or nil,
        }
        tab().active_id = id
        owner:complete(true)
      end)
      return id
    end
    h.ui.pane.register("tasks", function(args)
      return {
        title = args.name or "Tasks",
        state = {},
        render = function()
          return h.ui.components.text("Tasks")
        end,
      }
    end)
  end)

  it("adds a factory-backed leaf beside a reused terminal without sending it commands", function()
    h.workspace.bootstrap({
      tabs = {
        {
          panes = {
            {},
            {
              lua = "tasks",
              args = { name = "Build" },
              direction = "horizontal",
              size = 0.3,
              main = true,
              tags = { "ui" },
            },
          },
        },
      },
    })
    env.flush_deferred()
    assert.are.equal("split", requests[1].placement)
    assert.are.equal(2, #tab().panes)
    assert.are.equal(1001, current().id)
    local leaf = h.workspace.export_current().tabs[1].panes[2]
    assert.are.equal("tasks", leaf.lua)
    assert.same({ name = "Build" }, leaf.args)
    assert.are.equal("horizontal", leaf.direction)
    assert.are.equal(0.3, leaf.size)
    assert.is_true(leaf.main)
    assert.same({ "ui" }, leaf.tags)
    assert.is_nil(leaf.command)
    assert.is_nil(leaf.domain)
  end)

  it("builds Lua-only workspaces/tabs without creating temporary PTYs", function()
    h.workspace.bootstrap({
      tabs = {
        { name = "One", panes = { { lua = "tasks", args = { name = "A" } } } },
        { name = "Two", panes = { { lua = "tasks", args = { name = "B" }, main = true } } },
      },
    }, { replace_current = true })
    env.flush_deferred()
    assert.are.equal("workspace", requests[1].placement)
    assert.are.equal("tab", requests[2].placement)
    assert.are.equal(1, #workspaces)
    assert.are.equal(2, #workspace().tabs)
    assert.are.equal("lua", workspace().tabs[1].panes[1].kind)
    assert.are.equal("lua", workspace().tabs[2].panes[1].kind)
    assert.are.equal(1002, current().id)
  end)

  it(
    "preserves the existing tab when Lua-first bootstrap does not replace the workspace",
    function()
      h.workspace.bootstrap({ tabs = { { panes = { { lua = "tasks" } } } } })
      env.flush_deferred()
      assert.are.equal("tab", requests[1].placement)
      assert.are.equal(2, #workspace().tabs)
      assert.are.equal(101, workspace().tabs[1].panes[1].id)
      assert.are.equal("lua", current().kind)
    end
  )

  it("round-trips exported factory args, split ratios and floating bounds", function()
    h.workspace.bootstrap({
      tabs = {
        {
          name = "UI",
          panes = {
            { lua = "tasks", args = { name = "A" } },
            {
              lua = "tasks",
              args = { name = "B" },
              floating = true,
              x = 0.2,
              y = 0.3,
              width = 0.4,
              height = 0.5,
              size = 0.35,
              main = true,
            },
          },
        },
      },
    }, { replace_current = true })
    env.flush_deferred()
    local exported = h.json.decode(h.json.encode(h.workspace.export_current()))
    local old_id = current().id
    h.workspace.bootstrap(exported, { replace_current = true })
    env.flush_deferred()
    assert.are.equal(1, #workspaces)
    assert.are.equal(2, #tab().panes)
    assert.are_not.equal(old_id, current().id)
    assert.is_true(current().is_floating)
    assert.same({ x = 0.2, y = 0.3, width = 0.4, height = 0.5 }, current().floating_bounds)
    assert.same({ name = "B" }, current().args)
    assert.are.equal(0.35, current().split_ratio)
  end)

  it("round-trips hidden panes, hiding them only once the tab is built", function()
    local hidden_calls = {}
    h.term.set_pane_visible = function(id, visible)
      hidden_calls[#hidden_calls + 1] = { id = id, visible = visible, built = #requests }
      for _, p in ipairs(tab().panes) do
        if p.id == id then
          p.is_hidden = not visible
        end
      end
    end
    h.workspace.bootstrap({
      tabs = {
        {
          name = "UI",
          panes = {
            { lua = "tasks", args = { name = "A" }, hidden = true },
            { lua = "tasks", args = { name = "B" }, main = true },
            { lua = "tasks", args = { name = "C" }, hidden = true },
          },
        },
      },
    }, { replace_current = true })
    env.flush_deferred()
    assert.are.equal(2, #hidden_calls)
    assert.same({ id = 1001, visible = false, built = 3 }, hidden_calls[1])
    assert.same({ id = 1003, visible = false, built = 3 }, hidden_calls[2])

    local exported = h.json.decode(h.json.encode(h.workspace.export_current()))
    local panes = exported.tabs[1].panes
    assert.is_true(panes[1].hidden)
    assert.is_nil(panes[2].hidden)
    assert.is_true(panes[3].hidden)

    hidden_calls = {}
    h.workspace.bootstrap(exported, { replace_current = true })
    env.flush_deferred()
    assert.are.equal(2, #hidden_calls)
    assert.is_true(tab().panes[1].is_hidden)
    assert.is_nil(tab().panes[2].is_hidden)
    assert.is_true(tab().panes[3].is_hidden)
  end)

  it("round-trips edge placement, creating edge panes after ordinary splits", function()
    local splits = {}
    h.term.split_pane = function(opts)
      splits[#splits + 1] = opts
      next_id = next_id + 1
      local id = next_id
      tab().panes[#tab().panes + 1] = {
        id = id,
        kind = "terminal",
        cwd = "/tmp/project",
        tags = {},
        direction = opts.direction,
        split_ratio = opts.ratio,
        edge = opts.edge,
      }
      tab().active_id = id
      env.host_api.defer(function()
        opts.on_complete({ success = true, pane_id = id })
      end)
    end
    h.workspace.bootstrap({
      tabs = {
        {
          panes = {
            { cwd = "/tmp/project" },
            { edge = "right", size = 0.3, direction = "horizontal" },
            { direction = "horizontal", size = 0.4 },
            { edge = "bottom", size = 0.2 },
          },
        },
      },
    })
    env.flush_deferred()
    assert.are.equal(3, #splits)
    assert.are.equal("horizontal", splits[1].direction)
    assert.is_nil(splits[1].edge)
    assert.same({ "right", 0.3 }, { splits[2].edge, splits[2].ratio })
    assert.is_nil(splits[2].direction)
    assert.same({ "bottom", 0.2 }, { splits[3].edge, splits[3].ratio })

    local panes = h.workspace.export_current().tabs[1].panes
    assert.is_nil(panes[2].edge)
    assert.are.equal("right", panes[3].edge)
    assert.are.equal("bottom", panes[4].edge)
  end)

  it("exports hidden terminal panes", function()
    workspace().tabs[1].panes[1].is_hidden = true
    assert.is_true(h.workspace.export_current().tabs[1].panes[1].hidden)
  end)

  it("omits anonymous Lua panes and tabs from export", function()
    h.ui.pane._create({
      render = function()
        return h.ui.components.text("Transient")
      end,
    }, "tab")
    env.flush_deferred()
    local exported = h.workspace.export_current()
    assert.are.equal(1, #exported.tabs)
    assert.are.equal(1, #exported.tabs[1].panes)
    assert.are.equal("/tmp/project", exported.tabs[1].panes[1].cwd)
  end)

  it("loads host/local JSON leaves without executing a factory or terminal command", function()
    local calls = 0
    h.ui.pane.register("tasks", function()
      calls = calls + 1
      error("must not execute on read")
    end)
    env.host_api.read_file = function()
      return '{"tabs":[{"panes":[{"lua":"tasks","args":{"name":"Read only"}}]}]}'
    end
    local spec = h.workspace.load("workspace.json")
    assert.are.equal("tasks", spec.tabs[1].panes[1].lua)
    assert.are.equal(0, calls)
    assert.are.equal(0, #requests)
  end)

  it("rejects malformed Lua leaves instead of interpreting them as terminals", function()
    for _, leaf in ipairs({
      { lua = false },
      { kind = "lua" },
      { lua = "" },
      { lua = "tasks", args = false },
    }) do
      assert.has_error(function()
        h.workspace.bootstrap({ tabs = { { panes = { leaf } } } })
      end)
    end
    assert.are.equal(0, #requests)
    assert.are.equal(1, #workspace().tabs)
  end)

  it("preserves the workspace name independently of its first Lua tab", function()
    h.workspace.bootstrap(
      { name = "Project", tabs = { { name = "Panel", panes = { { lua = "tasks" } } } } },
      { replace_current = true }
    )
    env.flush_deferred()
    assert.are.equal("Project", workspace().name)
    local exported = h.workspace.export_current()
    h.workspace.bootstrap(exported, { replace_current = true })
    env.flush_deferred()
    assert.are.equal("Project", workspace().name)
  end)
end)
