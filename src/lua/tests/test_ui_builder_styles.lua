package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay dialog button styles", function()
  before_each(function()
    harness.boot()
  end)

  it("preserves normal, selected and hovered semantic button paint", function()
    local theme = {
      fg = "#101112",
      selected_fg = "#202122",
      selected_bg = "#304050",
      panel_bg = "#000000",
      primary_fg = "#f1f2f3",
      primary_bg = "#405060",
      destructive_fg = "#e1e2e3",
      destructive_bg = "#506070",
      radius = 7,
    }
    local emphasis =
      require("hollow.color").brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg)
    for _, kind in ipairs({ "default", "primary", "destructive", "unknown" }) do
      local semantic = kind == "primary" or kind == "destructive"
      local normal = { fg = semantic and theme[kind .. "_bg"] or theme.fg, radius = 7 }
      local active = {
        fg = semantic and theme[kind .. "_fg"] or theme.selected_fg,
        bg = semantic and theme[kind .. "_bg"] or emphasis,
        bold = true,
        radius = 7,
      }
      assert.same(normal, harness.dialog_button_style(theme, kind, false, false))
      assert.same(active, harness.dialog_button_style(theme, kind, true, false))
      assert.same(active, harness.dialog_button_style(theme, kind, false, true))
    end
  end)

  it("preserves footer callback identity and ignores false body children", function()
    local ui = hollow.ui
    local clicked
    local dialog = require("hollow.ui.components.dialog")
    local tree = dialog({
      body = ui.components.column({
        ui.components.text("first"),
        false,
        ui.components.text("last"),
      }),
      footer = {
        {
          id = "first",
          text = "First",
          on_click = function()
            clicked = true
          end,
        },
      },
    }, hollow.theme.resolve_widget("select"), {})
    local surface = ui.layout.new({
      render = function()
        return tree
      end,
    })
    surface:show()
    ui._layout_prepare(1200, 900, 8, 19)
    for _, node in ipairs(ui._layout_tree) do
      if node.label == "First" then
        surface:dispatch(node.id)
      end
    end
    assert.is_true(clicked)
    surface:destroy()
  end)
end)
