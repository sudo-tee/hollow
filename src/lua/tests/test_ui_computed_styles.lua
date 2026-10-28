package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("private computed style prototype", function()
  local hollow, shared
  local palette = { fg = "#112233", muted = "#223344", hover_bg = "#334455" }

  before_each(function()
    hollow = harness.boot().hollow
    shared = require("hollow.ui.shared")
  end)

  it("separates visual properties from identity and behavior", function()
    assert.same(
      {
        text = { fg = "#112233", bold = true },
        box = {
          bg = "#000000",
          border = "#223344",
          border_size = 2,
          radius = 4,
          background_extend = 1,
        },
        layout = {
          padding = { top = 2, right = 6, bottom = 2, left = 6 },
          margin = { top = 0, right = 0, bottom = 0, left = 3 },
        },
      },
      shared.compute_style(palette, {
        id = "action",
        on_click = function() end,
        fg = "fg",
        bold = true,
        bg = "#000000",
        border = "muted",
        border_size = 2,
        radius = 4,
        background_extend = 1,
        padding = { x = 6, y = 2 },
        margin = { left = 3 },
      })
    )
  end)

  it("merges explicit state layers and final overrides without inferring state", function()
    local base = { fg = "fg", padding = 4, hover = { bg = "hover_bg" } }
    local hover = { bg = "hover_bg", padding = { right = 2 } }
    local selected = { bg = "#556677", bold = true }
    local instance = { fg = "muted", bold = false, padding = { left = 0 } }
    local resolved = shared.compute_style(palette, base, false, nil, hover, selected, instance)
    assert.same({ fg = "#223344", bold = false }, resolved.text)
    assert.equals("#556677", resolved.box.bg)
    assert.same({ top = 4, right = 2, bottom = 4, left = 0 }, resolved.layout.padding)
    assert.is_nil(shared.compute_style(palette, base).box.bg)
    resolved.layout.padding.top = 99
    assert.equals(4, base.padding)
    assert.same({ right = 2 }, hover.padding)
    assert.equals("hover_bg", base.hover.bg)
  end)

  it("preserves absent boxes and explicit zero/false reset semantics", function()
    assert.same({ text = { bold = false }, box = {}, layout = {} }, shared.compute_style({}))
    local result = shared.compute_style(
      {},
      { bg = "#112233", padding = 4 },
      { bg = false, padding = false }
    )
    assert.is_nil(result.box.bg)
    assert.same({ top = 0, right = 0, bottom = 0, left = 0 }, result.layout.padding)
    assert.is_nil(shared.computed_style_to_segment("x", result).bg)
    assert.equals("#112233", shared.compute_style({}, { bg = "#112233" }, { bg = nil }).box.bg)
  end)

  it("respects partial explicit palettes and dotted tokens without global lookups", function()
    local resolve_widget = hollow.theme.resolve_widget
    hollow.theme.resolve_widget = function()
      error("unexpected theme lookup")
    end
    local ok, result = pcall(
      shared.compute_style,
      { fg = "#abcdef", notify_levels = { warn = "#fedcba" } },
      { fg = "fg", border = "notify_levels.warn" }
    )
    hollow.theme.resolve_widget = resolve_widget
    assert.is_true(ok)
    assert.equals("#abcdef", result.text.fg)
    assert.equals("#fedcba", result.box.border)
    assert.has_error(function()
      shared.compute_style(palette, { fg = "mutd" })
    end, 'hollow.ui: unknown style token "mutd" for fg (did you mean "muted"?)')
  end)

  it("returns independent snapshots from one reused style table", function()
    local source = { fg = "fg", padding = { x = 4 }, margin = { y = 2 } }
    local first = shared.compute_style(palette, source)
    first.text.fg = "#ffffff"
    first.layout.padding.left = 99
    first.layout.margin.top = 99
    local second = shared.compute_style(palette, source)
    assert.equals("#112233", second.text.fg)
    assert.equals(4, second.layout.padding.left)
    assert.equals(2, second.layout.margin.top)
    assert.same({ fg = "fg", padding = { x = 4 }, margin = { y = 2 } }, source)
  end)

  it("rejects unsupported paint rather than promising renderer support", function()
    for _, key in ipairs({ "opacity", "shadow", "italic", "underline" }) do
      assert.has_error(function()
        shared.compute_style(palette, { [key] = true })
      end, 'hollow.ui: unsupported computed style field "' .. key .. '"')
    end
  end)

  it("adapts current row and action fixtures across bundled themes", function()
    for _, name in ipairs({ "hollow", "kanagawa-wave", "nord", "rose-pine" }) do
      local theme = hollow.theme.resolve_widget("select", hollow.theme.get(name))
      for _, selected in ipairs({ false, true }) do
        for _, hovered in ipairs({ false, true }) do
          local row = require("hollow.ui.widgets.list_style").row({}, theme, selected, hovered)
          local computed =
            shared.compute_style(theme, { bg = row.fill_bg, radius = row.fill_radius })
          assert.equals(row.fill_bg, computed.box.bg)
          assert.equals(row.fill_radius, computed.box.radius)
          -- Row accents remain separate component parts, not span borders.
          assert.is_nil(computed.box.border)
          local action = hollow.ui.action_button({ id = "run", text = "Run", theme = theme })
          local style = shared.apply_hover(action.style, hovered and "run" or nil)
          local expected = shared.style_to_segment("Run", style, theme)
          local normalized = shared.compute_style(theme, style)
          local actual = shared.computed_style_to_segment("Run", normalized, action.style.id)
          assert.same(expected, actual)
          actual.padding.left = 99
          assert.equals(4, normalized.layout.padding.left)
        end
      end
    end
  end)

  it("takes a new palette after a theme switch without stale computed caching", function()
    local first = shared.compute_style(shared.palette("all"), { fg = "muted" })
    hollow.config.set({ theme = { ui = { status = { fg = "#010203" } } } })
    local second = shared.compute_style(shared.palette("all"), { fg = "muted" })
    assert.is_not.equal(first.text.fg, second.text.fg)
    assert.equals(shared.palette("all").muted, second.text.fg)
  end)
end)
