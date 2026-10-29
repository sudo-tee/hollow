package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path

local harness = require("tests.harness")

describe("UI overlay hover", function()
  local env
  local hollow
  local ui
  local shared

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    ui = hollow.ui
    shared = require("hollow.ui.shared")
  end)

  it("applies hover only to a matching nonempty id and leaves input untouched", function()
    local style = { id = "target", fg = "#111111", hover = { fg = "#222222" } }
    local resolved = shared.apply_hover(style, "target")

    assert.equals("#222222", resolved.fg)
    assert.equals("#111111", style.fg)
    assert.equals(style.id, resolved.id)
    assert.equals(style, shared.apply_hover(style, "other"))
    assert.equals(style, shared.apply_hover(style, nil))
    assert.equals(style, shared.apply_hover(style, ""))
    assert.equals("plain", shared.apply_hover("plain", "target"))
    assert.is_nil(shared.apply_hover(nil, "target"))
    local anonymous = { hover = { fg = "#ffffff" } }
    assert.equals(anonymous, shared.apply_hover(anonymous, nil))
    local empty = { id = "", hover = { fg = "#ffffff" } }
    assert.equals(empty, shared.apply_hover(empty, ""))
  end)

  it("merges hover per side without mutating either style", function()
    local base = {
      id = "target",
      fg = "#111111",
      bg = "#333333",
      padding = 4,
      hover = { fg = "#222222", padding = { left = 2 } },
    }
    local result = shared.apply_hover(base, "target")

    assert.equals("#222222", result.fg)
    assert.equals("#333333", result.bg)
    assert.same({ left = 2, right = 4, top = 4, bottom = 4 }, result.padding)
    assert.same({ fg = "#222222", padding = { left = 2 } }, base.hover)
    assert.is_not.equal(base, result)
  end)

  it("serializes matching overlay span hover and resets on leave", function()
    local widget = ui.overlay.new({
      render = function(state)
        return ui.row({
          ui.span("match", { id = "match", fg = "#111111", hover = { fg = "#222222" } }),
          ui.span("other", { id = "other", fg = "#333333", hover = { fg = "#444444" } }),
        })
      end,
    })
    ui.overlay.push(widget)

    widget.on_event("overlay:hover", { id = "match" })
    local hovered = ui._overlay_state()[1].rows[1].segments
    assert.equals("#222222", hovered[1].fg)
    assert.equals("#333333", hovered[2].fg)

    widget.on_event("overlay:leave")
    local idle = ui._overlay_state()[1].rows[1].segments
    assert.equals("#111111", idle[1].fg)
    assert.equals("#333333", idle[2].fg)
    ui.overlay.clear()
  end)

  it("keeps hover state available to render callback", function()
    local seen
    local widget = ui.overlay.new({
      render = function(state)
        seen = state.hovered_id
        return ui.row({ ui.text("row") })
      end,
    })
    ui.overlay.push(widget)
    widget.on_event("overlay:hover", { id = "row-id" })
    ui._overlay_state()
    assert.equals("row-id", seen)
    ui.overlay.clear()
  end)

  it("keeps hover independent across stacked overlays", function()
    local function widget(id)
      return ui.overlay.new({
        render = function()
          return ui.row({ ui.span(id, { id = id, fg = "#111111", hover = { fg = "#222222" } }) })
        end,
      })
    end
    local lower, upper = widget("lower"), widget("upper")
    ui.overlay.push(lower)
    ui.overlay.push(upper)
    lower.on_event("overlay:hover", { id = "lower" })
    upper.on_event("overlay:hover", { id = "upper" })

    local stack = ui._overlay_state()
    assert.equals("#222222", stack[1].rows[1].segments[1].fg)
    assert.equals("#222222", stack[2].rows[1].segments[1].fg)
    upper.on_event("overlay:leave")
    stack = ui._overlay_state()
    assert.equals("#222222", stack[1].rows[1].segments[1].fg)
    assert.equals("#111111", stack[2].rows[1].segments[1].fg)
    ui.overlay.clear()
  end)

  it("uses native action button hover defaults and custom hover style", function()
    local defaults = ui.action_button({ id = "default", text = "Default" })
    assert.is_table(defaults.style.hover)
    local custom = ui.action_button({
      id = "custom",
      text = "Custom",
      hover_style = { fg = "#abcdef" },
    })
    assert.equals("#abcdef", custom.style.hover.fg)
    local legacy = ui.action_button({
      id = "legacy",
      text = "Legacy",
      state = { hovered_id = "legacy" },
    })
    assert.is_table(legacy.style.hover)
    assert.equals(hollow.theme.resolve_widget("select").fg, legacy.style.fg)
  end)

  it("serializes action hover using explicit theme and legacy overrides", function()
    local theme = { fg = "#111111", hover_fg = "#222222", hover_bg = "#333333", muted = "#444444" }
    local widget = ui.overlay.new({
      render = function()
        return ui.row({
          ui.action_button({
            id = "action",
            text = "Run",
            theme = theme,
            style = { hover = { fg = "muted" } },
            hover_style = { bg = "#555555" },
          }),
        })
      end,
    })
    ui.overlay.push(widget)
    assert.equals("#111111", ui._overlay_state()[1].rows[1].segments[1].fg)
    ui.dispatch_widget_event("overlay:hover", { index = 1, id = "action" })
    local hovered = ui._overlay_state()[1].rows[1].segments[1]
    assert.equals("#444444", hovered.fg)
    assert.equals("#555555", hovered.bg)
    ui.dispatch_widget_event("overlay:leave", {})
    assert.equals("#111111", ui._overlay_state()[1].rows[1].segments[1].fg)
  end)

  it("preserves click callback dispatch", function()
    local clicked = false
    local widget = ui.overlay.new({
      render = function()
        return ui.row({
          ui.action_button({
            id = "click-me",
            text = "Click",
            on_click = function()
              clicked = true
            end,
          }),
        })
      end,
    })
    ui.overlay.push(widget)
    ui._overlay_state()
    widget.on_event("overlay:click", { id = "click-me" })
    assert.is_true(clicked)
    ui.overlay.clear()
  end)

  it("keeps legacy hover padding as a whole-box override", function()
    local node = ui.action_button({
      id = "legacy-padding",
      style = { padding = { left = 9, right = 7 } },
      hover_style = { padding = { left = 2 } },
    })
    local hovered = shared.style_to_segment("Run", shared.apply_hover(node.style, node.style.id))
    assert.same({ left = 2, right = 0, top = 0, bottom = 0 }, hovered.padding)
  end)
end)
