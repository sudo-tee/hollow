package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("unified component styling", function()
  local hollow, ui, shared
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    shared = require("hollow.ui.shared")
  end)

  it("has deterministic state priority with final instance overrides", function()
    local layers = {}
    local state = {}
    for i, key in ipairs({ "hovered", "selected", "pressed", "focus_visible", "disabled" }) do
      layers[key] = { radius = i, padding = { right = i } }
      state[key] = true
      local actual = shared.resolve_style_states({ radius = 0, padding = 8 }, layers, state)
      assert.equals(i, actual.radius)
      assert.same({ top = 8, right = i, bottom = 8, left = 8 }, actual.padding)
    end
    local override = { radius = 9, bold = false }
    local actual = shared.resolve_style_states({}, layers, state, override)
    assert.equals(9, actual.radius)
    assert.is_false(actual.bold)
    actual.radius = 99
    assert.equals(9, override.radius)
  end)

  it("preserves legacy row states for partial themes, including missing selected paint", function()
    local list = require("hollow.ui.widgets.list_style")
    local partial = { hover_bg = "#112233" }
    local row = list.row({}, partial, true, true, "#abcdef")
    assert.is_nil(row.fill_bg)
    assert.is_nil(row.accent_bar)
    assert.equals(4, row.fill_radius)
    assert.equals("#112233", list.row({}, partial, false, true).fill_bg)
  end)

  it("supports semantic variants and sizes while preserving raw buttons", function()
    local palette = {
      fg = "#112233",
      primary_fg = "#ffffff",
      primary_bg = "#223344",
      hover_bg = "#334455",
      muted = "#445566",
    }
    local button = ui.button({
      id = "run",
      text = "Run",
      variant = "primary",
      size = "sm",
      theme = palette,
      style = { padding = { right = 0 }, fg = "muted" },
    })
    assert.equals("#445566", button.style.fg)
    assert.equals("#223344", button.style.bg)
    assert.same({ left = 6, right = 0, top = 2, bottom = 2 }, button.style.padding)
    assert.same({}, ui.button().style)
    assert.has_error(function()
      ui.button({ variant = "typo" })
    end, "hollow.ui: unknown button variant typo")
    assert.has_error(function()
      ui.action_button({ size = "large" })
    end, "hollow.ui: unknown button size large")
    assert.has_error(function()
      shared.resolve_component_style("list_row", palette, { variant = "typo" })
    end, "hollow.ui: unknown list_row variant typo")
  end)

  it("does not retain disabled overlay callbacks from a previous enabled render", function()
    local clicks, disabled = 0, false
    local widget = ui.overlay.new({
      render = function()
        return ui.row({
          ui.action_button({
            id = "run",
            text = "Run",
            disabled = disabled,
            on_click = function()
              clicks = clicks + 1
            end,
          }),
        })
      end,
    })
    ui.overlay.push(widget)
    ui._overlay_state()
    widget.on_event("overlay:click", { id = "run" })
    assert.equals(1, clicks)
    disabled = true
    ui._overlay_state()
    widget.on_event("overlay:click", { id = "run" })
    assert.equals(1, clicks)
    local button = ui.button({
      id = "off",
      disabled = true,
      on_click = function() end,
      on_mouse_enter = function() end,
      style = { hover = { bg = "#ffffff" } },
    })
    assert.is_nil(button.style.on_click)
    assert.is_nil(button.style.on_mouse_enter)
    assert.is_nil(button.style.hover)
  end)

  it("clears disabled bar callbacks after an enabled render", function()
    local clicks, disabled = 0, false
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return {
          ui.button({
            id = "off",
            variant = "primary",
            disabled = disabled,
            on_click = function()
              clicks = clicks + 1
            end,
          }),
        }
      end,
    }))
    ui._topbar_state()
    hollow._emit_builtin_event("topbar:click", { id = "off" })
    assert.equals(1, clicks)
    disabled = true
    ui.topbar.invalidate()
    ui._topbar_state()
    hollow._emit_builtin_event("topbar:click", { id = "off" })
    assert.equals(1, clicks)
  end)

  it("uses row recipes without inheriting boxes or identity into text", function()
    local widget = ui.overlay.new({
      render = function()
        return ui.row({ ui.text("inherited"), ui.text("child", { fg = "#abcdef" }) }, {
          id = "choice",
          variant = "selectable",
          selected = true,
          style = { radius = 9, fg = "muted" },
        })
      end,
    })
    ui.overlay.push(widget)
    local row = ui._overlay_state()[1].rows[1]
    local theme = shared.palette("overlay")
    assert.equals(theme.selection_bg, row.fill_bg)
    assert.equals(theme.panel_border, row.accent_bar)
    assert.equals(9, row.fill_radius)
    assert.equals(theme.muted, row.segments[1].fg)
    assert.equals("#abcdef", row.segments[2].fg)
    assert.is_nil(row.segments[1].bg)
    assert.is_nil(row.segments[1].padding)
    assert.is_nil(row.segments[1].radius)
    assert.is_nil(row.segments[1].id)
  end)

  it("rejects unsupported row geometry instead of silently dropping it", function()
    assert.has_error(function()
      shared.resolve_row_style({ style = { padding = 4 } }, shared.palette("all"))
    end, "hollow.ui: unsupported row style field padding")
  end)

  it("resolves row hover once and keeps explicit legacy aliases final", function()
    local widget = ui.overlay.new({
      render = function()
        return ui.row({ ui.text("Choice") }, {
          id = "choice",
          style = { fg = "#111111", bg = "#222222", hover = { fg = "#333333", bg = "#444444" } },
          fill_bg = "#555555",
          fill_radius = 0,
        })
      end,
    })
    ui.overlay.push(widget)
    widget.on_event("overlay:hover", { id = "choice" })
    local row = ui._overlay_state()[1].rows[1]
    assert.equals("#333333", row.segments[1].fg)
    assert.equals("#555555", row.fill_bg)
    assert.equals(0, row.fill_radius)
    widget.on_event("overlay:leave")
    assert.equals("#111111", ui._overlay_state()[1].rows[1].segments[1].fg)
  end)

  it("honors an explicit disabled accent part on selectable rows", function()
    ui.overlay.push(ui.overlay.new({
      render = function()
        return ui.row(
          { ui.text("Choice") },
          { id = "choice", variant = "selectable", selected = true, accent_bar = false }
        )
      end,
    }))
    assert.is_false(ui._overlay_state()[1].rows[1].accent_bar)
  end)

  it("resolves overlay style tokens and keeps explicit chrome fields final", function()
    ui.overlay.push(ui.overlay.new({
      style = { bg = "panel_bg", border = "panel_border", padding = 4, radius = 7 },
      chrome = { bg = "#abcdef", padding = { left = 9 } },
      render = function()
        return ui.row({ ui.text("Panel") })
      end,
    }))
    local chrome = ui._overlay_state()[1].chrome
    assert.equals("#abcdef", chrome.bg)
    assert.equals(shared.palette("overlay").panel_border, chrome.border)
    assert.equals(7, chrome.radius)
    assert.same({ left = 9, right = 0, top = 0, bottom = 0 }, chrome.padding)
  end)

  it("does not mutate shared styles when bars assign automatic ids", function()
    local source = { fg = "muted", hover = { fg = "hover_fg" } }
    local first, second = ui.text("one", source), ui.text("two", source)
    local counter = 0
    require("hollow.ui.widgets.bars.bar_events").register({ first, second }, {}, function()
      counter = counter + 1
      return tostring(counter)
    end)
    assert.equals("1", first.style.id)
    assert.equals("2", second.style.id)
    assert.is_nil(source.id)
    first.style.hover.fg = "#ffffff"
    assert.equals("hover_fg", source.hover.fg)
  end)

  it("refreshes recipe and native hover colors after a theme change", function()
    local before = ui.action_button({}).style.fg
    hollow.config.set({
      theme = { ui = { widgets = { all = { fg = "#123456", hover_bg = "#654321" } } } },
    })
    assert.equals("#123456", ui.action_button({}).style.fg)
    assert.is_not.equal(before, ui.action_button({}).style.fg)
    ui.overlay.push(ui.overlay.new({
      render = function()
        return ui.row({ ui.text("row") }, { id = "row" })
      end,
    }))
    assert.equals("#654321", ui._overlay_state()[1].rows[1].hover_bg)
  end)

  it("derives dialog emphasis after widget overrides and permits a semantic override", function()
    hollow.config.set({
      theme = {
        ui = { widgets = { all = { panel_bg = "#000000" }, select = { selected_bg = "#102030" } } },
      },
    })
    local palette = shared.palette("select")
    local expected = require("hollow.color").brighten_hex_color("#102030", 0.25, "#000000")
    assert.equals(expected, palette.button_emphasis_bg)
    assert.equals(
      expected,
      shared.resolve_component_style(
        "button",
        palette,
        { presentation = "dialog" },
        { selected = true }
      ).bg
    )
    hollow.config.set({
      theme = { ui = { widgets = { all = { button_emphasis_bg = "#abcdef" } } } },
    })
    assert.equals(
      "#abcdef",
      shared.resolve_component_style(
        "button",
        shared.palette("select"),
        { presentation = "dialog" },
        { selected = true }
      ).bg
    )
  end)

  it("resolves tab close-button part tokens through the real bar adapter", function()
    hollow.config.set({ top_bar_mode = "always" })
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return { ui.bar.tabs({ style = { close_fg = "muted", close_hover_bg = "tab_active_bg" } }) }
      end,
    }))
    local style = ui._topbar_state().items[1].style
    assert.equals(shared.bar_palette().muted, style.close_fg)
    assert.equals(shared.bar_palette().tab_active_bg, style.close_hover_bg)
  end)

  it("refreshes open picker paint and chrome while retaining instance overrides", function()
    ui.select.open({ items = { "one" }, theme = { title = "#abcdef" } })
    local function label_color()
      for _, row in ipairs(ui._overlay_state()[1].rows) do
        for _, segment in ipairs(row.segments) do
          if segment.text == "one" then
            return segment.fg
          end
        end
      end
    end
    local before = label_color()
    hollow.config.set({
      theme = {
        ui = {
          widgets = {
            select = {
              selection_fg = "#123456",
              panel_bg = "#234567",
              title = "#345678",
            },
          },
        },
      },
    })
    assert.is_not.equal(before, label_color())
    assert.equals("#123456", label_color())
    assert.equals("#234567", ui._overlay_state()[1].chrome.bg)
    local palette = shared.widget_theme("select", { title = "#abcdef", selected_bg = "#102030" })
    hollow.config.set({ theme = "nord" })
    assert.equals("#abcdef", palette.title)
    assert.equals("#102030", palette.selected_bg)
    assert.equals(
      require("hollow.color").brighten_hex_color(palette.selected_bg, 0.25, palette.panel_bg),
      palette.button_emphasis_bg
    )
  end)

  it("uses a modal's explicit palette for lazy child and chrome tokens", function()
    ui.modal({
      theme = { muted = "#123456", panel_bg = "#234567" },
      chrome = { bg = "panel_bg" },
      render = function()
        return ui.row({ ui.text("lazy", { fg = "muted" }) })
      end,
    })
    local widget = ui._overlay_state()[1]
    assert.equals("#123456", widget.rows[1].segments[1].fg)
    assert.equals("#234567", widget.chrome.bg)
  end)

  it("refreshes notification text and border from the same level token", function()
    ui.notify.show("message", { level = "warn" })
    hollow.config.set({
      theme = { ui = { widgets = { notify = { notify_levels = { warn = "#abcdef" } } } } },
    })
    local widget = ui._overlay_state()[1]
    assert.equals("#abcdef", widget.rows[1].segments[1].fg)
    assert.equals("#abcdef", widget.chrome.border)
  end)

  it("does not retain released live palette or chrome tables", function()
    local function allocate()
      local palette = shared.widget_theme("select")
      return setmetatable({ palette, shared.theme_overlay_chrome(palette) }, { __mode = "v" })
    end
    local weak = allocate()
    collectgarbage("collect")
    collectgarbage("collect")
    assert.is_nil(weak[1])
    assert.is_nil(weak[2])
  end)

  it("honors explicit false backdrops across built-in dialogs", function()
    local openers = {
      function()
        ui.select.open({ items = { "one" }, backdrop = false })
      end,
      function()
        ui.command_palette.open({ entries = {}, backdrop = false })
      end,
      function()
        ui.mux_navigator.open({ backdrop = false })
      end,
      function()
        ui.activity.open({ backdrop = false })
      end,
      function()
        ui.input.open({ prompt = "Input", backdrop = false })
      end,
      function()
        ui.confirm.open({ prompt = "Confirm", backdrop = false })
      end,
    }
    for _, open in ipairs(openers) do
      ui.overlay.clear()
      open()
      assert.is_nil(ui._overlay_state()[1].backdrop)
    end
  end)

  it("removes and restores an open picker's theme backdrop", function()
    ui.select.open({ items = { "one" } })
    assert.is_table(ui._overlay_state()[1].backdrop)
    hollow.config.set({ theme = { ui = { widgets = { select = { backdrop = false } } } } })
    assert.is_nil(ui._overlay_state()[1].backdrop)
    hollow.config.set({
      theme = { ui = { widgets = { select = { backdrop = { color = "#123456", alpha = 81 } } } } },
    })
    assert.same({ color = "#123456", alpha = 81 }, ui._overlay_state()[1].backdrop)
  end)

  it("preserves a disabled input backdrop through theme resolution and refresh", function()
    hollow.config.set({ theme = { ui = { widgets = { input = { backdrop = false } } } } })
    assert.is_nil(hollow.theme.resolve_widget("input").backdrop)
    ui.input.open({ prompt = "Input" })
    assert.is_nil(ui._overlay_state()[1].backdrop)
    hollow.config.set({
      theme = { ui = { widgets = { input = { backdrop = { color = "#234567", alpha = 82 } } } } },
    })
    assert.same({ color = "#234567", alpha = 82 }, ui._overlay_state()[1].backdrop)
  end)

  it("retains an explicit instance backdrop across theme changes", function()
    ui.select.open({ items = { "one" }, backdrop = { color = "#abcdef", alpha = 91 } })
    hollow.config.set({ theme = { ui = { widgets = { select = { backdrop = false } } } } })
    assert.same({ color = "#abcdef", alpha = 91 }, ui._overlay_state()[1].backdrop)
  end)

  it("resolves child tokens against a row's partial palette on both row surfaces", function()
    local function row()
      return ui.row({ ui.text("detail", { fg = "muted" }) }, { theme = { muted = "#123456" } })
    end
    ui.overlay.push(ui.overlay.new({ render = row }))
    assert.equals("#123456", ui._overlay_state()[1].rows[1].segments[1].fg)
    ui.sidebar.mount(ui.sidebar.new({ width = 20, render = row }))
    assert.equals("#123456", ui._sidebar_state().rows[1][1].fg)
  end)

  it("shares finite surface pixel normalization without changing span fractions", function()
    assert.equals(2, shared.normalize_surface_px(2.9, 0))
    assert.equals(0, shared.normalize_surface_px(-1, 0))
    assert.equals(7, shared.normalize_surface_px(math.huge, 7))
    assert.equals(7, shared.normalize_surface_px(0 / 0, 7))
    assert.same(
      { top = 2, bottom = 2, left = 5, right = 5 },
      shared.normalize_surface_box({ 2.9, 5.8 })
    )
    assert.equals(2.9, shared.normalize_segment_padding(2.9).top)
  end)
end)
