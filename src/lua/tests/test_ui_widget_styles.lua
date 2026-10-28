package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("widget style recipes", function()
  local hollow

  before_each(function()
    hollow = harness.boot().hollow
  end)

  local function segment(text)
    for _, overlay in ipairs(hollow.ui._overlay_state() or {}) do
      for _, row in ipairs(overlay.rows) do
        for _, node in ipairs(row.segments) do
          if node.text == text then
            return node
          end
        end
      end
    end
    error("missing segment: " .. text)
  end

  local theme = { title = "#123456", muted = "#654321" }

  it("keeps select header and hints on its custom theme", function()
    hollow.ui.select.open({
      prompt = "Styled",
      items = { "one" },
      theme = theme,
      actions = { { key = "enter", desc = "Choose", fn = function() end } },
    })
    assert.equals(theme.title, segment("Styled:").fg)
    assert.is_true(segment("Styled:").bold)
    assert.equals(theme.title, segment("Filter: ").fg)
    assert.equals(theme.muted, segment(" Choose").fg)
  end)

  it("keeps palette header and hints on its custom theme", function()
    hollow.ui.command_palette.open({ prompt = "Styled", entries = {}, theme = theme })
    assert.equals(theme.title, segment("Styled:").fg)
    assert.is_true(segment("Styled:").bold)
    assert.equals(theme.title, segment("Filter: ").fg)
    assert.equals(theme.muted, segment(" dismiss").fg)
  end)

  it("keeps mux search styles on its custom theme", function()
    hollow.ui.mux_navigator.open({ theme = theme })
    assert.equals(theme.title, segment("/ ").fg)
    assert.is_true(segment("/ ").bold)
    assert.equals(theme.muted, segment("search panes").fg)
  end)

  it("keeps activity header and hints on its custom theme", function()
    hollow.ui.activity.open({ theme = theme })
    assert.equals(theme.title, segment("Activity  ").fg)
    assert.is_true(segment("Activity  ").bold)
    assert.equals(theme.muted, segment(" views   ").fg)
  end)
end)
