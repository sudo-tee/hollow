package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("UI hover", function()
  local ui, shared
  before_each(function()
    ui = harness.boot().hollow.ui
    shared = require("hollow.ui.shared")
  end)

  it("applies inline hover only to matching nonempty ids without mutation", function()
    local style = { id = "target", fg = "#111111", hover = { fg = "#222222" } }
    assert.equals("#222222", shared.apply_hover(style, "target").fg)
    assert.equals("#111111", style.fg)
    for _, id in ipairs({ "other", "" }) do
      assert.equals(style, shared.apply_hover(style, id))
    end
    assert.equals(style, shared.apply_hover(style, nil))
    assert.equals("plain", shared.apply_hover("plain", "target"))
    assert.is_nil(shared.apply_hover(nil, "target"))
    local anonymous, empty = { hover = { fg = "#ffffff" } }, { id = "", hover = { fg = "#ffffff" } }
    assert.equals(anonymous, shared.apply_hover(anonymous, nil))
    assert.equals(empty, shared.apply_hover(empty, ""))
  end)

  it("merges inline hover padding per side without mutation", function()
    local style = {
      id = "target",
      fg = "#111111",
      bg = "#333333",
      padding = 4,
      hover = { fg = "#222222", padding = { left = 2 } },
    }
    local result = shared.apply_hover(style, "target")
    assert.equals("#222222", result.fg)
    assert.equals("#333333", result.bg)
    assert.same({ left = 2, right = 4, top = 4, bottom = 4 }, result.padding)
    assert.same({ fg = "#222222", padding = { left = 2 } }, style.hover)
    assert.not_equals(style, result)
  end)

  it("publishes independent native hover paint and callbacks for stacked overlays", function()
    local clicked = {}
    local function widget(id, bg)
      return ui.overlay.new({
        render = function()
          return ui.components.button({
            id = id,
            text = id,
            style = { hover = { bg = bg } },
            on_click = function()
              clicked[#clicked + 1] = id
            end,
          })
        end,
      })
    end
    local lower, upper = widget("lower", "#112233"), widget("upper", "#223344")
    ui.overlay.push(lower)
    ui.overlay.push(upper)
    ui._layout_prepare(1200, 900, 8, 19)
    assert.is_true(ui._layout_prepare_overlay(1, 1200, 900, 8, 19))
    -- [1] is the overlay chrome; [2] is the rendered root.
    local lower_node = ui._layout_tree[2]
    assert.is_true(ui._layout_prepare_overlay(2, 1200, 900, 8, 19))
    local upper_node = ui._layout_tree[2]
    assert.equals("#112233", lower_node.hover_bg)
    assert.equals("#223344", upper_node.hover_bg)
    lower.on_event("overlay:click", { id = lower_node.id })
    upper.on_event("overlay:click", { id = upper_node.id })
    assert.same({ "lower", "upper" }, clicked)
  end)

  it("keeps semantic hover state available to modal render callbacks", function()
    local seen
    local modal = ui.modal({
      semantic_hover = true,
      render = function(_, state)
        seen = state.hovered_id
        return ui.components.button({ id = "row-id", text = "row" })
      end,
    })
    modal.widget.on_event("overlay:hover", { id = clay.find(ui, ":row-id").id })
    clay.nodes(ui)
    assert.equals("row-id", seen)
    modal.widget.on_event("overlay:leave", {})
    clay.nodes(ui)
    assert.is_nil(seen)
  end)

end)
