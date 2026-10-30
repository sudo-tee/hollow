package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("Clay command palette behavior", function()
  local hollow, ui, entries
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    entries = {}
    for i = 1, 8 do
      entries[i] = {
        name = "palette_item_" .. i,
        display_name = "Palette item " .. i,
        desc = "Palette item " .. i,
        category = "general",
        category_label = "General",
        chords = {},
      }
    end
  end)

  it("publishes semantic items and activates clicks", function()
    local selected
    ui.command_palette.open({
      entries = entries,
      on_confirm = function(item)
        selected = item.name
      end,
    })
    assert.is_true(ui._overlay_state()[1].clay)
    local item
    for _, node in ipairs(clay.nodes(ui)) do
      if node.list_item and node.label and node.label:find("Palette item 1", 1, true) then
        item = node
      end
    end
    assert.is_not_nil(item)
    ui.dispatch_widget_event("overlay:click", { id = item.id, index = 1 })
    assert.equals("palette_item_1", selected)
    assert.equals(0, ui.overlay.depth())
  end)

  it("keeps wheel navigation and scrollbar drag within the list", function()
    ui.command_palette.open({ entries = entries, max_height = 8 })
    local viewport = assert(clay.find(ui, ":select:viewport"))
    ui.dispatch_widget_event("overlay:scroll", { id = viewport.id, delta = -1, index = 1 })
    assert.is_truthy(clay.text(ui):find("/8", 1, true))
    ui.dispatch_widget_event(
      "overlay:scrollbar",
      { id = viewport.scrollbar_id, ratio = 1, index = 1 }
    )
    assert.equals(1, clay.find(ui, ":select:viewport").scrollbar_thumb_ratio)
  end)

  it("preserves active-domain colors, command text and match emphasis", function()
    hollow.config.set({ domains = { main = { shell = "sh" } } })
    ui.command_palette.open({ entries = ui.command_palette.build_domain_entries(), query = "sh" })
    local active_color = require("hollow.ui.shared").resolve_theme().palette.bright_green
    assert.equals(active_color, assert(clay.text_node(ui, "main")).fg)
    assert.is_true(clay.text_node(ui, "main").bold)
    assert.equals(active_color, assert(clay.text_node(ui, "• ")).fg)
    assert.is_not_nil(clay.text_node(ui, "sh", function(node)
      return node.bold
    end))
  end)

  it("leaves inactive-domain status blank", function()
    hollow.config.set({ domains = { dev = { shell = "bash" } } })
    ui.command_palette.open({ entries = ui.command_palette.build_domain_entries(), query = "dev" })
    assert.is_not_nil(clay.text_node(ui, "dev"))
    assert.is_nil(clay.text_node(ui, "• "))
  end)

  it("highlights matched palette text", function()
    ui.command_palette.open({
      entries = {
        {
          name = "product_details",
          display_name = "product-details",
          desc = "",
          category = "general",
          chords = {},
        },
      },
      query = "pro",
    })
    assert.is_not_nil(clay.text_node(ui, "pro", function(node)
      return node.bold
    end))
  end)
end)
