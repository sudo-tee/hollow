package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay activity", function()
  local env, hollow, ui, entries, running, dismissed
  before_each(function()
    env = harness.boot()
    hollow, ui = env.hollow, env.hollow.ui
    entries, running, dismissed = {}, {}, {}
    hollow.activity.list = function()
      return entries
    end
    hollow.activity.running = function()
      return running
    end
    hollow.activity.summary = function()
      return { count = #entries }
    end
    hollow.activity.dismiss = function(id)
      dismissed[#dismissed + 1] = id
      for i, entry in ipairs(entries) do
        if entry.id == id then
          table.remove(entries, i)
          break
        end
      end
    end
    hollow.activity.dismiss_all = function()
      entries = {}
    end
  end)

  local function tree()
    ui._layout_prepare(800, 600, 8, 19)
    return ui._layout_tree
  end
  local function find(suffix)
    for _, node in ipairs(tree()) do
      if node.id and node.id:sub(-#suffix) == suffix then
        return node
      end
    end
  end
  local function text()
    local out = {}
    for _, node in ipairs(tree()) do
      if node.kind == 2 then
        out[#out + 1] = node.text
      end
    end
    return table.concat(out, "|")
  end
  local function key(k)
    ui.dispatch_overlay_key(k, 0)
  end
  local function entry(id, title)
    return {
      id = id,
      kind = "notification",
      title = title,
      message = "message",
      pending = true,
      level = "info",
    }
  end

  it("keeps empty activity idle and ignores timers after close", function()
    local queue, requests = {}, 0
    env.host_api.defer = function(fn, delay)
      queue[#queue + 1] = { fn = fn, delay = delay }
    end
    env.host_api.request_redraw = function()
      requests = requests + 1
    end
    env.host_api.request_layout_refresh = function()
      error("overlay invalidation must not relayout panes")
    end
    local handle = ui.activity.open()
    local first = tree()
    assert.equals(first, tree())
    assert.equals(0, #queue)
    running[1] =
      { id = "task:one", kind = "program", state = "working", started_ms = env.recorded.now_ms }
    hollow.events.emit("activity:changed", {})
    tree()
    assert.equals(1, #queue)
    handle.close()
    local before = requests
    queue[1].fn()
    assert.equals(before, requests)
  end)

  it("refreshes spinner and elapsed labels only when their timer is due", function()
    local queue = {}
    env.host_api.defer = function(fn, delay)
      queue[#queue + 1] = { fn = fn, delay = delay }
    end
    running[1] = {
      id = "task:one",
      kind = "program",
      state = "working",
      app = "Compiler",
      started_ms = env.recorded.now_ms,
    }
    local handle = ui.activity.open()
    local first, initial = tree(), text()
    assert.is_true(queue[1].delay > 0 and queue[1].delay <= 100)
    assert.equals(first, tree())
    env.recorded.now_ms = env.recorded.now_ms + queue[1].delay
    queue[1].fn()
    assert.not_equals(first, tree())
    assert.not_equals(initial, text())
    handle.close()
  end)

  it("updates elapsed seconds without a spinner or continuous rebuilding", function()
    local queue = {}
    env.host_api.defer = function(fn, delay)
      queue[#queue + 1] = { fn = fn, delay = delay }
    end
    running[1] = {
      id = "task:one",
      kind = "program",
      state = "blocked",
      app = "Compiler",
      started_ms = env.recorded.now_ms,
    }
    local handle = ui.activity.open()
    local first = tree()
    assert.equals(1000, queue[1].delay)
    assert.equals(first, tree())
    assert.is_truthy(text():find("0s", 1, true))
    env.recorded.now_ms = env.recorded.now_ms + 1000
    queue[1].fn()
    assert.is_truthy(text():find("1s", 1, true))
    assert.equals(1000, queue[2].delay)
    handle.close()
  end)

  it("uses Clay and preserves modal ownership on repeated opens", function()
    ui.activity.open()
    assert.is_not_nil(find(":activity:viewport"))
    assert.equals("Activity", find(":dialog").label)
    ui.activity.open() -- existing modal remains authoritative
    ui.close_overlay_widget(require("hollow.state").get().ui.overlay_stack[1])
    ui.activity.open()
    assert.is_not_nil(find(":activity:viewport"))
  end)

  it("keeps identity across collapse and refresh and searches live providers", function()
    running[1] = { id = "task:one", title = "Alpha", source = "task" }
    running[2] = { id = "task:two", title = "Beta", source = "task" }
    ui.activity.open()
    local id = find(":activity:item:task:one").id
    key("t")
    assert.is_nil(find(":activity:item:task:one"))
    key("t")
    assert.equals(id, find(":activity:item:task:one").id)
    key("slash")
    key("b")
    assert.is_nil(find(":activity:item:task:one"))
    assert.is_not_nil(find(":activity:item:task:two"))
    running[2].title = "Changed"
    hollow.events.emit("activity:changed", {})
    assert.is_nil(find(":activity:item:task:two"))
  end)

  it("dismisses via nested button and supports details, copy and back", function()
    entries[1] = entry(1, "First")
    entries[2] = entry(2, "Second")
    ui.activity.open()
    key("v")
    assert.is_not_nil(find(":activity:details"))
    assert.matches("First", text())
    key("y")
    assert.matches("Copied", text())
    key("escape")
    assert.is_not_nil(find(":activity:viewport"))
    local button
    for _, node in ipairs(tree()) do
      if node.id and node.id:find("activity:item:1:run:", 1, true) then
        button = node
      end
    end
    assert.is_not_nil(button)
    ui._layout_click(button.id)
    assert.same({ 1 }, dismissed)
    assert.is_not_nil(find(":activity:item:2"))
  end)

  it("opens and acknowledges an existing pane", function()
    entries[1] = entry(1, "First")
    entries[1].pane_id = 101
    ui.activity.open()
    key("enter")
    assert.same({ 1 }, dismissed)
    assert.equals(101, env.recorded.focus_pane_by_id)
    assert.is_nil(tree())
  end)

  it("bounds and scrolls long detail text", function()
    entries[1] = entry(1, "Long")
    entries[1].message = string.rep("word ", 3000)
    ui.activity.open({ height = 1000 })
    key("v")
    local viewport = find(":activity:details")
    assert.is_not_nil(viewport.scrollbar_id)
    assert.equals(0, viewport.padding.left)
    assert.equals(8, viewport.padding.right)
    assert.is_true(#tree() <= 512)
    ui._layout_measure(ui._layout_surface_id, viewport.id, 400, 3 * 19)
    tree()
    key("page_down")
    assert.is_not_nil(find(":activity:details"))
    key("escape")
    assert.is_not_nil(find(":activity:viewport"))
  end)

  it("bounds rows and follows measured viewport and scrollbar", function()
    for i = 1, 1000 do
      entries[i] = entry(i, "Item " .. i)
    end
    ui.activity.open()
    assert.is_true(#tree() <= 512)
    local viewport = find(":activity:viewport")
    ui._layout_measure(ui._layout_surface_id, viewport.id, 400, 3 * 25)
    viewport = find(":activity:viewport")
    assert.is_not_nil(viewport.scrollbar_id)
    local widget = require("hollow.state").get().ui.overlay_stack[1]
    widget.on_event("overlay:scrollbar", { id = viewport.scrollbar_id, ratio = 1 })
    assert.is_not_nil(find(":activity:item:1000"))
    assert.is_true(#tree() <= 512)
  end)
end)
