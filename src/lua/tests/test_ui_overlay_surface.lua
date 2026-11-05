package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

local CTX = { width = 800, height = 600, cell_w = 10, cell_h = 20 }

describe("shared overlay surfaces", function()
  local ui, c

  before_each(function()
    ui = harness.boot().hollow.ui
    c = ui.components
  end)

  it("uses a single frame/chrome path for regular overlays", function()
    local widget = ui.overlay.new({
      width = 36,
      height = 8,
      max_height = 20,
      align = "bottom_right",
      chrome = { margin = { left = 2, right = 3, top = 4, bottom = 5 } },
      render = function()
        return c.text("Overlay")
      end,
    })
    ui.overlay.push(widget)
    local surface = widget._layout_surface
    local nodes = surface:snapshot(CTX)
    assert.equals(36, surface.frame.width)
    assert.equals(8, surface.frame.height)
    assert.equals(20, surface.frame.max_height)
    assert.equals(2, surface.frame.align_x)
    assert.equals(2, surface.frame.align_y)
    assert.equals(2, surface.frame.margin.left)
    assert.equals(5, surface.frame.margin.bottom)
    assert.equals("Overlay", nodes[#nodes].text)
    ui.overlay.clear()
  end)

  it("preserves modal labels, insets, and preferred height", function()
    local handle = ui.modal({
      title = "Test dialog",
      width = 50,
      max_height = 18,
      align = "top_left",
      center_content = true,
      render = function()
        return c.text("Modal body"), 100
      end,
    })
    assert.is_truthy(handle)
    local surface = handle.widget._layout_surface
    local nodes = surface:snapshot(CTX)
    assert.equals(50, surface.frame.width)
    assert.equals(18, surface.frame.max_height)
    assert.equals(0, surface.frame.align_x)
    assert.equals(0, surface.frame.align_y)
    assert.is_true(surface.frame.height > 100 / CTX.cell_h)
    assert.equals("Test dialog", nodes[1].label)
    assert.equals("Modal body", nodes[#nodes].text)
    handle.close()
  end)

  it("dispatches each overlay and modal click exactly once", function()
    local hits, reported = {}, {}
    local function button()
      return c.button({
        id = "run",
        text = "Run",
        on_click = function()
          hits[#hits + 1] = "clicked"
        end,
      })
    end
    local regular = ui.overlay.new({ render = button })
    ui.overlay.push(regular)
    local surface = regular._layout_surface
    surface:snapshot(CTX)
    regular.on_event("overlay:click", { id = surface.namespace .. "run" })
    assert.same({ "clicked" }, hits)
    ui.overlay.clear()

    local modal = ui.modal({
      render = function()
        return button()
      end,
      on_event = function(event, payload)
        if event == "overlay:click" then
          reported[#reported + 1] = payload.id
        end
      end,
    })
    surface = modal.widget._layout_surface
    surface:snapshot(CTX)
    modal.widget.on_event("overlay:click", { id = surface.namespace .. "run" })
    assert.same({ "clicked", "clicked" }, hits)
    assert.same({ "run" }, reported)
    modal.close()
  end)
end)
