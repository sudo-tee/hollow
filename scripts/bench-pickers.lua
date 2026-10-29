-- Run from repository root: luajit scripts/bench-pickers.lua [iterations]
-- CPU time for Lua event handling and snapshot construction, not native layout.
package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local iterations = tonumber(arg[1] or "10")
assert(iterations and iterations >= 2 and iterations % 2 == 0, "iterations must be a positive even number")

local entries, workspaces = {}, {}
for i = 1, 100 do
  entries[i] = { name = "command_" .. i, desc = "Command " .. i, category = "general", chords = {} }
  workspaces[i] = { name = "workspace " .. i, cwd = "/srv/project/" .. i, domain = "remote", workspace_id = i }
end

for _, picker in ipairs({ "palette", "workspace" }) do
  for _, backend in ipairs({ "legacy", "clay" }) do
    local ui = harness.boot().hollow.ui
    if picker == "palette" then
      ui.command_palette.open({ entries = entries, layout = backend })
    else
      -- Callable source intentionally mirrors workspace's live provider behavior.
      require("hollow.ui.workspace.source").items = function() return workspaces end
      ui.workspace.open_switcher({ layout = backend })
    end
    local function frame(width)
      local overlay = ui._overlay_state()
      assert(overlay[1] and (overlay[1].clay == true) == (backend == "clay"))
      ui._layout_prepare(width, 900, 8, 19)
    end
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
      for i = 1, 20 do step(i) end
      local samples = {}
      for sample = 1, 7 do
        collectgarbage("collect")
        local start = os.clock()
        for i = 1, iterations do step(i) end
        samples[sample] = (os.clock() - start) * 1000 / iterations
      end
      table.sort(samples)
      print(string.format("%-9s %-6s %-9s %.4f ms/step", picker, backend, scenario, samples[4]))
    end
    ui.overlay.clear()
  end
end
