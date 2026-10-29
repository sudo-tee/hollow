package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("overlay lifecycle retention", function()
  local ui, stack, registry
  before_each(function()
    ui = harness.boot().hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
    registry = require("hollow.ui.builder.internal.click_registry")
  end)

  it("releases a closed legacy palette and its theme after rendering", function()
    local refs = setmetatable({}, { __mode = "v" })
    local function open_and_close()
      ui.command_palette.open({
        entries = {
          { name = "example", desc = "Example", category = "general", chords = {} },
        },
        layout = "legacy",
      })
      local widget = assert(stack[1])
      ui._overlay_state()
      refs[1], refs[2], refs[3] = widget, widget._palette, widget.chrome
      ui.overlay.clear()
    end
    open_and_close()
    collectgarbage("collect")
    collectgarbage("collect")
    assert.is_nil(refs[1])
    assert.is_nil(refs[2])
    assert.is_nil(refs[3])
  end)

  it("preserves callbacks while another overlay remains", function()
    ui.overlay.push(ui.overlay.new({
      render = function()
        return ui.row({})
      end,
    }))
    local modal = ui.modal({
      render = function()
        return ui.row({})
      end,
    })
    local callback = function() end
    registry.register("existing", callback)
    modal.close()
    assert.equals(callback, registry.lookup("existing"))
    ui.overlay.clear()
  end)
end)
