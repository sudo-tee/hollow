-- Run from repository root: luajit scripts/bench-picker-memory.lua [even steps per batch]
-- Lua heap only; see docs/renderer-bench.md for measurement boundaries.
package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local iterations = tonumber(arg[1] or "10")
assert(
  iterations and iterations >= 2 and iterations % 2 == 0,
  "iterations must be a positive even number"
)

local entries, workspaces = {}, {}
for i = 1, 100 do
  entries[i] = { name = "command_" .. i, desc = "Command " .. i, category = "general", chords = {} }
  workspaces[i] =
    { name = "workspace " .. i, cwd = "/srv/project/" .. i, domain = "remote", workspace_id = i }
end

local function heap()
  collectgarbage("collect")
  return collectgarbage("count")
end

local function median(values)
  table.sort(values)
  return values[4]
end

print(string.format("Lua heap KiB; 100 entries, %d steps/cycles per batch, 7 batches", iterations))
for _, picker in ipairs({ "palette", "workspace" }) do
  for _, backend in ipairs({ "legacy", "clay" }) do
    local ui = harness.boot().hollow.ui
    if picker == "workspace" then
      require("hollow.ui.workspace.source").items = function()
        return workspaces
      end
    end
    local function open()
      if picker == "palette" then
        ui.command_palette.open({ entries = entries, layout = backend })
      else
        ui.workspace.open_switcher({ layout = backend })
      end
    end
    local function frame(width)
      local overlay = ui._overlay_state()
      assert(overlay[1] and (overlay[1].clay == true) == (backend == "clay"))
      ui._layout_prepare(width, 900, 8, 19)
    end
    open()
    frame(1200)
    for _, scenario in ipairs({ "idle", "selection", "filter", "resize" }) do
      local function step(i)
        if scenario == "selection" then
          ui.dispatch_overlay_key(i % 2 == 1 and "page_down" or "page_up", 0)
        elseif scenario == "filter" then
          ui.dispatch_overlay_key(i % 2 == 1 and "1" or "backspace", 0)
        end
        frame(scenario == "resize" and (i % 2 == 1 and 1000 or 1200) or 1200)
      end
      for i = 1, 20 do
        step(i)
      end
      local retained, uncollected, deltas = {}, {}, {}
      for sample = 1, 7 do
        retained[sample] = heap()
        collectgarbage("stop")
        local before = collectgarbage("count")
        step(sample % 2 == 1 and 1 or 2)
        uncollected[sample] = collectgarbage("count") - before
        collectgarbage("restart")
        before = heap()
        for i = 1, iterations do
          step(i)
        end
        deltas[sample] = heap() - before
      end
      print(
        string.format(
          "%-9s %-6s %-9s retained=%9.1f KiB  uncollected/step=%9.1f KiB  batch-delta=%+8.1f KiB",
          picker,
          backend,
          scenario,
          median(retained),
          median(uncollected),
          median(deltas)
        )
      )
    end
    ui.overlay.clear()
    local function cycle()
      open()
      frame(1200)
      ui.overlay.clear()
    end
    for _ = 1, 20 do
      cycle()
    end
    local deltas = {}
    for sample = 1, 7 do
      local before = heap()
      for _ = 1, iterations do
        cycle()
      end
      deltas[sample] = heap() - before
    end
    local parts = {}
    for i = 1, 7 do
      parts[i] = string.format("%+.1f", deltas[i])
    end
    print(
      string.format(
        "%-9s %-6s lifecycle batch-deltas KiB: %s (median %+.1f)",
        picker,
        backend,
        table.concat(parts, ", "),
        median(deltas)
      )
    )
  end
end
