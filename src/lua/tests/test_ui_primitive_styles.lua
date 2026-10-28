package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("primitive style compatibility", function()
  local hollow
  local shared

  setup(function()
    hollow = harness.boot().hollow
    shared = require("hollow.ui.shared")
  end)

  it("keeps select theme defaults for tabs without an explicit theme", function()
    local theme = hollow.theme.resolve_widget("select")
    local ui = hollow.ui
    for _, active in ipairs({ false, true }) do
      for _, badged in ipairs({ false, true }) do
        local badge = badged and { text = 2, color = "#123456" } or nil
        local node = ui.tab({ id = "tab", label = "Tab", active = active, badge = badge })
        local flattened = shared.flatten_span_nodes(node.children)
        local expected = {
          {
            text = badged and "Tab " or "Tab",
            style = {
              id = "tab",
              fg = active and theme.selection_fg or theme.muted,
              bg = active and theme.selection_bg or nil,
              bold = active,
              radius = 4,
              background_extend = active and badged and 2 or nil,
              padding = { left = 8, right = badged and 0 or 8, top = 3, bottom = 3 },
            },
          },
        }
        if badged then
          expected[2] = {
            text = "2",
            style = {
              id = "tab:badge",
              fg = theme.panel_bg,
              bg = "#123456",
              bold = true,
              radius = 4,
              padding = { left = 5, right = 5, top = 1, bottom = 1 },
            },
          }
          expected[3] = { text = " ", style = {} }
        end
        assert.same(expected, flattened)
      end
    end
  end)

  it("keeps select theme defaults and whole-box action style overrides", function()
    local ui = hollow.ui
    local theme = hollow.theme.resolve_widget("select")
    local normal = ui.action_button({ id = "action" })
    assert.equals(theme.fg, normal.style.fg)
    assert.equals(4, normal.style.radius)
    assert.same({ left = 4, right = 4 }, normal.style.padding)
    local override = ui.action_button({ id = "action", style = { padding = { left = 9 } } })
    assert.same({ left = 9 }, override.style.padding)
  end)

  it("resolves action override tokens against explicit themes", function()
    local node = hollow.ui.action_button({
      id = "custom",
      theme = { fg = "#111111", muted = "#222222", hover_fg = "#333333", hover_bg = "#444444" },
      style = { fg = "muted" },
    })
    assert.equals("#222222", node.style.fg)
  end)

  it("clones button styles and assigns event fields through one path", function()
    local ui = hollow.ui
    local old = function() end
    local click, enter, leave = function() end, function() end, function() end
    local source = {
      id = "old",
      on_click = old,
      on_mouse_enter = old,
      on_mouse_leave = old,
      padding = { left = 3 },
    }
    local node = ui.button({
      id = "new",
      style = source,
      on_click = click,
      on_mouse_enter = enter,
      on_mouse_leave = leave,
    })
    assert.equals("new", node.style.id)
    assert.equals(click, node.style.on_click)
    assert.equals(enter, node.style.on_mouse_enter)
    assert.equals(leave, node.style.on_mouse_leave)
    node.style.padding.left = 9
    assert.equals(3, source.padding.left)
    assert.equals("old", source.id)
    assert.equals(old, source.on_click)

    local cleared = ui.button({ style = source }).style
    assert.is_nil(cleared.id)
    assert.is_nil(cleared.on_click)
    assert.is_nil(cleared.on_mouse_enter)
    assert.is_nil(cleared.on_mouse_leave)
    assert.same({}, ui.button().style)
    assert.same({}, ui.button({ style = false }).style)
    assert.same({}, ui.button({ style = "#123456" }).style)
  end)
end)
