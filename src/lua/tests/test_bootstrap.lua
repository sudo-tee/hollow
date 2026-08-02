package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("bootstrap test suite", function()
  local env
  local hollow
  local host_api
  local state
  local actions
  local config
  local events
  local htp
  local keymap
  local term
  local theme_api
  local ui
  local ui_primitives
  local ui_runtime
  local ui_widgets_bars
  local ui_widgets_core
  local ui_widgets_input
  local ui_widgets_notify
  local ui_widgets_overlay
  local ui_widgets_select
  local ui_widgets_workspace
  local util

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    host_api = env.host_api
    state = env.state
    actions = require("hollow.actions")
    config = require("hollow.config")
    events = require("hollow.events")
    htp = require("hollow.htp")
    keymap = require("hollow.keymap")
    term = require("hollow.term")
    theme_api = require("hollow.theme")
    ui = require("hollow.ui")
    ui_primitives = require("hollow.ui.primitives")
    ui_runtime = require("hollow.ui.runtime")
    ui_widgets_bars = require("hollow.ui.widgets.bars")
    ui_widgets_core = require("hollow.ui.widgets.core")
    ui_widgets_input = require("hollow.ui.widgets.input")
    ui_widgets_notify = require("hollow.ui.widgets.notify")
    ui_widgets_overlay = require("hollow.ui.widgets.overlay")
    ui_widgets_select = require("hollow.ui.widgets.select")
    ui_widgets_workspace = require("hollow.ui.widgets.workspace")
    util = require("hollow.util")
  end)

  describe("core bootstrap", function()
    it("initializes the global hollow table", function()
      harness.assert_true(hollow ~= nil, "core should initialize the global hollow table")
    end)

    it("retains the host bridge", function()
      harness.assert_equal(state.get().host_api, host_api, "state should retain the host bridge")
    end)

    it("exposes util helpers", function()
      harness.assert_true(type(util.host_now_ms) == "function", "util helper should be available")
    end)
  end)

  describe("module loading", function()
    it("loads the config module", function()
      harness.assert_true(type(config.setup) == "function", "config module should load")
    end)

    it("loads the term module", function()
      harness.assert_true(type(term.setup) == "function", "term module should load")
    end)

    it("loads the actions module", function()
      harness.assert_true(type(actions.setup) == "function", "actions module should load")
    end)

    it("loads the keymap module", function()
      harness.assert_true(type(keymap.setup) == "function", "keymap module should load")
    end)

    it("loads the events module", function()
      harness.assert_true(type(events.setup) == "function", "events module should load")
    end)

    it("loads the htp module", function()
      harness.assert_true(type(htp.setup) == "function", "htp module should load")
    end)
  end)

  describe("ui module loading", function()
    it("merges ui exports onto hollow.ui", function()
      harness.assert_true(
        type(ui.dispatch_widget_event) == "function",
        "ui exports should be merged onto hollow.ui"
      )
    end)

    it("loads the ui runtime", function()
      harness.assert_true(ui_runtime == true, "ui runtime should be loadable")
    end)

    it("loads ui primitives", function()
      harness.assert_true(ui_primitives == true, "ui primitives should be loadable")
    end)

    it("loads widget core helpers", function()
      harness.assert_true(
        type(ui_widgets_core.mount_widget) == "function",
        "widget core helpers should load"
      )
    end)

    it("merges the bars widget module onto hollow.ui", function()
      harness.assert_true(
        type(hollow.ui._topbar_state) == "function",
        "bars widget module should merge onto hollow.ui"
      )
    end)

    it("loads the overlay widget module", function()
      harness.assert_true(ui_widgets_overlay == true, "overlay widget module should be loadable")
    end)

    it("loads the notify widget module", function()
      harness.assert_true(ui_widgets_notify == true, "notify widget module should be loadable")
    end)

    it("loads the input widget module", function()
      harness.assert_true(ui_widgets_input == true, "input widget module should be loadable")
    end)

    it("loads the select widget module", function()
      harness.assert_true(ui_widgets_select == true, "select widget module should be loadable")
    end)

    it("loads the workspace widget module", function()
      harness.assert_true(
        ui_widgets_workspace == true,
        "workspace widget module should be loadable"
      )
    end)
  end)

  describe("theme module", function()
    it("exposes create", function()
      harness.assert_true(type(theme_api.create) == "function", "theme module should expose create")
    end)

    it("exposes get", function()
      harness.assert_true(type(theme_api.get) == "function", "theme module should expose get")
    end)
  end)

  describe("util helpers", function()
    it("prefers the host clock", function()
      harness.assert_equal(
        util.host_now_ms(host_api),
        1234,
        "host_now_ms should prefer the host clock"
      )
    end)

    it("normalizes path segments", function()
      harness.assert_equal(
        util.join_path("alpha", "beta"),
        "alpha/beta",
        "join_path should normalize path segments"
      )
    end)
  end)
end)
