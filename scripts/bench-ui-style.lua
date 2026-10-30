-- Run from the repository root with the LuaJIT/Busted dependencies installed:
--   luajit scripts/bench-ui-style.lua
-- Median of seven warm runs. Allocation counts disable GC briefly; timings
-- include ordinary GC. This measures Lua style work, not native rendering.
package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local hollow = require("tests.harness").boot().hollow
local shared = require("hollow.ui.shared")
local palette = shared.palette("select")
local style = hollow.ui.action_button({ id = "run", text = "Run" }).style
-- Older branches paint list rows through `hollow.ui.widgets.list_style`.
local has_list_style, list_style = pcall(require, "hollow.ui.widgets.list_style")
local function row_paint(options, selected, hovered)
  if has_list_style then
    return list_style.row(options, palette, selected, hovered)
  end
  local paint = require("hollow.ui.recipes.list_row")(palette, {
    selected = selected,
    hovered = hovered,
  }).paint
  return hollow.util.merge_tables(options, paint)
end
-- --components is also runnable on the pre-unification branch for comparison.
if arg[1] == "--components" then
  local function render(count)
    for i = 1, count do
      local action = hollow.ui.action_button({ id = "run", text = "Run", theme = palette })
      shared.style_to_segment(action.text, action.style, palette)
      local tab = hollow.ui.tab({
        id = "tab",
        label = "Tab",
        active = i % 2 == 0,
        theme = palette,
        badge = { text = 2, color = "#123456" },
      })
      for _, node in ipairs(shared.flatten_span_nodes(tab.children)) do
        shared.style_to_segment(node.text, node.style, palette)
      end
      row_paint({}, i % 2 == 0, i % 3 == 0)
    end
  end
  for _, count in ipairs({ 25, 100, 500 }) do
    for _ = 1, 10 do
      render(count)
    end
    local samples = {}
    for i = 1, 7 do
      collectgarbage("collect")
      local start = os.clock()
      for _ = 1, 20 do
        render(count)
      end
      samples[i] = (os.clock() - start) * 1000 / 20
    end
    table.sort(samples)
    collectgarbage("collect")
    collectgarbage("stop")
    local start_kb = collectgarbage("count")
    render(count)
    local bytes = (collectgarbage("count") - start_kb) * 1024 / count
    collectgarbage("restart")
    print(
      string.format(
        "%d component groups: %.3f ms/batch, %.0f bytes/group",
        count,
        samples[4],
        bytes
      )
    )
  end
  return
end
if arg[1] == "--overlay" then
  local ui = hollow.ui
  for _, count in ipairs({ 25, 100, 500 }) do
    ui.overlay.push(ui.overlay.new({
      chrome = shared.theme_overlay_chrome(palette),
      render = function()
        local rows = {}
        for i = 1, count do
          rows[i] = ui.row({
            ui.action_button({ id = "run:" .. i, text = "Run", theme = palette }),
            ui.tab({
              id = "tab:" .. i,
              label = "Tab",
              active = i % 2 == 0,
              theme = palette,
              badge = { text = 2, color = "#123456" },
            }),
          }, row_paint({ id = "row:" .. i }, i % 2 == 0, i % 3 == 0))
        end
        return ui.column(rows)
      end,
    }))
    for _ = 1, 10 do
      ui._overlay_state()
    end
    local samples = {}
    for i = 1, 7 do
      collectgarbage("collect")
      local start = os.clock()
      for _ = 1, 20 do
        ui._overlay_state()
      end
      samples[i] = (os.clock() - start) * 1000 / 20
    end
    table.sort(samples)
    collectgarbage("collect")
    collectgarbage("stop")
    local start_kb = collectgarbage("count")
    ui._overlay_state()
    local bytes = (collectgarbage("count") - start_kb) * 1024 / count
    collectgarbage("restart")
    ui.overlay.clear()
    print(
      string.format(
        "%d overlay rows: %.3f ms/render+serialize, %.0f bytes/row",
        count,
        samples[4],
        bytes
      )
    )
  end
  return
end
local function measure(count)
  local function run()
    for _ = 1, count do
      shared.style_to_segment("Run", style, palette)
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
  local ms, bytes = measure(count)
  print(string.format("%d nodes: %.3f ms/batch, %.0f allocated bytes/node", count, ms, bytes))
end
