package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

local CTX = { width = 800, height = 600, cell_w = 8, cell_h = 19 }

describe("keyboard focus", function()
  local ui, c, clicks, widget_keys, input, widget

  local function surface()
    return widget._layout_surface
  end

  local function node(id)
    for _, entry in ipairs(surface():snapshot(CTX)) do
      if entry.id == surface().namespace .. id then
        return entry
      end
    end
  end

  before_each(function()
    ui = harness.boot().hollow.ui
    c = ui.components
    clicks, widget_keys = {}, {}
    input = ui.text_input({ initial = "" })
    widget = ui.overlay.new({
      render = function()
        return c.column({
          c.button({
            id = "first",
            text = "First",
            on_click = function()
              clicks[#clicks + 1] = "first"
            end,
          }),
          c.button({ id = "disabled", text = "Off", disabled = true, on_click = function() end }),
          c.input({ id = "field", behavior = input }),
          c.button({
            id = "last",
            text = "Last",
            on_click = function()
              clicks[#clicks + 1] = "last"
            end,
          }),
        })
      end,
      on_key = function(key)
        widget_keys[#widget_keys + 1] = key
        return key == "q"
      end,
    })
    ui.overlay.push(widget)
    surface():snapshot(CTX)
  end)

  it("cycles enabled buttons and inputs with Tab and Shift-Tab", function()
    assert.is_nil(surface():focused_id())
    assert.is_true(ui.dispatch_overlay_key("tab", 0))
    assert.equals("first", surface():focused_id())
    surface():snapshot(CTX)
    ui.dispatch_overlay_key("tab", 0)
    assert.equals("field", surface():focused_id())
    surface():snapshot(CTX)
    ui.dispatch_overlay_key("tab", 0)
    assert.equals("last", surface():focused_id())
    surface():snapshot(CTX)
    ui.dispatch_overlay_key("tab", 0)
    assert.equals("first", surface():focused_id())
    surface():snapshot(CTX)
    ui.dispatch_overlay_key("tab", 1)
    assert.equals("last", surface():focused_id())
  end)

  it("paints a ring and the hover layer on the focused node", function()
    local rest = node("first")
    assert.is_nil(rest.border)
    surface():focus("first")
    local focused = node("first")
    assert.is_truthy(focused.border)
    assert.same({ left = 1, right = 1, top = 1, bottom = 1 }, focused.border_width)
    assert.equals(rest.hover_bg, focused.bg)
  end)

  it("activates the focused button with Enter and Space", function()
    surface():focus("last")
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.is_true(ui.dispatch_overlay_key("space", 0))
    assert.same({ "last", "last" }, clicks)
    assert.same({}, widget_keys)
  end)

  it("routes keys to a focused input before the widget", function()
    surface():focus("field")
    assert.is_true(ui.dispatch_overlay_key("q", 0))
    assert.equals("q", input.value)
    assert.same({}, widget_keys)
    ui.dispatch_overlay_key("escape", 0)
    assert.same({ "escape" }, widget_keys)
  end)

  it("moves focus on click without showing the ring", function()
    surface():dispatch(surface().namespace .. "last")
    assert.same({ "last" }, clicks)
    assert.is_nil(node("last").border)
    ui.dispatch_overlay_key("enter", 0)
    assert.same({ "last" }, clicks)
    ui.dispatch_overlay_key("tab", 0)
    assert.equals("first", surface():focused_id())
  end)

  it("focuses an input on click", function()
    local field = node("field")
    assert.is_true(field.clickable)
    assert.is_true(field.text_cursor)
    assert.is_nil(node("first").text_cursor)
    surface():dispatch(field.id)
    assert.equals("field", surface():focused_id())
    assert.is_truthy(node("field").border)
    assert.is_true(ui.dispatch_overlay_key("j", 0))
    assert.equals("j", input.value)
    assert.same({}, widget_keys)
  end)

  it("gives each gallery input its own text", function()
    local gallery = ui.components.demo()
    local s = gallery._layout_surface
    s:snapshot(CTX)
    s:dispatch(s.namespace .. "gallery:input")
    ui.dispatch_overlay_key("x", 0)
    local texts = {}
    for _, entry in ipairs(s:snapshot(CTX)) do
      if entry.text then
        texts[entry.text] = true
      end
    end
    assert.is_true(texts["boxedx"] == true)
    assert.is_true(texts["bare"] == true)
  end)

  it("leaves Tab to widgets that consume it", function()
    widget.on_key = function(key)
      return key == "tab"
    end
    assert.is_true(ui.dispatch_overlay_key("tab", 0))
    assert.is_nil(surface():focused_id())
  end)
end)
