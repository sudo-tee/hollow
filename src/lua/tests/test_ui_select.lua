package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("select search and paint", function()
  local ui
  before_each(function()
    ui = harness.boot().hollow.ui
  end)

  it("prioritizes full-label prefixes in fuzzy scores", function()
    local shared = require("hollow.ui.shared")
    assert.is_true(
      shared.fuzzy_match_score("product-details", "pro")
        > shared.fuzzy_match_score("gamer-profile-app", "pro")
    )
  end)

  it("uses custom search text instead of matching every displayed path", function()
    ui.select.open({
      items = {
        { name = "hollow", cwd = "/home/projects/hollow" },
        { name = "alpha", cwd = "/home/projects/alpha" },
      },
      fuzzy = false,
      label = function(item)
        return item.name .. " " .. item.cwd
      end,
      search_text = function(item)
        return item.name
      end,
    })
    assert.is_true(ui.dispatch_overlay_key("h", 0))
    assert.is_true(ui.dispatch_overlay_key("o", 0))
    assert.is_truthy(clay.text(ui):find("hollow", 1, true))
    assert.is_nil(clay.find(ui, ":select:item:2"))
  end)

  it("preserves custom panel paint and explicit backdrop opt-out", function()
    ui.select.open({
      items = { "alpha" },
      chrome = { bg = "#112233", alpha = 123 },
      backdrop = false,
    })
    local panel = assert(clay.find(ui, ":dialog"))
    assert.equals("#112233", panel.bg)
    assert.equals(123, panel.alpha)
    assert.is_nil(ui._overlay_state()[1].backdrop)
  end)

  it("reports initial selection and navigation without duplicate redraw notifications", function()
    local changes = {}
    ui.select.open({
      items = { "alpha", "beta", "gamma" },
      on_selection_changed = function(item)
        changes[#changes + 1] = item
      end,
    })
    assert.same({ "alpha" }, changes)
    clay.nodes(ui)
    clay.nodes(ui)
    assert.same({ "alpha" }, changes)
    ui.dispatch_overlay_key("arrow_down", 0)
    ui.dispatch_overlay_key("end", 0)
    ui.dispatch_overlay_key("arrow_up", 0)
    ui.dispatch_overlay_key("arrow_up", 0)
    ui.dispatch_overlay_key("arrow_up", 0) -- wraps
    assert.same({ "alpha", "beta", "gamma", "beta", "alpha", "gamma" }, changes)
  end)

  it("reports filtering to a new item and to no matches", function()
    local changes = {}
    ui.select.open({
      items = { "alpha", "beta" },
      on_selection_changed = function(item)
        changes[#changes + 1] = item or "empty"
      end,
    })
    ui.dispatch_overlay_key("b", 0)
    ui.dispatch_overlay_key("z", 0)
    ui.dispatch_overlay_key("backspace", 0)
    assert.same({ "alpha", "beta", "empty", "beta" }, changes)
  end)

  it("notifies before a clicked row action and stops after unmount", function()
    local calls = {}
    ui.select.open({
      items = { "alpha", "beta" },
      on_selection_changed = function(item)
        calls[#calls + 1] = "preview:" .. item
      end,
      actions = {
        {
          name = "apply",
          fn = function(item)
            calls[#calls + 1] = "apply:" .. item
            ui.select.close()
          end,
        },
      },
      on_unmount = function()
        calls[#calls + 1] = "closed"
      end,
    })
    local beta = assert(clay.find(ui, ":select:item:2"))
    ui.dispatch_widget_event("overlay:click", { id = beta.id, index = 1 })
    clay.nodes(ui)
    assert.same({ "preview:alpha", "preview:beta", "apply:beta", "closed" }, calls)
  end)

  it("reports live replacements but deduplicates fresh tables with stable ids", function()
    local id = "alpha"
    local changes = {}
    ui.select.open({
      items = function()
        return id and { { id = id } } or {}
      end,
      label = function(item)
        return item.id
      end,
      on_selection_changed = function(item)
        changes[#changes + 1] = item and item.id or "empty"
      end,
    })
    clay.nodes(ui)
    clay.nodes(ui)
    id = "beta"
    clay.nodes(ui)
    id = nil
    clay.nodes(ui)
    clay.nodes(ui)
    assert.same({ "alpha", "beta", "empty" }, changes)
  end)

  it("reports an initially empty picker once and preserves cancel hooks", function()
    local calls = {}
    ui.select.open({
      items = {},
      on_mount = function()
        calls[#calls + 1] = "mounted"
      end,
      on_selection_changed = function(item)
        assert.is_nil(item)
        calls[#calls + 1] = "empty"
      end,
      on_unmount = function()
        calls[#calls + 1] = "unmounted"
      end,
      on_cancel = function()
        calls[#calls + 1] = "cancelled"
      end,
    })
    clay.nodes(ui)
    ui.dispatch_overlay_key("escape", 0)
    assert.same({ "mounted", "empty", "unmounted", "cancelled" }, calls)
  end)

  it("reports group payloads on focus but not on hover or collapse redraws", function()
    local changes = {}
    ui.select.open({
      items = {
        { id = "alpha", group = "a" },
        { id = "beta", group = "b" },
      },
      label = function(item)
        return item.id
      end,
      group_by = function(item)
        return item.group
      end,
      group_item = function(group)
        return { id = "group:" .. group }
      end,
      on_selection_changed = function(item)
        changes[#changes + 1] = item.id
      end,
    })
    local beta = assert(clay.find(ui, ":select:item:2"))
    ui.dispatch_widget_event("overlay:hover", { id = beta.id, index = 1 })
    clay.nodes(ui)
    assert.same({ "alpha" }, changes)
    ui.dispatch_overlay_key("arrow_up", 0)
    ui.dispatch_overlay_key("enter", 0)
    clay.nodes(ui)
    assert.same({ "alpha", "group:a" }, changes)
    ui.dispatch_overlay_key("arrow_down", 0)
    assert.same({ "alpha", "group:a", "group:b" }, changes)
  end)

  it("does not preview when an exclusive modal blocks opening", function()
    ui.modal({
      render = function()
        return ui.components.text("Busy")
      end,
    })
    local calls = 0
    ui.select.open({
      items = { "alpha" },
      on_selection_changed = function()
        calls = calls + 1
      end,
    })
    clay.nodes(ui)
    assert.equals(0, calls)
  end)
end)
