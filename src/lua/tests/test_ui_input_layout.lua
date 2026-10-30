package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay text-input overlay", function()
  local ui, stack
  before_each(function()
    ui = harness.boot().hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
  end)

  local function prepare()
    ui._layout_prepare(800, 600, 8, 19)
    return ui._layout_tree
  end

  local function field_text()
    local text, field = {}, false
    for _, node in ipairs(prepare()) do
      if node.scroll_x then
        field = true
      end
      if field and node.kind == 2 then
        assert.equals(2, node.wrap)
        text[#text + 1] = node.text
      end
    end
    return table.concat(text)
  end

  it("composes styled inline runs with a horizontal viewport and reveal target", function()
    ui.input.open({ prompt = "Rename", default = "world", layout = "clay", width = 50 })
    assert.is_true(ui._overlay_state()[1].clay)
    assert.is_nil(ui._overlay_state()[1].rows)
    local nodes = prepare()
    assert.equals(50, ui._layout_frame.width)
    assert.equals("world ", field_text())
    local viewport, caret
    for _, node in ipairs(nodes) do
      if node.scroll_x then
        viewport = node
      end
      if node.id and node.id:match("input:caret$") then
        caret = node
      end
    end
    assert.equals(caret.id, viewport.reveal)
    assert.equals(19, viewport.height)
    assert.is_not_nil(caret.bg)
    local revision = ui._layout_revision
    assert.equals(nodes, prepare())
    assert.equals(revision, ui._layout_revision)
  end)

  it("retains existing editing and Enter callback behavior", function()
    local value
    ui.input.open({
      prompt = "Rename",
      default = "main",
      layout = "clay",
      on_confirm = function(v)
        value = v
      end,
    })
    prepare()
    local revision = ui._layout_revision
    assert.is_true(ui.dispatch_overlay_key("arrow_left", 0))
    assert.is_true(ui.dispatch_overlay_key("x", 0))
    assert.equals("maixn", field_text())
    assert.is_true(ui._layout_revision > revision)
    assert.is_true(ui.dispatch_overlay_key("backspace", 0))
    assert.equals("main", field_text())
    local surface = stack[1]._layout_surface
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.equals("main", value)
    assert.equals(0, #stack)
    assert.is_true(surface.destroyed)
    prepare()
    assert.is_nil(ui._layout_tree)
  end)

  it("draws an empty input caret and cancels without submitting", function()
    local submitted, cancelled = false, false
    ui.input.open({
      prompt = "Name",
      layout = "clay",
      on_confirm = function()
        submitted = true
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.equals(" ", field_text())
    ui.dispatch_overlay_key("escape", 0)
    assert.is_true(cancelled)
    assert.is_false(submitted)
    assert.equals(0, #stack)
  end)

  it("closes before invoking callbacks so the next modal can open", function()
    ui.input.open({
      prompt = "Name",
      default = "tasks",
      layout = "clay",
      on_confirm = function(value)
        ui.confirm.open({ prompt = value, layout = "clay" })
      end,
    })
    local first = stack[1]._layout_surface
    ui.dispatch_overlay_key("enter", 0)
    assert.is_true(first.destroyed)
    assert.equals(1, #stack)
    assert.not_equals(first.namespace, stack[1]._layout_surface.namespace)
    prepare()
    assert.equals(stack[1]._layout_surface.id, ui._layout_surface_id)
  end)

  it("keeps theme-owned backdrop live and respects an explicit opt-out", function()
    ui.input.open({ prompt = "Name", layout = "clay" })
    stack[1]._palette.backdrop = { color = "#123456", alpha = 99 }
    assert.same({ color = "#123456", alpha = 99 }, ui._overlay_state()[1].backdrop)
    stack[1]._palette.backdrop = false
    assert.is_nil(ui._overlay_state()[1].backdrop)
    ui.input.close()
    ui.input.open({ prompt = "Name", layout = "clay", backdrop = false })
    stack[1]._palette.backdrop = { color = "#ffffff", alpha = 255 }
    assert.is_nil(ui._overlay_state()[1].backdrop)
  end)

  it("retains the legacy path by default", function()
    ui.input.open({ prompt = "Name", default = "world" })
    assert.is_nil(ui._overlay_state()[1].clay)
    assert.is_not_nil(ui._overlay_state()[1].rows)
    assert.is_nil(stack[1]._layout_surface)
  end)
end)
