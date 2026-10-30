package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local json = require("dkjson")

describe("activity snapshots", function()
  it("preserves list and detail hint nodes", function()
    local hollow = harness.boot().hollow
    local ui = hollow.ui
    local entries = {
      {
        id = "one",
        kind = "notification",
        title = "Example",
        message = "Details",
        pending = true,
        level = "info",
      },
    }
    hollow.activity.list = function()
      return entries
    end
    hollow.activity.running = function()
      return {}
    end
    hollow.activity.summary = function()
      return { count = 1 }
    end
    ui.activity.open()
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local function snapshot()
      local nodes = surface:snapshot({ width = 800, height = 600, cell_w = 8, cell_h = 19 })
      local normalized = json.decode(json.encode(nodes))
      for _, node in ipairs(normalized) do
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      return normalized
    end
    local snapshots = { snapshot() }
    ui.dispatch_overlay_key("v", 0)
    snapshots[2] = snapshot()
    local file = assert(io.open("src/lua/tests/fixtures/activity_snapshot.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, snapshots)
  end)

  it("preserves list and details scrollbar paint", function()
    local hollow = harness.boot().hollow
    local ui = hollow.ui
    local entries = {}
    for i = 1, 30 do
      entries[i] = {
        id = i,
        kind = "notification",
        title = "Item " .. i,
        message = i == 1 and string.rep("word ", 3000) or "Details",
        pending = true,
        level = "info",
      }
    end
    hollow.activity.list = function()
      return entries
    end
    hollow.activity.running = function()
      return {}
    end
    hollow.activity.summary = function()
      return { count = #entries }
    end
    ui.activity.open({ height = 1000 })
    local surface = require("hollow.state").get().ui.overlay_stack[1]._layout_surface
    local ctx = { width = 800, height = 600, cell_w = 10, cell_h = 20 }
    local function snapshot()
      local nodes = json.decode(json.encode(surface:snapshot(ctx)))
      local found
      for _, node in ipairs(nodes) do
        if node.scrollbar_id then
          found = true
        end
        for _, field in ipairs({ "id", "reveal", "scrollbar_id" }) do
          if node[field] then
            node[field] = node[field]:gsub("^layout:%d+:", "test:")
          end
        end
      end
      assert.is_true(found)
      return nodes
    end
    surface:snapshot(ctx)
    surface.metrics["activity:viewport"] = { width = 400, height = 48 }
    surface:invalidate()
    local snapshots = { snapshot() }
    ui.dispatch_overlay_key("v", 0)
    snapshots[2] = snapshot()
    local file = assert(io.open("src/lua/tests/fixtures/activity_scroll_snapshots.json", "r"))
    local expected = json.decode(file:read("*a"))
    file:close()
    assert.same(expected, snapshots)
  end)
end)
