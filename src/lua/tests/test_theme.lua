package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("theme test suite", function()
  local env
  local hollow
  local theme_api

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    theme_api = require("hollow.theme")
  end)

  describe("theme.create", function()
    local derived_theme

    it("derives a theme from terminal colors", function()
      derived_theme = theme_api.create({
        terminal = {
          foreground = "#eeeeee",
          background = "#111111",
          ansi = {
            "#010101",
            "#020202",
            "#030303",
            "#040404",
            "#050505",
            "#060606",
            "#070707",
            "#080808",
          },
          brights = {
            "#111111",
            "#121212",
            "#131313",
            "#141414",
            "#151515",
            "#161616",
            "#171717",
            "#181818",
          },
        },
      })
    end)

    it("derives background palette entries", function()
      harness.assert_equal(
        derived_theme.palette.background,
        "#111111",
        "theme.create should derive background palette entries"
      )
    end)

    it("exposes named bright ANSI colors", function()
      harness.assert_equal(
        derived_theme.palette.bright_blue,
        "#151515",
        "theme.create should expose named bright ANSI colors"
      )
    end)

    it("derives the scrollbar theme from the palette", function()
      harness.assert_equal(
        derived_theme.ui.scrollbar.thumb,
        "#111111",
        "theme.create should derive scrollbar theme from the palette"
      )
    end)
  end)

  describe("theme.get", function()
    it("loads built-in themes", function()
      local built_in_theme = theme_api.get("kanagawa-wave")
      harness.assert_equal(
        built_in_theme.terminal.background,
        "#1f1f28",
        "theme.get should load built-in themes"
      )
      harness.assert_equal(
        built_in_theme.palette.bright_red,
        "#e82424",
        "theme.get should derive palette names from terminal themes"
      )
    end)

    it("loads themes from runtime package paths", function()
      hollow.config.set({ lib_dir = "src/lua/tests/fixtures/lib" })
      local external_theme = theme_api.get("external")
      harness.assert_equal(
        external_theme.terminal.background,
        "#121212",
        "theme.get should load themes from runtime package paths"
      )
    end)
  end)

  describe("theme.current", function()
    it("reflects the active configured theme", function()
      hollow.config.set({ theme = { ui = { accent = "#abcdef" } } })
      local current_theme = theme_api.current()
      harness.assert_equal(
        current_theme.ui.accent,
        "#abcdef",
        "theme.current should reflect the active configured theme"
      )
    end)
  end)

  describe("theme.resolve_widget", function()
    it("exposes flat widget theme values", function()
      local current_theme = theme_api.current()
      local select_theme = theme_api.resolve_widget("select")
      harness.assert_true(
        type(select_theme) == "table",
        "theme.resolve_widget should expose flat widget theme values"
      )
      harness.assert_equal(
        select_theme.panel_bg,
        current_theme.ui.tab_bar.background,
        "theme.resolve_widget should align overlay panel background with the tab bar background"
      )
    end)
  end)
end)
