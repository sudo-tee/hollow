package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("public UI styling example", function()
  local hollow, ui, modal
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    modal = assert(loadfile("examples/ui-styling.lua"))()()
  end)

  it("renders tabs, selectable rows, a themed action and panel using public APIs", function()
    local overlay = ui._overlay_state()[1]
    local palette = hollow.theme.resolve_widget("select")
    assert.is_true(overlay.clay)
    assert.equals(palette.panel_bg, clay.find(ui, ":dialog").bg)
    assert.equals(palette.selection_bg, clay.find(ui, ":styling:choice:Hollow").bg)
    assert.is_not_nil(clay.text_node(ui, "Hollow"))
    assert.is_not_nil(clay.text_node(ui, "Plugin"))
    assert.equals(palette.primary_bg, clay.find(ui, ":styling:done").bg)
  end)

  it("keeps selection and tab callbacks working after serialization", function()
    modal.widget.on_event("overlay:click", { id = clay.find(ui, ":styling:choice:Plugin").id })
    local palette = hollow.theme.resolve_widget("select")
    assert.equals(palette.selection_bg, clay.find(ui, ":styling:choice:Plugin").bg)
    assert.is_nil(clay.find(ui, ":styling:choice:Hollow").bg)
    modal.widget.on_event("overlay:click", { id = clay.find(ui, ":styling:tab:Recent").id })
    assert.is_not_nil(clay.text_node(ui, "Notes"))
    assert.equals(palette.selection_bg, clay.find(ui, ":styling:choice:Notes").bg)
    modal.widget.on_event("overlay:click", { id = clay.find(ui, ":styling:done").id })
    assert.equals(0, ui.overlay.depth())
  end)

  it("refreshes an open example on theme changes without rebuilding it", function()
    ui._overlay_state()
    hollow.config.set({
      theme = {
        ui = {
          widgets = {
            select = {
              panel_bg = "#112233",
              selection_bg = "#223344",
              primary_bg = "#334455",
              parts = { list_row = { accent = "primary_bg" } },
            },
          },
        },
      },
    })
    assert.equals("#112233", clay.find(ui, ":dialog").bg)
    assert.equals("#223344", clay.find(ui, ":styling:choice:Hollow").bg)
    assert.equals("#334455", clay.find(ui, ":styling:done").bg)
  end)

  it("closes through its existing escape key handler", function()
    assert.is_true(modal.widget.on_key("escape", ""))
    assert.equals(0, ui.overlay.depth())
  end)
end)
