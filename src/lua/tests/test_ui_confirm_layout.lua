package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay confirmation overlay", function()
  local hollow, ui, stack
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
  end)

  local function prepare()
    ui._layout_prepare(800, 600, 8, 19)
    return ui._layout_tree
  end

  local function find_button(label)
    for _, node in ipairs(prepare()) do
      if node.label == label and node.clickable then
        return node
      end
    end
    error("button not found: " .. label)
  end

  it("uses the overlay shell and cached tree without serializing legacy rows", function()
    ui.confirm.open({ title = "Delete", prompt = "Delete this file?", width = 60 })
    local state = ui._overlay_state()
    assert.equals(1, #state)
    assert.is_true(state[1].clay)
    assert.is_nil(state[1].rows)
    local tree = prepare()
    local revision = ui._layout_revision
    assert.equals(1, ui._layout_owner)
    assert.equals(60, ui._layout_frame.width)
    assert.equals("Delete", tree[1].label)
    assert.equals(tree, prepare())
    assert.equals(revision, ui._layout_revision)
  end)

  it("preserves navigation, Enter values and cancellation", function()
    local value, cancelled
    ui.confirm.open({
      prompt = "Continue?",
      on_confirm = function(v)
        value = v
      end,
    })
    prepare()
    assert.is_true(ui.dispatch_overlay_key("arrow_right", 0))
    assert.is_true(ui.dispatch_overlay_key("enter", 0))
    assert.is_false(value)
    assert.equals(0, #stack)
    ui.confirm.open({
      prompt = "Continue?",
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.is_true(ui.dispatch_overlay_key("escape", 0))
    assert.is_true(cancelled)
    assert.equals(0, #stack)
    prepare()
    assert.is_nil(ui._layout_tree)
  end)

  it("routes namespaced click and hover events to the owning dialog", function()
    local value, button_value
    ui.confirm.open({
      prompt = "Choose",
      buttons = {
        {
          text = "Keep",
          id = "keep",
          value = 42,
          on_confirm = function(v)
            button_value = v
          end,
        },
        { text = "Discard", id = "discard", value = 99 },
      },
      on_confirm = function(v)
        value = v
      end,
    })
    local button = find_button("Discard")
    local revision = ui._layout_revision
    local hover = { id = button.id, index = 1 }
    ui.dispatch_widget_event("overlay:hover", hover)
    assert.equals(button.id, hover.id)
    prepare()
    assert.equals(revision, ui._layout_revision)
    local keep = find_button("Keep")
    ui.dispatch_widget_event("overlay:click", { id = keep.id, index = 1 })
    assert.equals(42, value)
    assert.equals(42, button_value)
    assert.equals(0, #stack)
  end)

  it("destroys callbacks when popped, clears or closed and preserves modal ownership", function()
    local calls = 0
    ui.confirm.open({
      prompt = "First",
      on_confirm = function()
        calls = calls + 1
      end,
    })
    local button = find_button("Yes")
    local surface = stack[1]._layout_surface
    ui.confirm.open({ prompt = "Second" })
    assert.equals(1, #stack)
    assert.equals(surface, stack[1]._layout_surface)
    ui.overlay.clear()
    assert.is_true(surface.destroyed)
    surface:dispatch(button.id)
    assert.equals(0, calls)
    ui.confirm.open({ prompt = "Third" })
    assert.not_equals(surface.namespace, stack[1]._layout_surface.namespace)
    ui.confirm.close()
    assert.equals(0, #stack)
  end)

  it("suspends standalone demo behind a Clay modal", function()
    ui.layout.show(ui.components.text("demo"))
    ui.confirm.open({ prompt = "Confirmation" })
    prepare()
    assert.is_not_nil(ui._layout_tree)
    assert.is_true(ui._overlay_state()[1].clay)
    assert.is_not_nil(find_button("Yes"))
    ui.confirm.close()
    assert.equals("demo", prepare()[1].text)
  end)
end)
