package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("styling unification baseline", function()
  local hollow

  before_each(function()
    hollow = harness.boot().hollow
  end)

  it("preserves legacy row paint with selection taking priority over hover", function()
    local ui = hollow.ui
    local list_style = require("hollow.ui.widgets.list_style")
    local theme = {
      selection_bg = "#112233",
      hover_bg = "#223344",
      panel_border = "#334455",
      scrollbar_track = "#445566",
      scrollbar_thumb = "#556677",
    }
    for _, selected in ipairs({ false, true }) do
      for _, hovered in ipairs({ false, true }) do
        local options = list_style.row({ id = "row" }, theme, selected, hovered, "#010203")
        ui.overlay.push(ui.overlay.new({
          render = function()
            return ui.row({ ui.text("Choice", { fg = "#abcdef" }) }, options)
          end,
        }))
        assert.same({
          id = "row",
          hoverable = true,
          segments = { { text = "Choice", fg = "#abcdef", bold = false } },
          fill_bg = selected and "#112233" or (hovered and "#223344" or "#010203"),
          fill_radius = 4,
          accent_bar = selected and "#334455" or nil,
          scrollbar_track = false,
          scrollbar_thumb = false,
          scrollbar_track_color = "#445566",
          scrollbar_thumb_color = "#556677",
        }, ui._overlay_state()[1].rows[1])
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
        return ui.row({ action() })
      end,
    })
    ui.overlay.push(widget)
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { action() }
      end,
    }))
    for _, hovered in ipairs({ false, true, false }) do
      widget.on_event(hovered and "overlay:hover" or "overlay:leave", { id = "run" })
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
      assert.same(expected, ui._overlay_state()[1].rows[1].segments[1])
      assert.same(expected, ui._topbar_state().items[1].segments[1])
    end
    ui.overlay.clear()
    ui.topbar.unmount()
  end)
end)
