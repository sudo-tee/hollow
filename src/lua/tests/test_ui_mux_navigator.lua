package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI mux navigator test suite", function()
  local env
  local hollow
  local recorded
  local host_api
  local on_key

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    host_api = env.host_api
    on_key = env.get_key_handler()
  end)

  describe("mux navigator overlay", function()
    local mux_overlay
    local mux_overlay_text = ""
    local mux_theme
    local bell_marker = string.char(226, 151, 143) .. " "
    local saw_yellow_bell = false
    local saw_green_process = false
    local cwd_detail_fg = nil
    local subtle_fg

    it("renders pane labels and markers", function()
      hollow.term.set_pane_foreground_process(101, "zig build")
      host_api.set_pane_bell(101, true)
      hollow.ui.mux_navigator.open({
        filter = "pane_bell",
        title = "Attention",
        max_height = 12,
      })
      mux_overlay = hollow.ui._overlay_state()
      harness.assert_true(mux_overlay ~= nil, "mux navigator should create an overlay")
      mux_theme = hollow.ui.resolve_theme("select")
      for _, row in ipairs(mux_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          mux_overlay_text = mux_overlay_text .. (segment.text or "")
          if segment.text == bell_marker and segment.fg == mux_theme.notify_levels.warn then
            saw_yellow_bell = true
          end
          if segment.text == ": zig build" and segment.fg == mux_theme.notify_levels.success then
            saw_green_process = true
          end
        end
        mux_overlay_text = mux_overlay_text .. "\n"
      end
      harness.assert_true(
        mux_overlay_text:find("zig build", 1, true) ~= nil,
        "mux navigator should show foreground process as pane label"
      )
      harness.assert_true(
        mux_overlay_text:find("Tab 1: shell", 1, true) ~= nil,
        "mux navigator should prefix tab labels with tab index"
      )
      harness.assert_true(
        mux_overlay_text:find("Pane 1: zig build", 1, true) ~= nil,
        "mux navigator should prefix pane labels with pane index"
      )
    end)

    it("shows pane cwd as a right-aligned detail", function()
      for _, row in ipairs(mux_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          if segment.text == "/tmp/project" then
            cwd_detail_fg = segment.fg
          end
        end
      end
      subtle_fg = require("hollow.color").brighten_hex_color(
        require("hollow.theme").current().palette.background,
        0.35,
        require("hollow.theme").current().palette.foreground
      )
      harness.assert_true(
        mux_overlay_text:find("/tmp/project", 1, true) ~= nil,
        "mux navigator should show pane cwd as a right-aligned detail"
      )
      harness.assert_true(cwd_detail_fg ~= nil, "mux navigator should render the pane cwd detail")
      harness.assert_equal(cwd_detail_fg, subtle_fg, "mux navigator should color pane cwd subtly")
    end)

    it("keeps bell markers yellow and processes green", function()
      harness.assert_true(saw_yellow_bell, "mux navigator should keep bell markers yellow")
      harness.assert_true(
        saw_green_process,
        "mux navigator should color foreground processes green"
      )
      harness.assert_true(
        mux_overlay_text:find("Pane bells", 1, true) ~= nil,
        "mux navigator should show active filter"
      )
    end)

    it("cycles filters on f", function()
      harness.assert_true(on_key("f", 0), "mux navigator should cycle filters")
      mux_overlay = hollow.ui._overlay_state()
      local mux_filter_text = ""
      for _, row in ipairs(mux_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          mux_filter_text = mux_filter_text .. (segment.text or "")
        end
      end
      harness.assert_true(
        mux_filter_text:find("All panes", 1, true) ~= nil,
        "mux navigator filter key should select all panes"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("mux navigator search", function()
    it("searches by pane id", function()
      host_api.set_pane_bell(101, true)
      hollow.ui.mux_navigator.open({ max_height = 12 })
      harness.assert_true(on_key("slash", 0), "mux navigator should enter search mode")
      harness.assert_true(on_key("1", 0), "mux navigator should search pane ids")
      harness.assert_true(on_key("0", 0), "mux navigator should continue searching pane ids")
      harness.assert_true(on_key("1", 0), "mux navigator should complete pane id search")
      local mux_id_overlay = hollow.ui._overlay_state()
      local mux_id_text = ""
      for _, row in ipairs(mux_id_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          mux_id_text = mux_id_text .. (segment.text or "")
        end
        mux_id_text = mux_id_text .. "\n"
      end
      harness.assert_true(
        mux_id_text:find("Pane 1: zig build", 1, true) ~= nil,
        "mux navigator should search by pane id"
      )
      hollow.ui.overlay.clear()
    end)
  end)

  describe("mux navigator actions", function()
    it("focuses a pane from a workspace row", function()
      hollow.ui.mux_navigator.open({ filter = "pane_bell", max_height = 12 })
      harness.assert_true(
        on_key("enter", 0),
        "mux navigator should focus a pane from a workspace row"
      )
      harness.assert_equal(
        recorded.focus_pane_by_id,
        101,
        "workspace bell row should focus the matching pane"
      )
      hollow.ui.overlay.clear()
    end)

    it("moves between rows and focuses the selected pane", function()
      hollow.ui.mux_navigator.open({ filter = "pane_bell", max_height = 12 })
      harness.assert_true(on_key("arrow_down", 0), "mux navigator should move to tab row")
      harness.assert_true(on_key("arrow_down", 0), "mux navigator should move to pane row")
      harness.assert_true(on_key("enter", 0), "mux navigator should focus selected pane")
      harness.assert_equal(recorded.focus_pane_by_id, 101, "mux navigator should focus pane by id")
      host_api.set_pane_bell(101, false)
    end)
  end)
end)
