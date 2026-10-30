package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("modal layout invalidation", function()
  local hollow, ui, env, queue, now, requests
  before_each(function()
    env = harness.boot()
    hollow, ui = env.hollow, env.hollow.ui
    queue, now, requests = {}, 1000, 0
    env.host_api.defer = function(fn, delay)
      queue[#queue + 1] = { fn = fn, delay = delay }
    end
    env.host_api.now_ms = function()
      return now
    end
    env.host_api.request_redraw = function()
      requests = requests + 1
    end
    env.host_api.request_layout_refresh = function()
      error("overlay invalidation must not relayout panes")
    end
  end)

  local function prepare()
    ui._layout_prepare(800, 600, 8, 19)
    return ui._layout_tree
  end

  it("reuses snapshots and invalidates on events, cleaning listeners on close", function()
    local renders, unmounted = 0, 0
    local handle = require("hollow.ui.modal").modal({
      render = function()
        return {}
      end,
      layout_events = { "test:changed" },
      on_unmount = function()
        unmounted = unmounted + 1
      end,
      render = function()
        renders = renders + 1
        return ui.components.text("value")
      end,
    })
    local tree = prepare()
    assert.equals(tree, prepare())
    assert.equals(1, renders)
    hollow.events.emit("test:changed")
    assert.equals(1, requests)
    prepare()
    assert.equals(2, renders)
    handle.close()
    hollow.events.emit("test:changed")
    assert.equals(1, requests)
    assert.equals(1, unmounted)
  end)

  it("schedules one refresh and ignores stale callbacks after close", function()
    local delay, renders = 100, 0
    local handle = require("hollow.ui.modal").modal({
      render = function()
        return {}
      end,
      layout_refresh_after = function()
        return delay
      end,
      render = function()
        renders = renders + 1
        return ui.components.text("timer")
      end,
    })
    prepare()
    assert.equals(100, queue[1].delay)
    prepare()
    assert.equals(1, #queue)
    queue[1].fn()
    assert.equals(1, requests)
    delay = 1000
    prepare()
    assert.equals(2, renders)
    assert.equals(1000, queue[2].delay)
    handle.close()
    queue[2].fn()
    assert.equals(1, requests)
  end)

  it("does not retain workspace listeners when another modal rejects opening", function()
    require("hollow.ui.workspace.source").items = function()
      return {}
    end
    ui.input.open({ default = "unfinished" })
    local function listener_count()
      local count = 0
      for _ in pairs(require("hollow.state").get().events.handles) do
        count = count + 1
      end
      return count
    end
    local before = listener_count()
    ui.workspace.open_switcher()
    assert.equals(before, listener_count())
    assert.equals(1, ui.overlay.depth())
  end)
end)
