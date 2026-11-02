package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("ui stylesheets", function()
  local hollow, sheet, shared
  local palette = { fg = "#112233", muted = "#223344", hover_bg = "#334455" }

  before_each(function()
    hollow = harness.boot().hollow
    sheet = require("hollow.ui.style.sheet")
    shared = require("hollow.ui.shared")
  end)

  it("merges layers left to right with partial boxes and false resets", function()
    local base = { fg = "fg", padding = 4, hover = { bg = "hover_bg" } }
    local hover = { bg = "hover_bg", padding = { right = 2 } }
    local merged = sheet.merge(base, false, nil, hover, { padding = { left = 0 } })
    assert.same({ top = 4, right = 2, bottom = 4, left = 0 }, merged.padding)
    assert.same(
      { bg = false, padding = false },
      sheet.merge({ bg = "#111111", padding = 4 }, {
        bg = false,
        padding = false,
      })
    )
    merged.hover.bg = "#ffffff"
    assert.equals("hover_bg", base.hover.bg)
    assert.same({ right = 2 }, hover.padding)
  end)

  it("applies states in fixed order after base, variant and size", function()
    local slots = { root = { radius = 0, padding = 8 } }
    local props = {}
    for i, state in ipairs(sheet.STATE_ORDER) do
      slots.root[state] = { radius = i, padding = { right = i } }
      props[state] = true
    end
    local s = sheet.define("test", slots)
    local all = s(palette, props).root
    assert.equals(#sheet.STATE_ORDER, all.radius)
    assert.same({ top = 8, right = 5, bottom = 8, left = 8 }, all.padding)
    all.radius = 99
    assert.equals(0, slots.root.radius)
    assert.equals(#sheet.STATE_ORDER, s(palette, props).root.radius)
  end)

  it("layers variant and size state rules over base state rules", function()
    local s = sheet.define("button", {
      root = {
        fg = "fg",
        hovered = { bg = "hover_bg" },
        variants = { danger = { fg = "#ff0000", hovered = { bg = "#330000" } } },
        sizes = { sm = { padding = { x = 2 } } },
      },
    })
    local style = s(palette, { variant = "danger", size = "sm", hovered = true }).root
    assert.same({ fg = "#ff0000", bg = "#330000", padding = { left = 2, right = 2 } }, style)
    assert.same({ fg = "#112233" }, s(palette).root)
    assert.has_error(function()
      local _ = s(palette, { variant = "dangr" }).root
    end, "hollow.ui: unknown button variant dangr")
    assert.has_error(function()
      local _ = s(palette).nope
    end, 'hollow.ui: unknown style slot "nope" in button')
  end)

  it("resolves sheet tokens leniently against partial palettes", function()
    local s = sheet.define("t", {
      label = { fg = "fg", bg = "missing", border = "notify_levels.warn" },
      suppressed = { fg = "fg", selected = { fg = false } },
    })
    local partial = { fg = "#abcdef", notify_levels = { warn = "#fedcba" } }
    assert.same({ fg = "#abcdef", border = "#fedcba" }, s(partial).label)
    assert.same({}, s(partial, { selected = true }).suppressed)
    assert.has_error(function()
      s:check(palette)
    end)
    assert.has_error(function()
      local _ = s(nil).label
    end, "hollow.ui: t styles require a palette")
  end)

  it("memoizes view slots and layers hex overrides with ui.style", function()
    local s = sheet.define("t", { label = { fg = "fg", hovered = { fg = "muted" } } })
    local view = s(palette, { hovered = true })
    assert.equals(view.label, view.label)
    assert.equals("#223344", view.label.fg)
    local styled = hollow.ui.style(view.label, { fg = "#ff0000", bold = true })
    assert.same({ fg = "#ff0000", bold = true }, styled)
    assert.equals("#223344", view.label.fg)
  end)

  it("keeps built-in sheets valid against bundled themes", function()
    for _, name in ipairs({ "hollow", "kanagawa-wave", "nord", "rose-pine" }) do
      local theme = hollow.theme.resolve_widget("select", hollow.theme.get(name))
      for _, sheet_name in ipairs({
        "select",
        "button",
        "label",
        "badge",
        "pill",
        "kbd",
        "tab",
        "list_row",
        "panel",
        "palette",
        "mux_navigator",
        "activity",
        "notify",
      }) do
        -- mux_navigator derives `subtle` when the theme omits it.
        local palette = setmetatable({ subtle = theme.subtle or "#808080" }, { __index = theme })
        require("hollow.ui.recipes." .. sheet_name):check(palette)
      end
    end
  end)

  it("keeps the topbar sheet valid against the bar palette", function()
    require("hollow.ui.recipes.topbar"):check(shared.bar_palette())
  end)

  it("keeps sheets for derived palettes valid", function()
    local hex = setmetatable({}, {
      __index = function()
        return "#123456"
      end,
    })
    -- Every token must be a key the derived palette builders provide.
    local workspace_keys = { "fg", "muted", "subtle", "open", "user", "bell", "bell_error" }
    local bottombar_keys = {
      "bg",
      "fg",
      "chip_bg",
      "chip_fg",
      "accent",
      "muted",
      "divider",
      "counter",
      "copy_bg",
      "quick_select_bg",
      "leader_bg",
      "hint_key_bg",
    }
    for name, keys in pairs({ workspace = workspace_keys, bottombar = bottombar_keys }) do
      local palette = {}
      for _, key in ipairs(keys) do
        palette[key] = hex[key]
      end
      require("hollow.ui.recipes." .. name):check(palette)
    end
  end)

  it("matches the legacy select entry paint", function()
    local select_sheet = require("hollow.ui.recipes.select")
    local theme = shared.palette("select")
    local util = require("hollow.util")
    for _, selected in ipairs({ false, true }) do
      for _, hovered in ipairs({ false, true }) do
        local s = select_sheet(theme, { selected = selected, hovered = hovered })
        assert.same({
          fg = util.state_value(selected, hovered, theme.selection_fg, theme.hover_fg, theme.fg),
        }, s.label)
        assert.equals(
          util.state_value(
            selected,
            hovered,
            theme.selected_muted,
            theme.selected_muted,
            theme.detail
          ),
          s.detail_indent.fg
        )
      end
    end
  end)

  it("takes new palette values after a theme switch", function()
    local s = sheet.define("t", { label = { fg = "muted" } })
    local first = s(shared.palette("all")).label
    hollow.config.set({ theme = { ui = { status = { fg = "#010203" } } } })
    local second = s(shared.palette("all")).label
    assert.is_not.equal(first.fg, second.fg)
    assert.equals(shared.palette("all").muted, second.fg)
  end)

  it("layers theme slot overrides over sheet rules and under button styles", function()
    hollow.config.set({
      theme = {
        ui = {
          widgets = {
            all = { styles = { button = { root = { radius = 9 } } } },
            select = {
              styles = {
                select = {
                  label = { fg = "title", bold = true, selected = { bg = "panel_bg" } },
                },
              },
            },
          },
        },
      },
    })
    local select = require("hollow.ui.recipes.select")
    local p = shared.palette("select")
    assert.same({ fg = p.title, bold = true }, select(p).label)
    assert.same(
      { fg = p.selection_fg, bg = p.panel_bg, bold = true },
      select(p, { selected = true }).label
    )
    assert.equals(p.fg, select(shared.palette("overlay")).label.fg)
    assert.equals(9, hollow.ui.button({ variant = "primary", theme = p }).style.radius)
    assert.equals(
      1,
      hollow.ui.button({ variant = "primary", theme = p, style = { radius = 1 } }).style.radius
    )
  end)

  it("does not retain discarded palettes or their theme sections", function()
    local button = require("hollow.ui.recipes.button")
    local refs = setmetatable({}, { __mode = "v" })
    local function resolve_palette(index)
      local section = { root = { radius = 8 } }
      local p = { fg = "#112233", styles = { button = section } }
      refs[index * 2 - 1], refs[index * 2] = p, section
      assert.equals(8, button(p).root.radius)
    end
    for i = 1, 100 do
      resolve_palette(i)
    end
    collectgarbage("collect")
    collectgarbage("collect")
    assert.is_nil(next(refs))
  end)

  it("validates a shared theme section against each palette", function()
    local button = require("hollow.ui.recipes.button")
    local styles = { button = { root = { fg = "custom" } } }
    local first = { custom = "#abcdef", styles = styles }
    assert.equals("#abcdef", button(first).root.fg)
    assert.has_error(function()
      local _ = button({ styles = styles }).root
    end)
  end)

  it("applies command palette overrides under the module's sheet name", function()
    hollow.config.set({
      theme = {
        ui = {
          widgets = {
            select = { styles = { palette = { label = { fg = "title", bold = true } } } },
          },
        },
      },
    })
    local styles = require("hollow.ui.recipes.palette")
    local p = shared.palette("select")
    assert.equals("palette", styles.name)
    assert.same({ fg = p.title, bold = true }, styles(p).label)
    assert.same({ fg = p.selected_fg, bold = true }, styles(p, { selected = true }).label)
  end)

  it("keeps theme base rules below built-in variant and size rules", function()
    local button = require("hollow.ui.recipes.button")
    local p = {
      fg = "#112233",
      primary_fg = "#ffffff",
      primary_bg = "#445566",
      styles = { button = { root = { fg = "fg", padding = 10 } } },
    }
    local style = button(p, { variant = "primary", size = "sm" }).root
    assert.equals(p.primary_fg, style.fg)
    assert.same({ top = 2, right = 6, bottom = 2, left = 6 }, style.padding)
  end)

  it("interleaves theme rules with each base, variant, size and state step", function()
    local function layer(radius)
      return { radius = radius, hovered = { radius = radius + 10 } }
    end
    local spec = layer(1)
    spec.variants = { primary = layer(3) }
    spec.sizes = { sm = layer(5) }
    local s = sheet.define("button", { root = spec })
    local themed = layer(2)
    themed.variants = { primary = layer(4) }
    themed.sizes = { sm = layer(6) }
    local p = { styles = { button = { root = themed } } }

    assert.equals(2, s(p).root.radius)
    assert.equals(12, s(p, { hovered = true }).root.radius)
    assert.equals(4, s(p, { variant = "primary" }).root.radius)
    assert.equals(14, s(p, { variant = "primary", hovered = true }).root.radius)
    themed.sizes.sm = nil
    assert.equals(5, s(p, { variant = "primary", size = "sm" }).root.radius)
    assert.equals(15, s(p, { variant = "primary", size = "sm", hovered = true }).root.radius)
    themed.sizes.sm = layer(6)
    assert.equals(6, s(p, { variant = "primary", size = "sm" }).root.radius)
    assert.equals(16, s(p, { variant = "primary", size = "sm", hovered = true }).root.radius)
  end)

  it("rejects unknown theme style sheets, slots, variants and tokens", function()
    local select, button
    local function themed(styles)
      hollow = harness.boot().hollow
      hollow.config.set({ theme = { ui = { widgets = { select = { styles = styles } } } } })
      select = require("hollow.ui.recipes.select")
      button = require("hollow.ui.recipes.button")
      return require("hollow.ui.shared").palette("select")
    end
    local p = themed({ selct = { label = { fg = "fg" } } })
    assert.has_error(function()
      local _ = select(p).label
    end, 'hollow.ui: unknown theme style sheet "selct"')
    p = themed({ select = { lable = { fg = "fg" } } })
    assert.has_error(function()
      local _ = select(p).label
    end, 'hollow.ui: unknown style slot "lable" in select')
    p = themed({ button = { root = { variants = { primray = { fg = "fg" } } } } })
    assert.has_error(function()
      local _ = button(p).root
    end, "hollow.ui: unknown button variant primray")
    p = themed({ select = { label = { selected = { fg = "mutd" } } } })
    assert.has_error(
      function()
        local _ = select(p).label
      end,
      'hollow.ui: unknown style token "mutd" for styles.select.label.selected.fg (did you mean "muted"?)'
    )
  end)

  it("resolves selection_accent tokens on surface styles", function()
    local surface = shared.normalize_surface_style({ selection_accent = "muted" }, palette)
    assert.equals("#223344", surface.selection_accent)
  end)
end)
