package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

local THEMES = {
  "catppuccin-mocha",
  "dracula",
  "gruvbox-dark",
  "hollow",
  "kanagawa-wave",
  "nord",
  "onedark",
  "rose-pine",
  "solarized-dark",
  "tokyonight",
}
local CTX = { width = 1200, height = 900, cell_w = 8, cell_h = 19 }

describe("component gallery", function()
  local hollow, gallery

  before_each(function()
    hollow = harness.boot().hollow
    gallery = require("hollow.ui.components.demo")
  end)

  it("snapshots within the node cap on every bundled theme", function()
    for _, name in ipairs(THEMES) do
      local theme = hollow.theme.resolve_widget("select", hollow.theme.get(name))
      local surface = hollow.ui.layout.new({
        theme = theme,
        render = function()
          return gallery.render()
        end,
      })
      local ok, nodes = pcall(surface.snapshot, surface, CTX)
      assert(ok, name .. ": " .. tostring(nodes))
      assert(#nodes > 0 and #nodes <= 512, name .. ": " .. #nodes .. " nodes")
      for _, node in ipairs(nodes) do
        for _, key in ipairs({ "fg", "bg", "border" }) do
          local value = node[key]
          assert(
            value == nil or (type(value) == "string" and value:match("^#%x+$")),
            name .. ": unresolved " .. key .. " " .. tostring(value)
          )
        end
      end
      surface:destroy()
    end
  end)

  it("re-renders after interactive components change state", function()
    local state, surface = {}, nil
    surface = hollow.ui.layout.new({
      render = function()
        return gallery.render(state, function()
          surface:invalidate()
        end)
      end,
    })
    surface:snapshot(CTX)
    surface:dispatch(surface.namespace .. "gallery:button:solid:primary:rest")
    surface:dispatch(surface.namespace .. "gallery:item:2")
    surface:dispatch(surface.namespace .. "gallery:tab:two")
    assert.equals(1, state.clicks)
    assert.equals(2, state.item)
    assert.equals("gallery:tab:two", state.tab)
    local text = {}
    for _, node in ipairs(surface:snapshot(CTX)) do
      text[#text + 1] = node.text
    end
    assert.matches("clicks: 1", table.concat(text, "\n"))
  end)

  it("opens as a closable overlay", function()
    local depth = hollow.ui.overlay.depth()
    hollow.ui.components.demo()
    assert.equals(depth + 1, hollow.ui.overlay.depth())
    hollow.ui.dispatch_overlay_key("q", {})
    assert.equals(depth, hollow.ui.overlay.depth())
  end)

  it("opens opaque and scrolls by section", function()
    local widget = hollow.ui.components.demo()
    assert.equals(255, widget.chrome.alpha)
    assert.is_true(widget._theme_backdrop)
    local function reveal()
      for _, node in ipairs(widget._layout_surface:snapshot(CTX)) do
        if node.reveal then
          return node.reveal
        end
      end
    end
    assert.matches("gallery:section:top$", reveal())
    widget.on_event("overlay:scroll", { delta = -1 })
    assert.matches("gallery:section:Text$", reveal())
    hollow.ui.dispatch_overlay_key("end", {})
    assert.matches("gallery:section:Spacer and gap$", reveal())
    widget.on_event("overlay:scroll", { delta = 1 })
    assert.matches("gallery:section:Panel and stack$", reveal())
    hollow.ui.close_overlay_widget(widget)
  end)
end)
