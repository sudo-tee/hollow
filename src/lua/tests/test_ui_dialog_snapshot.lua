package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("dialog component snapshot", function()
  it("publishes contrasting native hover text for unselected destructive actions", function()
    local ui = harness.boot().hollow.ui
    local surface = ui.layout.new({
      render = function()
        return ui.components.dialog({
          theme = { destructive_bg = "#ff0000", destructive_fg = "#ffffff" },
          actions = {
            { id = "discard", text = "Discard", kind = "destructive" },
            { id = "disabled", text = "Disabled", kind = "destructive", disabled = true },
          },
        })
      end,
    })
    local nodes = surface:snapshot({ cell_w = 10, cell_h = 20 })
    for index, node in ipairs(nodes) do
      if node.label == "Discard" then
        assert.equals("#ff0000", nodes[index + 1].fg)
        assert.equals("#ff0000", node.hover_bg)
        assert.equals("#ffffff", node.hover_fg)
      elseif node.label == "Disabled" then
        assert.is_nil(node.hover_bg)
        assert.is_nil(node.hover_fg)
      end
    end
    surface:destroy()
  end)

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
      body = "Continue?",
      selected = 1,
      hovered = 2,
      actions = {
        { id = "accept", text = "Accept", kind = "primary", on_click = function() end },
        { id = "delete", text = "Delete", kind = "destructive", on_click = function() end },
        { id = "cancel", text = "Cancel", on_click = function() end },
      },
    }
    local surface = ui.layout.new({
      theme = theme,
      render = function(ctx)
        opts.theme, opts.ctx = theme, ctx
        return ui.components.dialog(opts)
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
        hover_fg = "#ffffff",
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
        hover_fg = "#dddddd",
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
        hover_fg = "#eeeeee",
      },
      { wrap = 2, kind = 2, fg = "#111111", text = "Cancel" },
    }, nodes)
  end)

  it("supports scoped props, string body, and action IDs", function()
    local ui = harness.boot().hollow.ui
    local selected
    local theme = {
      fg = "#111111",
      title = "#222222",
      divider = "#333333",
      panel_bg = "#444444",
      selected_bg = "#555555",
      selected_fg = "#eeeeee",
      muted = "#777777",
      radius = 3,
    }
    local surface = ui.layout.new({
      theme = theme,
      render = function()
        return ui.components.dialog({
          id = "dialog",
          title = "Choose",
          body = "Body",
          selected = "dialog:action:1",
          actions = {
            {
              text = "Accept",
              on_click = function(event)
                selected = event.id
              end,
            },
            {
              id = "disabled",
              text = "Disabled",
              disabled = true,
              on_click = function()
                error("disabled")
              end,
            },
          },
        })
      end,
    })
    local nodes = surface:snapshot({ cell_w = 10, cell_h = 20 })
    local by_id = {}
    for _, node in ipairs(nodes) do
      if node.id then
        by_id[node.id] = node
      end
    end
    local action = assert(by_id[surface.namespace .. "dialog:action:1"])
    assert.equals("Accept", action.label)
    assert.is_not_nil(action.bg)
    assert.is_nil(by_id[surface.namespace .. "disabled"].clickable)
    surface:dispatch(action.id)
    assert.equals("dialog:action:1", selected)
  end)
end)
