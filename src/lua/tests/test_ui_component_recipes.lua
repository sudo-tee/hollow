package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("unified component styling", function()
  local hollow, ui, shared
  before_each(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    shared = require("hollow.ui.shared")
  end)

  it("preserves legacy row states for partial themes, including missing selected paint", function()
    local list_row = require("hollow.ui.recipes.list_row")
    local partial = { hover_bg = "#112233" }
    local row = list_row(partial, { variant = "section", selected = true, hovered = true }).paint
    assert.is_nil(row.fill_bg)
    assert.is_nil(row.accent_bar)
    assert.equals(4, row.fill_radius)
    assert.equals("#112233", list_row(partial, { hovered = true }).paint.fill_bg)
  end)

  it("supports semantic variants and sizes while preserving raw buttons", function()
    local palette = {
      fg = "#112233",
      primary_fg = "#ffffff",
      primary_bg = "#223344",
      hover_bg = "#334455",
      muted = "#445566",
    }
    local button = ui.components.button({
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
    assert.has_error(function()
      ui.components.button({ variant = "typo" })
    end, "hollow.ui: unknown button variant typo")
    assert.has_error(function()
      ui.action_button({ size = "large" })
    end, "hollow.ui: unknown button size large")
    assert.has_error(function()
      local _ = require("hollow.ui.recipes.list_row")(palette, { variant = "typo" }).paint
    end, "hollow.ui: unknown list_row variant typo")
  end)

  it("uses scoped quiet button paint and disables interaction", function()
    local palette = {
      fg = "#111111",
      selected_fg = "#eeeeee",
      button_emphasis_bg = "#222222",
      styles = { button = { dialog = { fg = "#abcdef" } } },
    }
    local surface = ui.layout.new({
      theme = palette,
      render = function()
        return ui.components.column({
          ui.components.button({
            appearance = "quiet",
            id = "active",
            text = "Go",
            selected = true,
            on_click = function() end,
          }),
          ui.components.button({
            appearance = "quiet",
            id = "disabled",
            text = "Stop",
            disabled = true,
            on_click = function() end,
          }),
        })
      end,
    })
    local nodes = surface:snapshot()
    assert.equals(5, #nodes)
    assert.equals("#222222", nodes[2].bg)
    assert.equals("#222222", nodes[2].hover_bg)
    assert.equals("#eeeeee", nodes[3].fg)
    assert.equals("#abcdef", nodes[5].fg)
    assert.is_nil(nodes[4].clickable)
    assert.is_nil(nodes[4].hover_bg)
  end)

  it("applies scoped solid button states and forwards layout props", function()
    local palette = {
      fg = "#111111",
      muted = "#222222",
      hover_fg = "#eeeeee",
      hover_bg = "#333333",
      primary_fg = "#ffffff",
      primary_bg = "#444444",
      styles = { button = { root = { radius = 9 } } },
    }
    local surface = ui.layout.new({
      theme = palette,
      render = function()
        return ui.components.column({
          ui.components.button({
            appearance = "solid",
            id = "a",
            text = "Go",
            variant = "primary",
            selected = true,
            width = 80,
            label = "Launch",
            on_click = function() end,
          }),
          ui.components.button({
            appearance = "solid",
            id = "b",
            text = "No",
            disabled = true,
            on_click = function() end,
          }),
          ui.components.button({ id = "c", text = "Legacy", variant = "primary" }),
        })
      end,
    })
    local nodes = surface:snapshot()
    assert.equals(7, #nodes)
    assert.equals(80, nodes[2].width)
    assert.equals("Launch", nodes[2].label)
    assert.equals(9, nodes[2].radius)
    assert.equals("#333333", nodes[2].bg)
    assert.equals("#eeeeee", nodes[3].fg)
    assert.equals("#222222", nodes[5].fg)
    assert.is_nil(nodes[4].clickable)
    assert.is_nil(nodes[4].hover_bg)
    assert.equals("#444444", nodes[6].bg)
    assert.equals(9, nodes[6].radius)
  end)

  it("does not retain disabled overlay callbacks from a previous enabled render", function()
    local clicks, disabled = 0, false
    local widget = ui.overlay.new({
      render = function()
        return ui.components.row({
          ui.components.button({
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
    widget.on_event("overlay:click", { id = clay.find(ui, ":run").id })
    assert.equals(1, clicks)
    disabled = true
    widget._layout_surface:invalidate()
    clay.nodes(ui)
    widget.on_event("overlay:click", { id = widget._layout_surface.namespace .. "run" })
    assert.equals(1, clicks)
    local button = ui.components.button({
      id = "off",
      disabled = true,
      on_click = function() end,
      on_mouse_enter = function() end,
      style = { hover = { bg = "#ffffff" } },
    })
    assert.is_nil(button.on_click)
    assert.is_nil(button.style.hover)
  end)

  it("clears disabled bar callbacks after an enabled render", function()
    local clicks, disabled = 0, false
    ui.topbar.mount(ui.topbar.new({
      render = function()
        return {
          ui.action_button({
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
        return clay.row(
          ui,
          ui.row({ ui.text("inherited", { fg = "muted" }), ui.text("child", { fg = "#abcdef" }) }, {
            id = "choice",
            variant = "selectable",
            selected = true,
            style = { radius = 9, fg = "muted" },
          })
        )
      end,
    })
    ui.overlay.push(widget)
    local row = assert(clay.find(ui, ":choice"))
    local theme = shared.palette("overlay")
    assert.equals(theme.selection_bg, row.bg)
    assert.equals(9, row.radius)
    local inherited = assert(clay.text_node(ui, "inherited"))
    assert.equals(theme.muted, inherited.fg)
    assert.equals("#abcdef", clay.text_node(ui, "child").fg)
    assert.is_nil(inherited.bg)
    assert.is_nil(inherited.padding)
    assert.is_nil(inherited.radius)
    assert.is_nil(inherited.id)
  end)

  it("rejects unsupported row geometry instead of silently dropping it", function()
    assert.has_error(function()
      shared.resolve_row_style({ style = { padding = 4 } }, shared.palette("all"))
    end, "hollow.ui: unsupported row style field padding")
  end)

  it("resolves row hover once and keeps explicit legacy aliases final", function()
    local widget = ui.overlay.new({
      render = function()
        return clay.row(
          ui,
          ui.row({ ui.text("Choice") }, {
            id = "choice",
            style = { fg = "#111111", bg = "#222222", hover = { fg = "#333333", bg = "#444444" } },
            fill_bg = "#555555",
            fill_radius = 0,
          })
        )
      end,
    })
    ui.overlay.push(widget)
    local row = assert(clay.find(ui, ":choice"))
    assert.equals(shared.palette("overlay").fg, clay.text_node(ui, "Choice").fg)
    assert.equals("#555555", row.bg)
    assert.is_nil(row.radius)
    assert.equals(shared.palette("overlay").hover_bg, row.hover_bg)
  end)

  it("honors an explicit disabled accent part on selectable rows", function()
    ui.overlay.push(ui.overlay.new({
      render = function()
        return clay.row(
          ui,
          ui.row(
            { ui.text("Choice") },
            { id = "choice", variant = "selectable", selected = true, accent_bar = false }
          )
        )
      end,
    }))
    for _, node in ipairs(clay.nodes(ui)) do
      assert.not_equals(shared.palette("overlay").panel_border, node.bg)
    end
  end)

  it("resolves overlay style tokens and keeps explicit chrome fields final", function()
    ui.overlay.push(ui.overlay.new({
      style = { bg = "panel_bg", border = "panel_border", padding = 4, radius = 7 },
      chrome = { bg = "#abcdef", padding = { left = 9 } },
      render = function()
        return ui.components.row({ ui.components.text("Panel") })
      end,
    }))
    local chrome = assert(clay.find(ui, ":dialog"))
    assert.equals("#abcdef", chrome.bg)
    assert.equals(shared.palette("overlay").panel_border, chrome.border)
    assert.equals(7, chrome.radius)
    -- Explicit 9px plus the half-cell base inset.
    assert.equals(13, chrome.padding.left)
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
        return clay.row(ui, ui.row({ ui.text("row") }, { id = "row" }))
      end,
    }))
    assert.equals("#654321", clay.find(ui, ":row").hover_bg)
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
    assert.equals(expected, harness.dialog_button_style(palette, "default", true, false).bg)
    hollow.config.set({
      theme = { ui = { widgets = { all = { button_emphasis_bg = "#abcdef" } } } },
    })
    assert.equals(
      "#abcdef",
      harness.dialog_button_style(shared.palette("select"), "default", true, false).bg
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
      for _, segment in ipairs(clay.nodes(ui)) do
        if segment.text == "one" then
          return segment.fg
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
    assert.equals("#234567", clay.find(ui, ":dialog").bg)
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
        return ui.components.row({ ui.components.text("lazy", { fg = "muted" }) })
      end,
    })
    local widget = ui._overlay_state()[1]
    assert.equals("#123456", clay.text_node(ui, "lazy").fg)
    assert.equals("#234567", clay.find(ui, ":dialog").bg)
  end)

  it("refreshes notification text and subdued borders from level colors", function()
    ui.notify.show("message", { level = "warn" })
    hollow.config.set({
      theme = {
        ui = {
          widgets = {
            notify = { panel_bg = "#202020", notify_levels = { warn = "#abcdef" } },
          },
        },
      },
    })
    local widget = ui._overlay_state()[1]
    assert.equals("#abcdef", clay.text_node(ui, "[WARN] message").fg)
    local border
    for _, node in ipairs(clay.nodes(ui)) do
      if node.border then
        border = node.border
      end
    end
    assert.equals("#47505a", border)
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
    ui.sidebar.mount(ui.sidebar.new({ width = 20, render = row }))
    assert.equals("#123456", ui._sidebar_state().rows[1][1].fg)
  end)

  it("shares finite surface pixel normalization without changing span fractions", function()
    local box = require("hollow.ui.style.box")
    assert.equals(2, box.px(2.9, 0, true))
    assert.equals(0, box.px(-1, 0, true))
    assert.equals(7, box.px(math.huge, 7, true))
    assert.equals(7, box.px(0 / 0, 7, true))
    assert.same({ top = 2, bottom = 2, left = 5, right = 5 }, box.normalize({ 2.9, 5.8 }, true))
    assert.equals(2.9, shared.normalize_segment_padding(2.9).top)
  end)
end)
