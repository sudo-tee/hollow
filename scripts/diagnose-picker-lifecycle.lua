-- Run each combination in a fresh process, using the busted environment:
-- source <(sed '$d' "$(command -v busted)"); luajit scripts/diagnose-picker-lifecycle.lua palette clay on 20 20 20
-- Arguments: picker, backend, JIT on/off, warmup cycles, cycles/batch, batches,
-- optional "reset-clicks" to test whether the callback registry owns survivors.
package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local picker, backend, jit_mode = arg[1] or "palette", arg[2] or "legacy", arg[3] or "on"
local warmup, cycles, batches =
  tonumber(arg[4] or 20), tonumber(arg[5] or 20), tonumber(arg[6] or 20)
assert(picker == "palette" or picker == "workspace")
assert(backend == "legacy" or backend == "clay")
assert(jit_mode == "on" or jit_mode == "off")
assert(warmup and warmup >= 0 and cycles and cycles > 0 and batches and batches > 0)
if jit_mode == "off" then
  jit.off()
end

local ui = require("tests.harness").boot().hollow.ui
local entries, workspaces = {}, {}
for i = 1, 100 do
  entries[i] = { name = "command_" .. i, desc = "Command " .. i, category = "general", chords = {} }
  workspaces[i] =
    { name = "workspace " .. i, cwd = "/srv/project/" .. i, domain = "remote", workspace_id = i }
end
if picker == "workspace" then
  require("hollow.ui.workspace.source").items = function()
    return workspaces
  end
end
local stack = require("hollow.state").get().ui.overlay_stack
local refs = {
  widget = setmetatable({}, { __mode = "v" }),
  palette = setmetatable({}, { __mode = "v" }),
  chrome = setmetatable({}, { __mode = "v" }),
  surface = setmetatable({}, { __mode = "v" }),
}
local serial = 0
local function cycle()
  if picker == "palette" then
    ui.command_palette.open({ entries = entries, layout = backend })
  else
    ui.workspace.open_switcher({ layout = backend })
  end
  local widget = assert(stack[#stack])
  assert(
    ui._overlay_state()[1].clay == (backend == "clay")
      or backend == "legacy" and not ui._overlay_state()[1].clay
  )
  ui._layout_prepare(1200, 900, 8, 19)
  serial = serial % cycles + 1
  refs.widget[serial], refs.palette[serial], refs.chrome[serial], refs.surface[serial] =
    widget, widget._palette, widget.chrome, widget._layout_surface
  ui.overlay.clear()
  if arg[7] == "reset-clicks" then
    require("hollow.ui.builder.internal.click_registry").reset()
  end
end
local function heap()
  collectgarbage("collect")
  collectgarbage("collect")
  return collectgarbage("count")
end
local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end
for _ = 1, warmup do
  cycle()
end
local previous = heap()
print(
  string.format(
    "%s %s jit=%s warmup=%d cycles=%d heap=%.1f KiB",
    picker,
    backend,
    jit_mode,
    warmup,
    cycles,
    previous
  )
)
for batch = 1, batches do
  for _ = 1, cycles do
    cycle()
  end
  local current = heap()
  print(
    string.format(
      "%02d heap=%9.1f delta=%+8.1f weak widget=%d palette=%d chrome=%d surface=%d",
      batch,
      current,
      current - previous,
      count(refs.widget),
      count(refs.palette),
      count(refs.chrome),
      count(refs.surface)
    )
  )
  previous = current
end
