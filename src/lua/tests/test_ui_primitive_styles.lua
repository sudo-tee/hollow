package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("primitive style compatibility", function()
  local hollow

  setup(function()
    hollow = harness.boot().hollow
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
