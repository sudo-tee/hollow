package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI bars test suite", function()
  local env
  local hollow
  local recorded
  local state
  local host_api
  local on_key

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    state = env.state
    host_api = env.host_api
    on_key = env.get_key_handler()
  end)

  describe("configured topbar", function()
    local configured_topbar

    it("serializes workspace, separator, and tabs content", function()
      hollow.config.set({ top_bar_mode = "always" })
      hollow.ui.topbar.configure({
        separator = "|",
        cwd = false,
        key_legend = false,
        time = false,
        tabs = {
          fit = "content",
          format = function(tab)
            return "tab:" .. tab.title
          end,
        },
      })
      configured_topbar = hollow.ui._topbar_state()
      harness.assert_true(
        configured_topbar ~= nil,
        "topbar.configure should provide a default topbar widget"
      )
      harness.assert_equal(
        configured_topbar.items[1].kind,
        "segment",
        "configured topbar should serialize workspace content"
      )
      harness.assert_equal(
        configured_topbar.items[2].kind,
        "segment",
        "configured topbar should serialize separators"
      )
      harness.assert_equal(
        configured_topbar.items[3].kind,
        "tabs",
        "configured topbar should serialize tabs content"
      )
    end)
  end)

  describe("tabs max_width", function()
    local topbar_with_max_width

    it("preserves short tab labels under max_width", function()
      hollow.ui.topbar.configure({
        separator = false,
        cwd = false,
        key_legend = false,
        time = false,
        workspace = false,
        tabs = {
          fit = "content",
          max_width = 20,
          format = function(tab)
            return {
              hollow.ui.span("prefix "),
              hollow.ui.span(tab.title),
            }
          end,
        },
      })
      topbar_with_max_width = hollow.ui._topbar_state()
      harness.assert_equal(
        topbar_with_max_width.items[1].kind,
        "tabs",
        "tabs-only topbar should serialize a tabs item"
      )
      harness.assert_equal(
        topbar_with_max_width.items[1].max_width,
        20,
        "tabs max_width should be preserved in serialized topbar state"
      )
      harness.assert_equal(
        topbar_with_max_width.items[1].tabs[1].text,
        "prefix shell",
        "short tab labels should remain unchanged under max_width"
      )
    end)

    it("truncates serialized tab text", function()
      _G.host_api.set_tab_title_by_id(201, "this is a very looooong name that should be shorter")
      topbar_with_max_width = hollow.ui._topbar_state()
      harness.assert_equal(
        topbar_with_max_width.items[1].tabs[1].text,
        "prefix this is a ...",
        "tabs max_width should truncate serialized tab text"
      )
    end)

    it("truncates serialized formatted segments", function()
      harness.assert_true(
        topbar_with_max_width.items[1].tabs[1].segments ~= nil
          and topbar_with_max_width.items[1].tabs[1].segments[1].text == "prefix "
          and topbar_with_max_width.items[1].tabs[1].segments[2].text == "this is a ...",
        "tabs max_width should truncate serialized formatted segments"
      )
    end)
  end)

  describe("topbar mounting", function()
    it("auto-hides when no widgets render", function()
      hollow.ui.topbar.mount(hollow.ui.topbar.new({
        render = function()
          return {}
        end,
      }))
      harness.assert_true(
        hollow.ui._topbar_state() == nil,
        "topbar should auto-hide when no widgets render"
      )
      harness.assert_true(
        hollow.ui._topbar_layout() == nil,
        "topbar layout should auto-hide when no widgets render"
      )
      hollow.ui.topbar.unmount()
    end)

    it("overrides configured defaults when mounted", function()
      hollow.ui.topbar.configure({
        cwd = false,
        key_legend = false,
        time = false,
        tabs = false,
        workspace = {
          style = function()
            local ui_theme = hollow.config.get("resolved_theme").ui
            return {
              bg = ui_theme.top_bar.background,
              fg = ui_theme.widgets.all.title,
            }
          end,
        },
      })
      hollow.config.set({ theme = "hollow" })
      local topbar_before_theme_change = hollow.ui._topbar_state()
      harness.assert_equal(
        topbar_before_theme_change.items[1].style.bg,
        hollow.config.get("resolved_theme").ui.top_bar.background,
        "workspace segment should use the current resolved topbar background"
      )

      hollow.config.set({ theme = "nord" })
      local topbar_after_theme_change = hollow.ui._topbar_state()
      harness.assert_equal(
        topbar_after_theme_change.items[1].style.bg,
        hollow.config.get("resolved_theme").ui.top_bar.background,
        "theme changes should invalidate cached topbar workspace styles"
      )

      hollow.ui.topbar.mount(hollow.ui.topbar.new({
        render = function()
          return {
            hollow.ui.span("mounted"),
          }
        end,
      }))
      local mounted_topbar = hollow.ui._topbar_state()
      harness.assert_equal(
        mounted_topbar.items[1].text,
        "mounted",
        "mounted topbar should override configured defaults"
      )
      hollow.ui.topbar.unmount()
    end)
  end)

  describe("bottombar auto-hide", function()
    it("hides when no special widgets render", function()
      harness.assert_true(
        hollow.ui._bottombar_state() == nil,
        "bottombar should auto-hide when no special widgets render"
      )
      harness.assert_true(
        hollow.ui._bottombar_layout() == nil,
        "bottombar layout should auto-hide when inactive"
      )
    end)
  end)

  describe("leader mode", function()
    it("shows the mode widget and legend, then clears", function()
      hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
      hollow.keymap.set("<leader>x", function() end, { desc = "test leader" })
      local leader_key, leader_mods = hollow.keymap.parse_chord("<C-Space>")
      harness.assert_true(on_key(leader_key, leader_mods), "leader key should activate leader mode")
      local leader_bar = hollow.ui._bottombar_state()
      harness.assert_true(leader_bar ~= nil, "bottombar should show in leader mode")
      harness.assert_true(
        leader_bar.items[1].text:find("LEADER", 1, true) ~= nil,
        "leader mode widget should identify leader mode"
      )
      harness.assert_true(
        #leader_bar.items >= 2,
        "leader mode should render the mode widget and legend region"
      )
      harness.assert_true(
        leader_bar.items[#leader_bar.items].text:find("x", 1, true) ~= nil,
        "leader mode should show the next leader keys"
      )
      harness.assert_true(on_key("z", 0), "unmatched leader continuation should clear leader mode")
      harness.assert_true(
        hollow.ui._bottombar_state() == nil,
        "bottombar should clear immediately after leader mode resets"
      )
    end)
  end)

  describe("copy mode bottombar", function()
    it("shows copy mode status and legend", function()
      local leader_key, leader_mods = hollow.keymap.parse_chord("<C-Space>")
      harness.assert_true(
        on_key(leader_key, leader_mods),
        "leader key should activate leader mode again"
      )

      hollow.action.copy_mode()
      local copy_bar = hollow.ui._bottombar_state()
      harness.assert_true(copy_bar ~= nil, "bottombar should show in copy mode")
      harness.assert_true(
        copy_bar.items[1].text:find("COPY", 1, true) ~= nil,
        "copy mode widget should identify copy mode"
      )
      harness.assert_true(
        copy_bar.items[2].text:find("/search", 1, true) ~= nil,
        "copy mode should show search status"
      )
      harness.assert_true(
        copy_bar.items[#copy_bar.items].text:find("move", 1, true) ~= nil,
        "copy mode should show key legend hints"
      )
    end)

    it("hides after special modes clear", function()
      hollow.action.copy_mode_exit()
      on_key("z", 0)
      harness.assert_true(
        hollow.ui._bottombar_state() == nil,
        "bottombar should hide again after special modes clear"
      )
    end)
  end)

  describe("quick select bottombar", function()
    it("shows quick select mode and key legend", function()
      hollow._emit_builtin_event("quick_select:changed", { active = true, action = "open" })
      local quick_select_bar = hollow.ui._bottombar_state()
      harness.assert_true(quick_select_bar ~= nil, "bottombar should show in quick select mode")
      harness.assert_true(
        quick_select_bar.items[1].text:find("QUICK SELECT", 1, true) ~= nil,
        "quick select widget should identify mode"
      )
      harness.assert_true(
        quick_select_bar.items[2].text:find("open/copy", 1, true) ~= nil,
        "quick select widget should identify mixed action"
      )
      harness.assert_true(
        quick_select_bar.items[#quick_select_bar.items].text:find("choose", 1, true) ~= nil,
        "quick select should show key legend hints"
      )
    end)

    it("hides after quick select exits", function()
      hollow._emit_builtin_event("quick_select:changed", { active = false, action = "open" })
      harness.assert_true(
        hollow.ui._bottombar_state() == nil,
        "bottombar should hide after quick select exits"
      )
    end)
  end)

  describe("quick select action event", function()
    it("exposes the executed action after quick-select exits", function()
      local quick_select_action_event = nil
      local quick_select_was_inactive_during_action = false
      hollow.events.once("quick_select:action_executed", function(payload)
        quick_select_action_event = payload
        quick_select_was_inactive_during_action = state.get().quick_select.active == false
      end)
      hollow._emit_builtin_event("quick_select:action_executed", {
        text = "src/main.zig",
        kind = "filename",
        action = "command",
        pattern_index = nil,
      })
      harness.assert_equal(
        quick_select_action_event.text,
        "src/main.zig",
        "quick-select action event should expose matched text"
      )
      harness.assert_equal(
        quick_select_action_event.kind,
        "filename",
        "quick-select action event should expose match kind"
      )
      harness.assert_equal(
        quick_select_action_event.action,
        "command",
        "quick-select action event should expose executed action"
      )
      harness.assert_true(
        quick_select_was_inactive_during_action,
        "quick-select should exit before action event dispatch"
      )
    end)
  end)
end)
