package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Lua pane example", function()
  local env, h, owners, panes, active, jobs, on_key, DEFAULT_FIRST

  local function ctx()
    return {
      pane_id = active,
      cols = 60,
      rows = 20,
      width = 600,
      height = 400,
      cell_w = 10,
      cell_h = 20,
      focused = true,
    }
  end

  local function snapshot()
    return owners[active]:snapshot(ctx())
  end

  local function find(nodes, id)
    for _, node in ipairs(nodes) do
      if node.id == h.ui.pane.get(active).surface.namespace .. id then
        return node
      end
    end
  end

  local function has_text(nodes, text)
    for _, node in ipairs(nodes) do
      if node.text == text then
        return true
      end
    end
    return false
  end

  local function complete(index, result)
    local job = jobs[index]
    job.result = result
    env.flush_deferred()
  end

  before_each(function()
    env = harness.boot()
    h, owners, panes, active, jobs = env.hollow, {}, {}, nil, {}
    env.host_api.current_pane_id = function()
      return active
    end
    env.host_api.create_lua_pane = function(owner)
      local id = 200 + #panes + 1
      owners[id] = owner
      panes[#panes + 1] = { id = id, kind = "lua", module = "tasks" }
      active = id
      return id
    end
    env.host_api.close_pane_by_id = function(id)
      for index, pane in ipairs(panes) do
        if pane.id == id then
          table.remove(panes, index)
        end
      end
      owners[id]:destroy()
      owners[id] = nil
      return true
    end
    env.host_api.invalidate_lua_pane = function() end
    env.host_api.process_start = function(opts)
      jobs[#jobs + 1] = { cmd = opts.cmd }
      return #jobs
    end
    env.host_api.process_poll = function(handle)
      return jobs[handle].result
    end
    env.host_api.process_cancel = function(handle)
      jobs[handle].result = { code = -1, error = "Canceled", canceled = true }
    end
    DEFAULT_FIRST = h.platform.is_windows and "cmd /c ver" or "uname -sr"
    -- Config load at startup runs before any tab exists.
    h.term.current_tab = function() end
    assert(loadfile("examples/lua-pane.lua"))()
    h.term.current_tab = function()
      return { panes = panes }
    end
    on_key = env.get_key_handler()
    h.events.emit("gui:ready")
    snapshot()
  end)

  it("opens the registered tasks factory on gui:ready", function()
    assert.equals(1, #panes)
    local nodes = snapshot()
    assert.is_true(has_text(nodes, DEFAULT_FIRST))
    assert.is_not_nil(find(nodes, "run:1"))
    assert.is_not_nil(find(nodes, "command"))
  end)

  it("opens once when loaded into a running window", function()
    assert(loadfile("examples/lua-pane.lua"))()
    env.flush_deferred()
    assert.equals(1, #panes)
    owners[active]:destroy()
    panes = {}
    assert(loadfile("examples/lua-pane.lua"))()
    env.flush_deferred()
    assert.equals(1, #panes)
  end)

  it("runs a task asynchronously and repaints on completion", function()
    local pane = h.ui.pane.get(active)
    owners[active]:pointer("click", pane.surface.namespace .. "run:1", "left")
    assert.equals(DEFAULT_FIRST:match("%S+"), jobs[1].cmd[1])
    assert.is_true(has_text(snapshot(), "Cancel"))
    complete(1, { code = 0, stdout = "Linux 6.6.87\n", stderr = "" })
    assert.is_true(pane.surface.dirty)
    local nodes = snapshot()
    assert.is_true(has_text(nodes, "Linux 6.6.87"))
    assert.is_true(has_text(nodes, "ok"))
  end)

  it("adds typed commands with Enter and navigates with arrows", function()
    local pane = h.ui.pane.get(active)
    pane.surface:focus("command")
    for char in ("echo hi"):gmatch(".") do
      on_key(char == " " and "space" or char, 0)
    end
    assert.is_true(on_key("enter", 0))
    assert.is_true(has_text(snapshot(), "echo hi"))
    pane.surface:focus("run:1")
    local bounds = {}
    for index = 1, 4 do
      bounds[pane.surface.namespace .. "run:" .. index] =
        { x = 0, y = index * 30, width = 40, height = 20 }
    end
    pane.surface.focus_bounds = bounds
    assert.is_true(on_key("arrow_down", 0))
    assert.equals("run:2", pane.surface:focused_id())
  end)

  it("runs @domain tasks through the domain's agent host", function()
    local async = require("hollow.async")
    local connect, exec, ops, requested = nil, nil, {}, {}
    h.host.for_domain = function(name)
      requested[#requested + 1] = name
      return async.promise(function(resolve)
        connect = resolve
      end)
    end
    local host = {
      exec = function(_, opts)
        ops[#ops + 1] = opts
        local promise = async.promise(function(resolve)
          exec = resolve
        end)
        function promise:cancel()
          ops.canceled = true
        end
        return promise
      end,
    }
    -- The leading @ opens the picker; canceling it keeps the @ for a prefix.
    h.ui.select.open = function() end
    local pane = h.ui.pane.get(active)
    pane.surface:focus("command")
    for char in ("@dev uname -a"):gmatch(".") do
      on_key(char == " " and "space" or char, 0)
    end
    on_key("enter", 0)
    local nodes = snapshot()
    assert.is_true(has_text(nodes, "uname -a"))
    assert.is_true(has_text(nodes, "@dev"))
    assert.is_true(has_text(nodes, "@local"))

    owners[active]:pointer("click", pane.surface.namespace .. "run:4", "left")
    assert.are.same({ "dev" }, requested)
    assert.is_true(has_text(snapshot(), "connecting"))
    connect(host)
    env.flush_deferred()
    assert.are.same({ "uname", "-a" }, ops[1].argv)
    assert.is_true(has_text(snapshot(), "running"))
    exec({ exit_code = 0, stdout = "Linux dev 6.6\n", stderr = "" })
    env.flush_deferred()
    nodes = snapshot()
    assert.is_true(has_text(nodes, "Linux dev 6.6"))
    assert.is_true(has_text(nodes, "ok"))

    owners[active]:pointer("click", pane.surface.namespace .. "run:4", "left")
    connect(host)
    env.flush_deferred()
    owners[active]:pointer("click", pane.surface.namespace .. "run:4", "left")
    assert.is_true(ops.canceled)
    assert.is_true(has_text(snapshot(), "canceled"))
  end)

  it("picks the domain for new tasks with the @ button", function()
    local picker
    h.ui.select.open = function(opts)
      picker = opts
    end
    h.ui.select.close = function() end
    local pane = h.ui.pane.get(active)
    owners[active]:pointer("click", pane.surface.namespace .. "domain", "left")
    assert.equals("local", picker.items[1])
    picker.actions[1].fn("dev")
    assert.is_true(has_text(snapshot(), "@dev"))
    pane.surface:focus("command")
    on_key("w", 0)
    on_key("enter", 0)
    local nodes = snapshot()
    assert.is_true(has_text(nodes, "w"))
    local count = 0
    for _, node in ipairs(nodes) do
      if node.text == "@dev" then
        count = count + 1
      end
    end
    assert.equals(2, count)
  end)

  it("opens the domain picker when @ is typed into the empty input", function()
    local opened = 0
    local picker
    h.ui.select.open = function(opts)
      opened, picker = opened + 1, opts
    end
    h.ui.select.close = function() end
    local pane = h.ui.pane.get(active)
    pane.surface:focus("command")
    on_key("digit_2", 1)
    assert.equals(1, opened)
    picker.actions[1].fn("dev")
    local nodes = snapshot()
    assert.is_true(has_text(nodes, "@dev"))
    assert.is_false(has_text(nodes, "@"))

    on_key("x", 0)
    on_key("digit_2", 1)
    on_key("backspace", 0)
    on_key("backspace", 0)
    on_key("digit_2", 1)
    assert.equals(2, opened)
  end)

  it("toggles with <leader>T and cancels running jobs on close", function()
    local pane = h.ui.pane.get(active)
    owners[active]:pointer("click", pane.surface.namespace .. "run:2", "left")
    local binding = h.keymap.get("<leader>T")
    binding()
    assert.equals(0, #panes)
    assert.is_true(jobs[1].result.canceled)
    binding()
    assert.equals(1, #panes)
  end)
end)
