package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("dialog component snapshot", function()
  it("preserves button states, geometry, and accessibility", function()
    local ui = harness.boot().hollow.ui
    local theme = {
      fg = "#111111",
      title = "#222222",
      divider = "#333333",
      panel_bg = "#444444",
      selected_bg = "#555555",
      selected_fg = "#eeeeee",
      primary_fg = "#ffffff",
      primary_bg = "#666666",
      destructive_fg = "#dddddd",
      destructive_bg = "#777777",
      radius = 3,
    }
    local opts = {
      title = "Confirm",
      prompt = "Continue?",
      selected = 1,
      hovered = 2,
      footer = {
        { id = "accept", text = "Accept", kind = "primary", on_click = function() end },
        { id = "delete", text = "Delete", kind = "destructive", on_click = function() end },
        { id = "cancel", text = "Cancel", on_click = function() end },
      },
    }
    local surface = ui.layout.new({
      theme = theme,
      render = function(ctx)
        return ui.components.dialog(opts, theme, ctx)
      end,
    })
    local nodes = surface:snapshot({ cell_w = 10, cell_h = 20 })
    for _, node in ipairs(nodes) do
      if node.id then
        node.id = node.id:gsub("^layout:%d+:", "test:")
      end
    end
    local padding = { top = 0, right = 10, bottom = 0, left = 10 }
    assert.same({
      {
        id = "test:auto:1",
        children = 2,
        border_width = { top = 0, right = 0, bottom = 0, left = 0, between_children = 1 },
        border = "#333333",
        gap = 10,
        width = -1,
      },
      { kind = 2, bold = true, fg = "#222222", text = "Confirm" },
      { children = 3, width = -1 },
      { kind = 2, fg = "#111111", text = "Continue?" },
      { height = 20 },
      { children = 4, kind = 1, gap = 20, width = -1 },
      { width = -1 },
      {
        id = "test:accept",
        hover_bg = "#666666",
        bg = "#666666",
        label = "Accept",
        clickable = true,
        children = 1,
        radius = 3,
        padding = padding,
      },
      { wrap = 2, kind = 2, bold = true, fg = "#ffffff", text = "Accept" },
      {
        id = "test:delete",
        hover_bg = "#777777",
        bg = "#777777",
        label = "Delete",
        clickable = true,
        children = 1,
        radius = 3,
        padding = padding,
      },
      { wrap = 2, kind = 2, bold = true, fg = "#dddddd", text = "Delete" },
      {
        id = "test:cancel",
        padding = padding,
        label = "Cancel",
        clickable = true,
        children = 1,
        radius = 3,
        hover_bg = "#808080",
      },
      { wrap = 2, kind = 2, fg = "#111111", text = "Cancel" },
    }, nodes)
  end)
end)
