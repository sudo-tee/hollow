package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("styling unification baseline", function()
  local hollow

  before_each(function()
    hollow = harness.boot().hollow
  end)

  it("preserves row recipe selection priority over hover in Clay", function()
    local ui = hollow.ui
    local list_row = require("hollow.ui.recipes.list_row")
    local theme = {
      selection_bg = "#112233",
      hover_bg = "#223344",
      panel_border = "#334455",
      selected_detail_bg = "#010203",
      scrollbar_track = "#445566",
      scrollbar_thumb = "#556677",
    }
    for _, selected in ipairs({ false, true }) do
      for _, hovered in ipairs({ false, true }) do
        local paint =
          list_row(theme, { variant = "section", selected = selected, hovered = hovered })
        local options = hollow.util.merge_tables({ id = "row" }, paint.paint)
        ui.overlay.push(ui.overlay.new({
          render = function()
            return clay.row(ui, ui.row({ ui.text("Choice", { fg = "#abcdef" }) }, options))
          end,
        }))
        local row = assert(clay.find(ui, ":row"))
        assert.equals(selected and "#112233" or (hovered and "#223344" or "#010203"), row.bg)
        assert.equals(4, row.radius)
        assert.equals("#abcdef", clay.text_node(ui, "Choice").fg)
        ui.overlay.clear()
      end
    end
  end)

  it("preserves action paint and geometry across bar and overlay hover transitions", function()
    local ui = hollow.ui
    local theme = { fg = "#112233", hover_fg = "#223344", hover_bg = "#334455" }
    local function action()
      return ui.action_button({ id = "run", text = "Run", theme = theme })
    end
    local widget = ui.overlay.new({
      render = function()
        return clay.row(ui, ui.row({ action() }))
      end,
    })
    ui.overlay.push(widget)
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { action() }
      end,
    }))
    for _, hovered in ipairs({ false, true, false }) do
      hollow._emit_builtin_event(hovered and "topbar:hover" or "topbar:leave", { id = "run" })
      local expected = {
        text = "Run",
        bold = false,
        id = "run",
        fg = hovered and "#223344" or "#112233",
        bg = hovered and "#334455" or nil,
        radius = 4,
        padding = { left = 4, right = 4, top = 0, bottom = 0 },
      }
      local action_box = assert(clay.label(ui, "Run"))
      assert.equals(hollow.theme.resolve_widget("overlay").hover_bg, action_box.hover_bg)
      assert.equals(4, action().style.radius)
      assert.equals("#112233", clay.text_node(ui, "Run").fg)
      assert.same(expected, ui._topbar_state().items[1].segments[1])
    end
    ui.overlay.clear()
    ui.topbar.unmount()
  end)
end)
