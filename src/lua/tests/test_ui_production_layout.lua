package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("production Clay pickers", function()
  local ui, hollow
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
  end)

  local function prepare()
    ui._layout_prepare(1200, 900, 8, 19)
    return ui._layout_tree
  end

  local function find(suffix)
    for _, node in ipairs(prepare() or {}) do
      if node.id:sub(-#suffix) == suffix then
        return node
      end
    end
  end

  local function text(value)
    for _, node in ipairs(prepare() or {}) do
      if node.text == value then
        return node
      end
    end
  end

  local function click(node)
    ui.dispatch_widget_event("overlay:click", { id = node.id, index = 1 })
  end

  it("defaults palette to Clay, normalizes entries and preserves collapse identities", function()
    local ran, chosen
    local entries = {
      {
        name = "alpha",
        desc = "Alpha",
        category = "general",
        run = function()
          ran = true
        end,
      },
      { name = "beta", desc = "Beta", category = "user" },
    }
    ui.command_palette.open({
      entries = entries,
      on_confirm = function(item)
        chosen = item
      end,
    })
    assert.is_true(ui._overlay_state()[1].clay)
    assert.is_nil(entries[1]._palette_key)
    local alpha = find(":palette:item:entry:1")
    local beta = find(":palette:item:entry:2")
    assert.is_truthy(alpha.label:find("Alpha", 1, true))
    click(find(":palette:item:section:1"))
    assert.is_nil(find(":palette:item:entry:1"))
    assert.equals(beta.id, find(":palette:item:entry:2").id)
    click(find(":palette:item:section:1"))
    assert.equals(alpha.id, find(":palette:item:entry:1").id)
    click(find(":palette:item:entry:1"))
    assert.is_true(ran)
    assert.equals("alpha", chosen.name)
    assert.equals(0, ui.overlay.depth())
  end)

  it("keeps palette themes, key bindings, stale-click safety and cancellation", function()
    local cancelled, ran
    ui.command_palette.open({
      prompt = "Custom",
      theme = { title = "#123456" },
      backdrop = false,
      entries = {
        { name = "alpha", desc = "Alpha", chords = { "<C-a>" } },
        {
          name = "beta",
          desc = "Beta",
          run = function()
            ran = true
          end,
        },
      },
      on_cancel = function()
        cancelled = true
      end,
    })
    assert.equals("#123456", text("Custom:").fg)
    assert.is_not_nil(text("  <C-a>"))
    assert.is_nil(ui._overlay_state()[1].backdrop)
    local beta = find(":palette:item:entry:2")
    ui.dispatch_overlay_key("l", 0)
    click(beta)
    assert.is_nil(ran)
    assert.is_nil(find(":palette:item:entry:2"))
    ui.dispatch_overlay_key("escape", 0)
    assert.is_true(cancelled)
  end)

  local function workspaces(count)
    local source = require("hollow.ui.workspace.source")
    source.items = function()
      local items = {}
      for i = 1, count do
        items[i] = {
          name = "workspace " .. i,
          cwd = "/srv/project/" .. i,
          domain = "remote",
          workspace_id = i,
        }
      end
      return items
    end
  end

  it("defaults workspace picker to bounded native columns with stable IDs", function()
    workspaces(100)
    ui.workspace.open_switcher({ name_column_width = 30, column_gap = 3 })
    assert.is_true(ui._overlay_state()[1].clay)
    local name = find(":select:item:1:name")
    assert.equals(240, name.width)
    assert.is_true(name.scroll_x)
    assert.is_false(name.measure)
    local count = 0
    for _, node in ipairs(prepare()) do
      if node.list_item then
        count = count + 1
      end
    end
    assert.equals(23, count)
    assert.is_true(#prepare() <= 512)
    ui.dispatch_overlay_key("end", 0)
    assert.is_not_nil(find(":select:item:100:cwd"))
    assert.is_nil(find(":select:item:1:name"))
    ui.dispatch_overlay_key("home", 0)
    assert.equals(name.id, find(":select:item:1:name").id)
  end)

  it("preserves custom workspace formatters and rename/create keyboard flows", function()
    workspaces(1)
    require("hollow.ui.workspace.source").items = function()
      return { { name = hollow.term.current_workspace().name, workspace_id = 1 } }
    end
    ui.workspace.open_switcher({
      format_item = function(item)
        return { ui.text("Custom " .. item.name, { fg = "#abcdef", bold = true }) }
      end,
    })
    assert.equals("#abcdef", text("Custom " .. hollow.term.current_workspace().name).fg)
    assert.is_nil(find(":select:item:1:name"))
    local key, mods = hollow.keymap.parse_chord("<C-r>")
    ui.dispatch_overlay_key(key, mods)
    assert.is_true(ui._overlay_state()[1].clay)
    assert.is_not_nil(text("Rename workspace"))
    ui.dispatch_overlay_key("escape", 0)
    ui.workspace.open_switcher()
    key, mods = hollow.keymap.parse_chord("<C-n>")
    ui.dispatch_overlay_key(key, mods)
    assert.is_true(ui._overlay_state()[1].clay)
    assert.is_not_nil(text("New workspace name"))
  end)

  it("honors global fallback, per-call overrides and auto reset", function()
    workspaces(1)
    ui.layout.configure({ backend = "legacy" })
    ui.command_palette.open({ entries = {} })
    assert.is_nil(ui._overlay_state()[1].clay)
    ui.overlay.clear()
    ui.workspace.open_switcher()
    assert.is_nil(ui._overlay_state()[1].clay)
    ui.overlay.clear()
    ui.command_palette.open({ entries = {}, layout = "clay" })
    assert.is_true(ui._overlay_state()[1].clay)
    ui.overlay.clear()
    ui.layout.configure({ backend = "clay" })
    ui.input.open({ layout = "legacy" })
    assert.is_nil(ui._overlay_state()[1].clay)
    ui.overlay.clear()
    ui.select.open({ items = {} })
    assert.is_true(ui._overlay_state()[1].clay)
    ui.overlay.clear()
    ui.layout.configure({ backend = "auto" })
    ui.select.open({ items = {} })
    assert.is_nil(ui._overlay_state()[1].clay)
    ui.overlay.clear()
    ui.command_palette.open({ entries = {} })
    assert.is_true(ui._overlay_state()[1].clay)
  end)
end)
