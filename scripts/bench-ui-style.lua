-- Run from the repository root with LuaJIT/Busted dependencies installed:
--   luajit scripts/bench-ui-style.lua
-- Measures the supported component path; no legacy inline tab or action adapters.
package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local hollow = require("tests.harness").boot().hollow
local ui = hollow.ui
local c = ui.components
local palette = require("hollow.ui.shared").palette("select")

local function make_tree(count)
  local rows = {}
  for i = 1, count do
    rows[i] = c.row({
      c.button({ id = "run:" .. i, text = "Run", variant = "primary" }),
      c.tabs({
        active = i % 2 == 0 and "on" or "off",
        tabs = {
          { id = "on:" .. i, label = "Tab" },
          { id = "off:" .. i, label = "Other", badge = { text = "2", color = "#123456" } },
        },
      }),
    }, { width = "grow" })
  end
  return c.column(rows)
end

-- A row creates a handful of Clay nodes. Keep the benchmark comfortably below
-- the 512-node limit so we measure construction, not budget enforcement.
for _, count in ipairs({ 10, 25, 50 }) do
  local surface = ui.layout.new({
    theme = palette,
    render = function()
      return make_tree(count)
    end,
  })
  for _ = 1, 10 do
    surface:invalidate()
    surface:snapshot({ width = 1200, height = 900, cell_w = 8, cell_h = 19 })
  end
  local samples = {}
  for i = 1, 7 do
    collectgarbage("collect")
    local start = os.clock()
    for _ = 1, 20 do
      surface:invalidate()
      surface:snapshot({ width = 1200, height = 900, cell_w = 8, cell_h = 19 })
    end
    samples[i] = (os.clock() - start) * 1000 / 20
  end
  table.sort(samples)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  surface:invalidate()
  local nodes = surface:snapshot({ width = 1200, height = 900, cell_w = 8, cell_h = 19 })
  local bytes = (collectgarbage("count") - before) * 1024 / count
  collectgarbage("restart")
  assert(#nodes <= 512, "benchmark exceeded Clay node capacity")
  print(
    string.format(
      "%d component rows (%d nodes): %.3f ms/snapshot, %.0f bytes/row",
      count,
      #nodes,
      samples[4],
      bytes
    )
  )
  surface:destroy()
end
