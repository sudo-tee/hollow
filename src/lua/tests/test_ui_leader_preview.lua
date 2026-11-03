package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("leader discovery", function()
  local env, h, key, timers, clock, hits

  local function press(chord)
    return key(h.keymap.parse_chord(chord))
  end

  local function advance(ms)
    clock = clock + ms
    env.recorded.now_ms = clock
    local queued = timers
    timers = {}
    for _, timer in ipairs(queued) do
      if timer.at <= clock then
        timer.fn()
      else
        timers[#timers + 1] = timer
      end
    end
  end

  local function stack()
    return env.state.get().ui.overlay_stack
  end

  local function snapshot()
    h.ui._layout_prepare(800, 600, 8, 19)
    return assert(stack()[1])._layout_snapshot.nodes
  end

  local function text(nodes)
    local out = {}
    for _, node in ipairs(nodes) do
      if node.text then
        out[#out + 1] = node.text
      end
    end
    return table.concat(out, "|")
  end

  before_each(function()
    env = harness.boot()
    h, key = env.hollow, env.get_key_handler()
    clock, timers, hits = env.recorded.now_ms, {}, 0
    env.host_api.defer = function(fn, delay)
      timers[#timers + 1] = { fn = fn, at = clock + (delay or 0) }
    end
    h.keymap.set_leader("<C-Space>")
    h.keymap.set("<leader>x", function()
      hits = hits + 1
    end, { desc = "Execute" })
    h.keymap.set("<leader>uu", "reload_config")
    h.keymap.group("<leader>u", "Configuration")
  end)

  it("reveals after 200 ms without stealing focus or duplicating bar hints", function()
    assert.is_true(press("<C-Space>"))
    assert.equal(5000, h.keymap.get_leader_state().timeout_ms)
    assert.equal(0, #stack())
    assert.is_nil(h.ui._bottombar_state())
    assert.is_nil(h.ui._bottombar_layout())
    advance(199)
    assert.equal(0, #stack())
    advance(1)
    assert.equal(1, #stack())
    local nodes = snapshot()
    local label = text(nodes)
    assert.matches("Configuration", label, 1, true)
    assert.matches("Execute", label, 1, true)
    assert.matches("›", label, 1, true)
    for _, node in ipairs(nodes) do
      assert.is_nil(node.focusable)
    end
    assert.same({}, stack()[1]._layout_surface.focus_order)
    assert.is_false(h.ui.dispatch_overlay_key("x", 0))
    assert.is_nil(h.ui._bottombar_state())
    assert.is_nil(h.ui._bottombar_layout())
    assert.is_true(press("x"))
    assert.equal(1, hits)
    assert.equal(0, #stack())
  end)

  it("never flashes for a fast shortcut or a stale reveal callback", function()
    press("<C-Space>")
    advance(80)
    press("x")
    advance(120)
    assert.equal(1, hits)
    assert.equal(0, #stack())
    press("<C-Space>")
    advance(199)
    assert.equal(0, #stack())
    advance(1)
    assert.equal(1, #stack())
  end)

  it("renders a rounded, theme-aware border around the preview", function()
    h.ui.leader_preview.configure({ theme = { panel_border = "#123456", radius = 10 } })
    press("<C-Space>")
    advance(200)
    local panel = snapshot()[1]
    assert.equal("#123456", panel.border)
    assert.same({ left = 1, right = 1, top = 1, bottom = 1 }, panel.border_width)
    assert.equal(10, panel.radius)
  end)

  it("keeps the initial reveal deadline while typing a group", function()
    press("<C-Space>")
    advance(100)
    press("u")
    advance(99)
    assert.equal(0, #stack())
    advance(1)
    assert.equal(1, #stack())
    local label = text(snapshot())
    assert.matches("Configuration", label, 1, true)
    assert.matches("<leader> u", label, 1, true)
    assert.matches("reload config", label, 1, true)
    assert.matches("Backspace back", label, 1, true)
  end)

  it("updates visible groups immediately and supports backtracking", function()
    press("<C-Space>")
    advance(200)
    local widget = stack()[1]
    advance(3000)
    press("u")
    assert.equal(widget, stack()[1])
    assert.equal(5000, h.keymap.get_leader_state().remaining_ms)
    assert.matches("Configuration", text(snapshot()), 1, true)
    assert.is_nil(h.ui._bottombar_state())
    assert.is_nil(h.ui._bottombar_layout())
    press("<BS>")
    assert.equal(widget, stack()[1])
    assert.same({}, h.keymap.get_leader_state().sequence)
    assert.matches("Execute", text(snapshot()), 1, true)
    press("<BS>")
    assert.is_nil(h.keymap.get_leader_state())
    assert.equal(0, #stack())
  end)

  it("honors explicit Backspace bindings", function()
    h.keymap.set("<leader><BS>", function()
      hits = hits + 1
    end)
    press("<C-Space>")
    press("<BS>")
    assert.equal(1, hits)
  end)

  it("expires at the idle deadline, but not at an old group deadline", function()
    press("<C-Space>")
    advance(200)
    advance(4700)
    press("u")
    advance(100)
    assert.equal(1, #stack())
    assert.is_not_nil(h.keymap.get_leader_state())
    advance(4899)
    assert.equal(1, #stack())
    advance(1)
    assert.equal(0, #stack())
    assert.is_nil(h.keymap.get_leader_state())
  end)

  it("closes even when the expiry timer fires early", function()
    press("<C-Space>")
    advance(200)
    for _, timer in ipairs(timers) do
      timer.at = timer.at - 1
    end
    advance(4799)
    assert.equal(1, #stack())
    advance(1)
    assert.equal(0, #stack())
    assert.is_nil(h.keymap.get_leader_state())
  end)

  it("drops an expired preview before layout when the timer is late", function()
    press("<C-Space>")
    advance(200)
    env.recorded.now_ms = clock + 4800
    h.ui._layout_prepare(800, 600, 8, 19)
    assert.equal(0, #stack())
  end)

  it("leaves ordinary sequences on their independent short timeout", function()
    h.keymap.set_leader("<C-Space>", { timeout_ms = 9000 })
    h.keymap.set("gg", function()
      hits = hits + 1
    end)
    press("g")
    assert.equal(1000, h.keymap.get_leader_state().timeout_ms)
    assert.is_not_nil(h.ui._bottombar_state())
    advance(1000)
    assert.is_nil(h.keymap.get_leader_state())
    assert.equal(0, #stack())
    press("<C-Space>")
    assert.equal(9000, h.keymap.get_leader_state().timeout_ms)
  end)

  it("supports immediate reveal, custom placement and copied theme overrides", function()
    local opts = {
      delay_ms = 0,
      align = "top_left",
      width = 60,
      max_height = 12,
      theme = { title = "#112233" },
    }
    h.ui.leader_preview.configure(opts)
    opts.theme.title = "#ffffff"
    press("<C-Space>")
    assert.equal(1, #stack())
    assert.equal("top_left", stack()[1].align)
    assert.equal(60, stack()[1].width)
    assert.equal(12, stack()[1].max_height)
    assert.equal("#112233", stack()[1]._palette.title)
    assert.is_true(#snapshot() > 0)
  end)

  it("supports bottom-bar and disabled previews without disabling shortcuts", function()
    h.ui.leader_preview.configure({ mode = "bottombar" })
    press("<C-Space>")
    advance(300)
    assert.equal(0, #stack())
    local bar = h.ui._bottombar_state()
    assert.matches("Execute", bar.items[#bar.items].text, 1, true)
    h.ui.leader_preview.configure(false)
    assert.is_nil(h.ui._bottombar_state())
    assert.is_nil(h.ui._bottombar_layout())
    press("x")
    assert.equal(1, hits)
    press("<C-Space>")
    advance(5000)
    assert.is_nil(h.keymap.get_leader_state())
    assert.equal(0, #stack())
  end)

  it("switches leader bar visibility immediately when preview mode changes", function()
    press("<C-Space>")
    assert.is_nil(h.ui._bottombar_state())
    h.ui.leader_preview.configure({ mode = "bottombar" })
    assert.is_not_nil(h.ui._bottombar_state())
    assert.is_not_nil(h.ui._bottombar_layout())
    h.ui.leader_preview.configure({ mode = "overlay" })
    assert.is_nil(h.ui._bottombar_state())
    assert.is_nil(h.ui._bottombar_layout())
    advance(200)
    assert.equal(1, #stack())
    h.ui.leader_preview.configure(false)
    assert.equal(0, #stack())
    assert.is_nil(h.ui._bottombar_state())
    h.ui.leader_preview.configure({ enabled = true, mode = "bottombar" })
    assert.is_not_nil(h.ui._bottombar_state())
    press("x")
    assert.equal(1, hits)
    assert.is_nil(h.ui._bottombar_state())
  end)

  it("keeps copy-mode and quick-select bars in overlay and disabled modes", function()
    for _, opts in ipairs({ { mode = "overlay" }, false }) do
      h.ui.leader_preview.configure(opts)
      h.action.copy_mode()
      local bar = h.ui._bottombar_state()
      assert.matches("COPY", bar.items[1].text, 1, true)
      assert.is_not_nil(h.ui._bottombar_layout())
      h.action.copy_mode_exit()
      h._emit_builtin_event("quick_select:changed", { active = true, action = "open" })
      bar = h.ui._bottombar_state()
      assert.matches("QUICK SELECT", bar.items[1].text, 1, true)
      assert.is_not_nil(h.ui._bottombar_layout())
      h._emit_builtin_event("quick_select:changed", { active = false })
      assert.is_nil(h.ui._bottombar_state())
    end
  end)

  it("validates configuration atomically", function()
    h.ui.leader_preview.configure({ delay_ms = 0 })
    press("<C-Space>")
    local widget = stack()[1]
    for _, invalid in ipairs({
      { delay_ms = -1 },
      { mode = "bad" },
      { width = 0 },
      { enabled = "no" },
      { typo = true },
    }) do
      assert.has_error(function()
        h.ui.leader_preview.configure(invalid)
      end)
      assert.equal(widget, stack()[1])
    end
    assert.equal("overlay", h.ui.leader_preview._mode())
  end)

  it("cancels on Escape, invalid input, blur, mode change, or a new modal", function()
    local cancel = {
      function()
        press("<Esc>")
      end,
      function()
        press("z")
      end,
      function()
        h._emit_builtin_event("window:blurred", {})
      end,
      function()
        h._emit_builtin_event("copy_mode:changed", { active = true })
      end,
      function()
        h.ui.input.open({ prompt = "Input" })
      end,
    }
    for _, fn in ipairs(cancel) do
      press("<C-Space>")
      advance(200)
      local preview = stack()[1]
      fn()
      assert.is_nil(h.keymap.get_leader_state())
      assert.is_true(preview._layout_surface.destroyed)
      h.ui.overlay.clear()
      h._emit_builtin_event("copy_mode:changed", { active = false })
    end
  end)

  it("does not swallow unused leader keys for description-only groups", function()
    h.keymap.del("<leader>x")
    h.keymap.del("<leader>uu")
    assert.is_false(press("<C-Space>"))
    assert.is_nil(h.keymap.get_leader_state())
  end)

  it("preserves group labels when bindings are removed and added again", function()
    h.keymap.del("<leader>uu")
    h.keymap.set("<leader>ur", "reload_config")
    press("<C-Space>")
    advance(200)
    assert.matches("Configuration", text(snapshot()), 1, true)
    press("u")
    assert.equal("Configuration", h.keymap.get_leader_state().desc)
  end)

  it("keeps leader cancellation ahead of notification Escape handlers", function()
    local toast = h.ui.notify.info("Background task", { ttl = 0 })
    press("<C-Space>")
    advance(200)
    assert.equal(2, #stack())
    press("<Esc>")
    assert.is_nil(h.keymap.get_leader_state())
    assert.equal(1, #stack())
    assert.equal(toast, stack()[1])
  end)

  it("bounds large previews under the surface node budget", function()
    for _, mods in ipairs({ 2, 4, 6, 8 }) do
      for index = 97, 122 do
        local chord = h.keymap.format_chord(string.char(index), mods)
        h.keymap.set("<leader>" .. chord, function() end, { desc = "Custom action" })
      end
    end
    press("<C-Space>")
    advance(200)
    local nodes = snapshot()
    assert.is_true(#nodes < 512)
    assert.matches("More bindings", text(nodes), 1, true)
  end)
end)
