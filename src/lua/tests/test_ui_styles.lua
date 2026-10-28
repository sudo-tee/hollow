package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI styles", function()
  local env
  local hollow
  local shared

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    shared = require("hollow.ui.shared")
  end)

  it("merges style layers without mutating nested inputs", function()
    local base = {
      fg = "muted",
      padding = 4,
      hover = { fg = "hover_fg", padding = { left = 2 } },
    }
    local override = { padding = { right = 0 }, hover = { bg = "hover_bg" } }
    local merged = shared.merge_styles(false, base, nil, override)

    assert.same({ top = 4, right = 0, bottom = 4, left = 4 }, merged.padding)
    assert.same({ fg = "hover_fg", bg = "hover_bg", padding = { left = 2 } }, merged.hover)
    assert.same(4, base.padding)
    assert.same({ fg = "hover_fg", padding = { left = 2 } }, base.hover)
    assert.same({ padding = { right = 0 }, hover = { bg = "hover_bg" } }, override)
    assert.is_not.equal(base, merged)
    assert.is_not.equal(base.hover, merged.hover)
    assert.same(merged, hollow.ui.style(false, base, nil, override))
  end)

  it("composes conditional layers into fresh tables", function()
    local base = { fg = "muted", bold = false }
    local active = { fg = "selection_fg", bold = true }

    assert.same(base, hollow.ui.style(base, false and active))
    assert.same({ fg = "selection_fg", bold = true }, hollow.ui.style(base, true and active))

    local first = hollow.ui.style(base, active)
    first.id = "leaked"
    assert.is_nil(hollow.ui.style(base, active).id)
    assert.is_nil(base.id)
    assert.is_nil(active.id)
  end)

  it("provides token-based style presets", function()
    assert.same({
      muted = { fg = "muted" },
      title = { fg = "title", bold = true },
      pill = { radius = 4, padding = { x = 4 } },
      badge = { fg = "panel_bg", bold = true, radius = 4, padding = { x = 5, y = 1 } },
      kbd = { fg = "fg", bg = "input_bg", radius = 3, padding = { x = 4 } },
    }, hollow.ui.styles)
    for _, preset in pairs(hollow.ui.styles) do
      local segment = shared.style_to_segment("preset", hollow.ui.style(preset))
      assert.equals("preset", segment.text)
    end
  end)

  it("keeps presets isolated from bar auto-ids and derived style mutations", function()
    local ui = hollow.ui
    local node = ui.span("pill", ui.style(ui.styles.pill, { hover = { fg = "hover_fg" } }))
    require("hollow.ui.widgets.bars.bar_events").register(node, {}, function()
      return "auto-id"
    end)
    assert.equals("auto-id", node.style.id)
    node.style.padding.left = 99
    assert.is_nil(ui.styles.pill.id)
    assert.is_nil(ui.styles.pill.hover)
    assert.same({ x = 4 }, ui.styles.pill.padding)
    ui.tab({ id = "preset-tab", label = "Tab", badge = { text = 2, color = "#123456" } })
    assert.is_nil(ui.styles.badge.id)
    assert.is_nil(ui.styles.badge.bg)
  end)

  it("merges and resolves themed styles in one call", function()
    local theme = { muted = "#111111", selection_fg = "#222222" }
    local base = { fg = "muted", bold = false }
    local active = { fg = "selection_fg", bold = true }

    assert.same({ fg = "#111111", bold = false }, hollow.ui.styled(theme, base, false and active))
    assert.same({ fg = "#222222", bold = true }, hollow.ui.styled(theme, base, active))
    assert.same({ fg = "muted", bold = false }, hollow.ui.styled(nil, base))
    assert.equals("muted", base.fg)
  end)

  it("retains themed_style as the same helper for existing configs", function()
    assert.equals(hollow.ui.styled, hollow.ui.themed_style)
    local base = { fg = "muted", hover = { bg = "hover_bg" }, padding = { x = 4 } }
    local palette = { muted = "#111111", hover_bg = "#222222" }
    assert.same(
      hollow.ui.styled(palette, base, false, { padding = { right = 0 } }),
      hollow.ui.themed_style(palette, base, false, { padding = { right = 0 } })
    )
    local resolved = hollow.ui.styled(palette, base)
    resolved.hover.bg = "#ffffff"
    resolved.padding.left = 99
    assert.equals("hover_bg", base.hover.bg)
    assert.same({ x = 4 }, base.padding)
    assert.same(hollow.ui.style(base), hollow.ui.styled(nil, base))
    assert.has_error(function()
      hollow.ui.styled({ fg = "#111111" }, { fg = "missing" })
    end)
  end)

  it("normalizes box shorthand before applying side overrides", function()
    assert.same(
      { top = 4, right = 0, bottom = 4, left = 4 },
      shared.merge_styles({ padding = 4 }, { padding = { right = 0 } }).padding
    )
    assert.same(
      { left = 8, right = 0 },
      shared.merge_styles({ padding = { x = 8 } }, { padding = { right = 0 } }).padding
    )
    assert.same(
      { top = 0, right = 8, bottom = 3, left = 8 },
      shared.merge_styles({ padding = { 3, 8 } }, { padding = { top = 0 } }).padding
    )
    assert.same({ right = 0 }, shared.merge_styles({ padding = { right = 0 } }).padding)
  end)

  it("retains normalized sides across multiple style layers", function()
    local base = { padding = { x = 8 }, margin = 2 }
    local merged = hollow.ui.style(
      base,
      { padding = { right = 0 }, margin = false },
      { padding = { top = 3 }, margin = { left = 1 } },
      { padding = { bottom = 4 }, margin = { right = 5 } }
    )
    assert.same({ left = 8, right = 0, top = 3, bottom = 4 }, merged.padding)
    assert.same({ left = 1, right = 5 }, merged.margin)
    merged.padding.left = 99
    assert.same({ x = 8 }, base.padding)
    assert.equals(2, base.margin)
  end)

  it("normalizes segment padding without filling sparse merge boxes", function()
    local cases = {
      { value = 2.5, expected = { top = 2.5, right = 2.5, bottom = 2.5, left = 2.5 } },
      { value = { left = 9 }, expected = { top = 0, right = 0, bottom = 0, left = 9 } },
      { value = { 3, 8 }, expected = { top = 3, right = 8, bottom = 3, left = 8 } },
      { value = { x = 4, y = 1 }, expected = { top = 1, right = 4, bottom = 1, left = 4 } },
      { value = false, expected = { top = 0, right = 0, bottom = 0, left = 0 } },
      {
        value = { top = -1, right = math.huge, bottom = 0 / 0, left = "2" },
        expected = { top = 0, right = 0, bottom = 0, left = 0 },
      },
    }
    for _, case in ipairs(cases) do
      assert.same(case.expected, shared.normalize_segment_padding(case.value))
      assert.same(case.expected, shared.style_to_segment("x", { padding = case.value }).padding)
    end
    assert.is_nil(shared.style_to_segment("x", {}).padding)
    assert.same({ left = 9 }, hollow.ui.style({ padding = { left = 9 } }).padding)
  end)

  it("merges margins and recursive hover boxes without sharing nested tables", function()
    local source = { margin = { x = 8, y = 3 }, hover = { hover = { padding = 2 } } }
    local merged = hollow.ui.style(source, {
      margin = { top = 0 },
      hover = { hover = { padding = { right = 0 } } },
    })
    assert.same({ left = 8, right = 8, top = 0, bottom = 3 }, merged.margin)
    assert.same({ left = 2, right = 0, top = 2, bottom = 2 }, merged.hover.hover.padding)
    merged.margin.left = 99
    merged.hover.hover.padding.left = 99
    assert.same({ x = 8, y = 3 }, source.margin)
    assert.equals(2, source.hover.hover.padding)
  end)

  it("resolves color tokens and preserves non-color values", function()
    local source = {
      fg = "muted",
      bg = "#123456",
      border = "notify_levels.warn",
      radius = "muted",
      hover = { fg = "hover_fg", bg = "#abcdef", border = "accent" },
    }
    local palette = {
      muted = "#111111",
      hover_fg = "#222222",
      accent = "#333333",
      notify_levels = { warn = "#ffaa00" },
    }
    local result = shared.resolve_tokens(source, palette)
    assert.same({
      fg = "#111111",
      bg = "#123456",
      border = "#ffaa00",
      radius = "muted",
      hover = { fg = "#222222", bg = "#abcdef", border = "#333333" },
    }, result)
    assert.equals("muted", source.fg)
    assert.equals("hover_fg", source.hover.fg)
  end)

  it("reports unknown tokens with a did-you-mean hint", function()
    assert.has_error(function()
      shared.resolve_tokens({ fg = "mutd" }, { muted = "#111111" })
    end, 'hollow.ui: unknown style token "mutd" for fg (did you mean "muted"?)')
  end)

  it("resolves explicit palettes and lazily uses current palettes", function()
    assert.equals(
      "#123456",
      shared.style_to_segment("x", { fg = "muted" }, { muted = "#123456" }).fg
    )
    local current = shared.palette("all")
    assert.equals(current.muted, shared.style_to_segment("x", { fg = "muted" }).fg)
    assert.equals(current.muted, shared.style_to_segment("x", { fg = "muted" }, current).fg)
  end)

  it("invalidates lazy palettes when configuration changes theme", function()
    local before = shared.palette("all").muted
    hollow.config.set({ theme = { ui = { status = { fg = "#010203" } } } })
    local after = shared.palette("all").muted
    assert.is_not.equal(before, after)
    assert.equals(after, shared.style_to_segment("x", { fg = "muted" }).fg)
  end)

  it("combines widget and bar tokens", function()
    local palette = shared.bar_palette()
    assert.equals(hollow.theme.resolve_widget("all").muted, palette.muted)
    assert.equals(hollow.theme.current().ui.tab_bar.active_tab.fg, palette.tab_active_fg)
    assert.equals(
      palette.tab_active_fg,
      shared.style_to_segment("active", { fg = "tab_active_fg" }, palette).fg
    )
  end)

  it("passes bar palettes through real span serialization", function()
    local ui = hollow.ui
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { ui.span("bar", { fg = "tab_active_fg", bg = "muted" }) }
      end,
    }))
    local item = ui._topbar_state().items[1]
    assert.equals(shared.bar_palette().tab_active_fg, item.fg)
    assert.equals(shared.bar_palette().muted, item.bg)
    ui.topbar.unmount()
  end)

  it("does not swallow unknown token errors in bars", function()
    local ui = hollow.ui
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { ui.span("bar", { fg = "mutd" }) }
      end,
    }))
    local ok, message = pcall(ui._topbar_state)
    ui.topbar.unmount()
    assert.is_false(ok)
    assert.matches('unknown style token "mutd"', message, 1, true)
  end)

  it("uses overlay widget kind instead of the generic palette", function()
    local ui = hollow.ui
    hollow.config.set({ theme = { ui = { widgets = { select = { muted = "#142536" } } } } })
    local widget = ui.overlay.new({
      render = function()
        return ui.row({ ui.text("detail", { fg = "muted" }) })
      end,
    })
    widget._kind = "select"
    ui.overlay.push(widget)
    local segment = ui._overlay_state()[1].rows[1].segments[1]
    ui.overlay.pop()
    assert.equals("#142536", segment.fg)
  end)
end)
