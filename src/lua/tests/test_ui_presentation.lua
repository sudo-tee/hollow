package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("shared presentation adapters", function()
  local hollow, ui, shared
  before_each(function()
    hollow = harness.boot().hollow
    ui, shared = hollow.ui, require("hollow.ui.shared")
  end)

  it("normalizes bar and chrome paint identically while projecting their legacy fields", function()
    local style = {
      fg = "muted",
      bg = "panel_bg",
      border = "panel_border",
      radius = 4.9,
      padding = { x = 3.8, y = -2 },
      margin = { top = 2.7 },
      border_size = 0,
      alpha = 123.8,
      close_fg = "hover_fg",
      close_radius = 3.9,
      bold = true,
      id = "paint",
    }
    local palette = shared.bar_palette()
    local original = hollow.util.clone_value(style)
    local computed = shared.normalize_surface_style(style, palette)
    assert.equals(4, computed.radius)
    assert.same({ top = 0, right = 3, bottom = 0, left = 3 }, computed.padding)
    assert.equals(123, computed.alpha)
    assert.equals(palette.hover_fg, computed.close_fg)
    assert.equals(0, computed.border_size)
    assert.same(original, style)
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { ui.span("paint", style) }
      end,
    }))
    local bar = ui._topbar_state().items[1].style
    local chrome = shared.normalize_overlay_chrome(style, palette)
    for _, key in ipairs({ "bg", "border", "radius", "padding", "margin" }) do
      assert.same(computed[key], bar[key])
      assert.same(computed[key], chrome[key])
    end
    assert.is_nil(bar.alpha)
    assert.is_nil(bar.border_size)
    assert.is_nil(chrome.fg)
    assert.is_nil(chrome.close_fg)
    assert.equals(0, chrome.border_size)
    assert.same({}, shared.normalize_overlay_chrome({}) or {})
    assert.is_nil(shared.normalize_surface_style({ fg = false, radius = 0, padding = 0 }))
  end)

  it("retains the old native sidebar paint as explicit Lua defaults", function()
    ui.sidebar.mount(ui.sidebar.new({
      width = 21,
      side = "right",
      reserve = true,
      render = function()
        return ui.row({ ui.text("plain") })
      end,
    }))
    local sidebar = ui._sidebar_state()
    assert.same({ fg = "#dcdcdc", bg = "#161b22", border = "#7aa2f7", alpha = 235 }, sidebar.style)
    assert.equals(21, sidebar.width)
    assert.equals("right", sidebar.side)
    assert.is_true(sidebar.reserve)
    assert.equals("plain", sidebar.rows[1][1].text)
  end)

  it("shares row paint between sidebar and overlay without changing segment arrays", function()
    local function row()
      return ui.row({ ui.text("choice") }, {
        id = "choice",
        variant = "selectable",
        selected = true,
        style = { fg = "muted", radius = 6 },
        divider = "divider",
        accent_bar = false,
      })
    end
    local palette = shared.palette("overlay")
    ui.overlay.push(ui.overlay.new({ render = row }))
    ui.sidebar.mount(ui.sidebar.new({ width = 30, render = row }))
    local overlay = ui._overlay_state()[1].rows[1]
    local sidebar = ui._sidebar_state()
    for _, key in ipairs({ "fill_bg", "fill_radius", "accent_bar", "divider" }) do
      assert.same(overlay[key], sidebar.row_styles[1][key])
    end
    assert.equals(palette.muted, sidebar.rows[1][1].fg)
    assert.equals("choice", sidebar.rows[1][1].text)
    assert.is_nil(sidebar.rows[1].segments)
    assert.is_nil(sidebar.rows[1][1].bg)
  end)

  it("resolves each styled sidebar row once before adapting text and paint", function()
    ui.sidebar.mount(ui.sidebar.new({
      render = function()
        return ui.row({ ui.text("choice") }, { variant = "selectable", selected = true })
      end,
    }))
    local original, calls = shared.resolve_row_style, 0
    shared.resolve_row_style = function(...)
      calls = calls + 1
      return original(...)
    end
    local ok, result = pcall(ui._sidebar_state)
    shared.resolve_row_style = original
    assert.is_true(ok)
    assert.equals(1, calls)
    assert.equals("choice", result.rows[1][1].text)
  end)

  it("keeps sidebar paint overrides separate from geometry", function()
    ui.sidebar.mount(ui.sidebar.new({
      width = 12,
      style = { bg = "panel_bg", fg = "muted", alpha = 0 },
      render = function()
        return ui.row({ ui.text("text") })
      end,
    }))
    local sidebar = ui._sidebar_state()
    assert.equals(shared.palette("sidebar").panel_bg, sidebar.style.bg)
    assert.equals(shared.palette("sidebar").muted, sidebar.style.fg)
    assert.equals(0, sidebar.style.alpha)
    assert.equals(12, sidebar.width)
    assert.has_error(function()
      shared.sidebar_surface_style({ padding = 4 }, shared.palette("sidebar"))
    end, "hollow.ui: unsupported sidebar surface field padding")
  end)

  it(
    "moves raw tab fallback paint without injecting layout or suppressing explicit styles",
    function()
      hollow.config.set({ top_bar_mode = "always" })
      ui.topbar.mount(ui.topbar.new({
        render = function()
          return { ui.bar.tabs({ style = { fg = "#123456", padding = { left = 7 }, radius = 4 } }) }
        end,
      }))
      local tab = ui._topbar_state().items[1].tabs[1]
      local active = hollow.term.tabs()[1].is_active
      assert.same({
        fg = active and "#ffffff" or "#b9b9b9",
        bg = active and "#373a48" or "#23252e",
        selection_accent = "#7896dc",
      }, tab.fallback_style)
      assert.equals("#123456", tab.style.fg)
      assert.equals(7, tab.style.padding.left)
      assert.equals(4, tab.style.radius)
      assert.is_nil(tab.fallback_style.padding)
    end
  )

  it("uses theme part overrides on tabs, sidebar and raw scrollbars after invalidation", function()
    hollow.config.set({ top_bar_mode = "always" })
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { ui.bar.tabs() }
      end,
    }))
    ui.sidebar.mount(ui.sidebar.new({
      render = function()
        return ui.row({ ui.text("row") })
      end,
    }))
    ui.overlay.push(ui.overlay.new({
      render = function()
        return ui.row({ ui.text("scroll") }, { scrollbar_track = true })
      end,
    }))
    ui._topbar_state()
    hollow.config.set({
      theme = {
        ui = {
          widgets = {
            all = {
              parts = {
                tab = {
                  active = { bg = "#112233" },
                  inactive = { bg = "#112233" },
                  selection_accent = "#223344",
                },
                sidebar = { bg = "#334455" },
                scrollbar = { track = "#445566", thumb = "#556677" },
              },
            },
          },
        },
      },
    })
    assert.equals("#112233", ui._topbar_state().items[1].tabs[1].fallback_style.bg)
    assert.equals("#223344", ui._topbar_state().items[1].tabs[1].fallback_style.selection_accent)
    assert.equals("#334455", ui._sidebar_state().style.bg)
    local row = ui._overlay_state()[1].rows[1]
    assert.equals("#445566", row.scrollbar_track_color)
    assert.equals("#556677", row.scrollbar_thumb_color)
  end)

  it(
    "keeps explicit scrollbar aliases and resolves their tokens without mutating inputs",
    function()
      local row = ui.row({}, {
        scrollbar_track = true,
        scrollbar_track_color = "muted",
        scrollbar_thumb_color = "panel_border",
      })
      local palette = shared.palette("overlay")
      local actual = shared.serialize_row_paint(row, palette)
      assert.equals(palette.muted, actual.scrollbar_track_color)
      assert.equals(palette.panel_border, actual.scrollbar_thumb_color)
      assert.equals("muted", row.scrollbar_track_color)
    end
  )

  it("keeps part palettes and sibling output styles independent", function()
    local palette = shared.bar_palette()
    local before = hollow.util.clone_value(palette.parts)
    local first = shared.tab_fallback_style(true, palette)
    first.bg = "#ffffff"
    local sidebar = shared.sidebar_surface_style(nil, palette)
    sidebar.bg = "#000000"
    assert.equals(before.tab.active.bg, shared.tab_fallback_style(true, palette).bg)
    assert.equals(before.sidebar.bg, shared.sidebar_surface_style(nil, palette).bg)
    assert.same(before, palette.parts)
  end)

  it("keeps legacy default tab and sidebar paint stable across bundled themes", function()
    for _, name in ipairs({ "hollow", "kanagawa-wave", "nord", "rose-pine" }) do
      local palette = hollow.theme.resolve_widget("all", hollow.theme.get(name))
      assert.equals("#161b22", shared.sidebar_surface_style(nil, palette).bg)
      assert.equals("#373a48", shared.tab_fallback_style(true, palette).bg)
      assert.equals("#23252e", shared.tab_fallback_style(false, palette).bg)
      local list_row = require("hollow.ui.styles.list_row")
      local row = list_row(palette, { selected = true }).paint
      assert.equals(palette.panel_border, row.accent_bar)
      assert.equals(palette.scrollbar_track, row.scrollbar_track_color)
      assert.equals(palette.scrollbar_thumb, row.scrollbar_thumb_color)
      assert.equals(
        "#5a6375",
        shared.serialize_row_paint({ scrollbar_track = true }, palette).scrollbar_track_color
      )
    end
  end)

  it("shares accent and scrollbar parts with built-in list recipes", function()
    local list_row = require("hollow.ui.styles.list_row")
    local palette = shared.merge_styles(shared.palette("overlay"), {
      parts = {
        list_row = { accent = "muted" },
        scrollbar = { track = "divider", thumb = "primary_bg" },
      },
    })
    local before = hollow.util.clone_value(palette)
    local built = list_row(palette, { selected = true }).paint
    local raw = ui.row({}, { variant = "selectable", selected = true, scrollbar_track = true })
    local paint = shared.serialize_row_paint(raw, palette)
    for _, key in ipairs({ "accent_bar", "scrollbar_track_color", "scrollbar_thumb_color" }) do
      assert.equals(built[key], paint[key])
    end
    assert.equals(palette.muted, paint.accent_bar)
    assert.equals(palette.muted, list_row(palette, { selected = true }).indicator.fg)
    assert.same(before, palette)

    palette.parts.list_row.accent = false
    assert.is_nil(list_row(palette, { selected = true }).paint.accent_bar)
    assert.is_nil(shared.serialize_row_paint(raw, palette).accent_bar)
    raw.accent_bar = "primary_bg"
    assert.equals(palette.primary_bg, shared.serialize_row_paint(raw, palette).accent_bar)
  end)

  it(
    "retains semantic list scrollbars and literal raw-track fallback on partial palettes",
    function()
      local list_row = require("hollow.ui.styles.list_row")
      local palette = { scrollbar_track = "#123456", scrollbar_thumb = "#234567" }
      local built = list_row(palette).paint
      assert.equals("#123456", built.scrollbar_track_color)
      assert.equals("#234567", built.scrollbar_thumb_color)
      local paint = shared.serialize_row_paint({ scrollbar_track = true }, palette)
      assert.equals("#5a6375", paint.scrollbar_track_color)
      -- Raw thumbs still inherit final native panel border, including explicit chrome.
      assert.is_nil(paint.scrollbar_thumb_color)
    end
  )

  it("keeps panel chrome whole-box precedence in the shared surface adapter", function()
    local palette = shared.palette("overlay")
    local style = { bg = "panel_bg", padding = 8, margin = 9, radius = 6 }
    local chrome = { bg = false, padding = { right = 2 }, margin = false, border = "muted" }
    local before_style, before_chrome =
      hollow.util.clone_value(style), hollow.util.clone_value(chrome)
    local expected = shared.overlay_surface_style(style, chrome, palette)
    ui.overlay.push(ui.overlay.new({
      style = style,
      chrome = chrome,
      render = function()
        return ui.row({})
      end,
    }))
    assert.same(expected, ui._overlay_state()[1].chrome)
    assert.is_nil(expected.bg)
    assert.is_nil(expected.margin)
    assert.same({ top = 0, right = 2, bottom = 0, left = 2 }, expected.padding)
    assert.equals(palette.muted, expected.border)
    assert.equals(6, expected.radius)
    assert.same(before_style, style)
    assert.same(before_chrome, chrome)
  end)

  it("paints explicit tab close spans identically in bars and overlays on hover", function()
    local events = require("hollow.ui.widgets.bars.bar_events")
    local state = require("hollow.state").get()
    local function close()
      return ui.button({
        id = "tab:close",
        text = " ×",
        style = { fg = "muted", padding = { x = 3 }, hover = { fg = "fg", bg = "hover_bg" } },
        on_click = function() end,
      })
    end
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { close() }
      end,
    }))
    local overlay = ui.overlay.new({
      render = function()
        return ui.row({ close() })
      end,
    })
    ui.overlay.push(overlay)
    for _, hovered in ipairs({ false, true, false }) do
      local id = hovered and "tab:close" or nil
      state.ui[events.hovered_key("topbar")] = id
      require("hollow.ui.widgets.bars.bar_cache").invalidate("topbar")
      overlay.on_event("overlay:hover", { id = id })
      local bar = ui._topbar_state().items[1].segments[1]
      local span = ui._overlay_state()[1].rows[1].segments[1]
      for _, key in ipairs({ "text", "id", "fg", "bg", "padding" }) do
        assert.same(bar[key], span[key])
      end
      assert.equals(" ×", span.text)
      assert.equals(hovered and shared.palette("overlay").hover_bg or nil, span.bg)
    end
  end)
end)
