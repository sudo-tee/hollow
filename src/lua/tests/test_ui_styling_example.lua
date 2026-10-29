package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
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
    assert.equals(44, overlay.width)
    assert.equals(palette.panel_bg, overlay.chrome.bg)
    assert.equals(palette.selection_bg, overlay.rows[3].fill_bg)
    assert.equals("Hollow", overlay.rows[3].segments[1].text)
    assert.equals("Plugin", overlay.rows[4].segments[1].text)
    assert.equals(palette.primary_bg, overlay.rows[5].segments[1].bg)
    assert.equals("styling:done", overlay.rows[5].segments[1].id)
  end)

  it("keeps selection and tab callbacks working after serialization", function()
    ui._overlay_state()
    modal.widget.on_event("overlay:click", { id = "styling:choice:Plugin" })
    local overlay = ui._overlay_state()[1]
    local palette = hollow.theme.resolve_widget("select")
    assert.equals(palette.selection_bg, overlay.rows[4].fill_bg)
    assert.is_nil(overlay.rows[3].fill_bg)
    modal.widget.on_event("overlay:click", { id = "styling:tab:Recent" })
    overlay = ui._overlay_state()[1]
    assert.equals("Notes", overlay.rows[3].segments[1].text)
    assert.equals(palette.selection_bg, overlay.rows[3].fill_bg)
    modal.widget.on_event("overlay:click", { id = "styling:done" })
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
    local overlay = ui._overlay_state()[1]
    assert.equals("#112233", overlay.chrome.bg)
    assert.equals("#223344", overlay.rows[3].fill_bg)
    assert.equals("#334455", overlay.rows[3].accent_bar)
    assert.equals("#334455", overlay.rows[5].segments[1].bg)
  end)

  it("closes through its existing escape key handler", function()
    assert.is_true(modal.widget.on_key("escape", ""))
    assert.equals(0, ui.overlay.depth())
  end)
end)
