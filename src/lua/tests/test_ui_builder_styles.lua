package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI builder styles", function()
  local hollow
  local color

  before_each(function()
    local env = harness.boot()
    hollow = env.hollow
    color = require("hollow.color")
  end)

  it("styles button kinds across normal, selected, and hovered states", function()
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
    local emphasis_bg = color.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg)

    local cases = {
      {
        kind = "default",
        normal = { fg = theme.fg, radius = 7 },
        emphasized = { fg = theme.selected_fg, bg = emphasis_bg, bold = true, radius = 7 },
      },
      {
        kind = "primary",
        normal = { fg = theme.primary_bg, radius = 7 },
        emphasized = { fg = theme.primary_fg, bg = theme.primary_bg, bold = true, radius = 7 },
      },
      {
        kind = "destructive",
        normal = { fg = theme.destructive_bg, radius = 7 },
        emphasized = {
          fg = theme.destructive_fg,
          bg = theme.destructive_bg,
          bold = true,
          radius = 7,
        },
      },
      {
        kind = "unknown",
        normal = { fg = theme.fg, radius = 7 },
        emphasized = { fg = theme.selected_fg, bg = emphasis_bg, bold = true, radius = 7 },
      },
    }

    for _, case in ipairs(cases) do
      local style = harness.dialog_button_style
      assert.same(case.normal, style(theme, case.kind, false, false))
      assert.same(case.emphasized, style(theme, case.kind, true, false))
      assert.same(case.emphasized, style(theme, case.kind, false, true))
    end
  end)

  it("uses default radius when theme radius is absent", function()
    assert.equals(4, harness.dialog_button_style({ fg = "#010203" }, nil, false, false).radius)
  end)

  it("adapts legacy dialog body forms with default foreground", function()
    local ui = hollow.ui
    local dialog = require("hollow.ui.builder.components.dialog")
    local theme = {
      fg = "#112233",
      title = "#223344",
      divider = "#334455",
      selected_fg = "#445566",
      selected_bg = "#556677",
      panel_bg = "#000000",
      primary_fg = "#667788",
      primary_bg = "#778899",
      destructive_fg = "#8899aa",
      destructive_bg = "#99aabb",
    }
    local tree = dialog.dialog({
      body = {
        "plain",
        ui.text("span"),
        ui.span("styled"),
        { ui.text("inline") },
      },
    }, theme)
    local text = {}
    for _, row in ipairs(tree.children) do
      for _, node in ipairs(require("hollow.ui.shared").flatten_span_nodes(row.children)) do
        text[node.text] = node.style
      end
    end
    assert.equals(theme.fg, text.plain.fg)
    assert.equals(theme.fg, text.span.fg)
    assert.equals(theme.fg, text.styled.fg)
    assert.equals(theme.fg, text.inline.fg)
  end)

  it("skips false body items while preserving rows after holes", function()
    local ui = hollow.ui
    local dialog = require("hollow.ui.builder.components.dialog")
    local first = ui.row({ ui.text("first") })
    local last = ui.row({ ui.text("last") })
    local tree = dialog.dialog({ body = { first, false, nil, last } }, { fg = "#112233" })
    assert.equals(2, #tree.children)
    assert.equals(first, tree.children[1])
    assert.equals(last, tree.children[2])
  end)

  it("splices nested columns and row fragments in dialog bodies", function()
    local ui = hollow.ui
    local first, second, third = ui.row({}), ui.row({}), ui.row({})
    local tree = ui.dialog({
      body = { first, ui.column({ second, ui.column({ third }) }), { first, { second } } },
    }, { fg = "#123456" })
    assert.same({ first, second, third, first, second }, tree.children)
  end)

  it("preserves footer spacing, styles and click registration", function()
    local ui = hollow.ui
    local clicked
    local theme = hollow.theme.resolve_widget("select")
    local tree = ui.dialog({
      footer = {
        {
          id = "first",
          text = "First",
          on_click = function()
            clicked = "first"
          end,
        },
        { id = "second", text = "Second", kind = "primary" },
      },
      selected = 2,
    }, theme)
    assert.equals(2, #tree.children)
    local nodes = require("hollow.ui.shared").flatten_span_nodes(tree.children[2].children)
    assert.is_true(nodes[1].spacer)
    assert.equals(" First ", nodes[2].text)
    assert.equals("  ", nodes[3].text)
    assert.equals(" Second ", nodes[4].text)
    assert.equals("first", nodes[2].style.id)
    assert.equals(theme.primary_bg, nodes[4].style.bg)
    require("hollow.ui.builder.internal.click_registry").dispatch("first", { id = "first" })
    assert.equals("first", clicked)
  end)
end)
