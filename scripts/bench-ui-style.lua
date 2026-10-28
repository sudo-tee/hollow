-- Run from the repository root with the LuaJIT/Busted dependencies installed:
--   luajit scripts/bench-ui-style.lua
-- Median of seven warm runs. Allocation counts disable GC briefly; timings
-- include ordinary GC. This measures Lua style work, not native rendering.
package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local hollow = require("tests.harness").boot().hollow
local shared = require("hollow.ui.shared")
local palette = shared.palette("select")
local style = hollow.ui.action_button({ id = "run", text = "Run" }).style
local snapshot = shared.compute_style(palette, style)
local function measure(count, mode)
  local function run()
    for _ = 1, count do
      if mode == "recompute" then
        shared.computed_style_to_segment("Run", shared.compute_style(palette, style), "run")
      elseif mode == "reuse" then
        shared.computed_style_to_segment("Run", snapshot, "run")
      else
        shared.style_to_segment("Run", style, palette)
      end
    end
  end
  for _ = 1, 100 do
    run()
  end
  local samples = {}
  for i = 1, 7 do
    collectgarbage("collect")
    local start = os.clock()
    for _ = 1, 100 do
      run()
    end
    samples[i] = (os.clock() - start) * 1000 / 100
  end
  table.sort(samples)
  collectgarbage("collect")
  collectgarbage("stop")
  local start_kb = collectgarbage("count")
  for _ = 1, 20 do
    run()
  end
  local bytes = (collectgarbage("count") - start_kb) * 1024 / (count * 20)
  collectgarbage("restart")
  return samples[4], bytes
end
for _, count in ipairs({ 25, 100, 500 }) do
  for _, mode in ipairs({ "legacy", "recompute", "reuse" }) do
    local ms, bytes = measure(count, mode)
    print(
      string.format("%d nodes %s: %.3f ms/batch, %.0f allocated bytes/node", count, mode, ms, bytes)
    )
  end
end
