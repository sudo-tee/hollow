package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")
local status = require("hollow.program_status")

describe("program status", function()
  it("colors only unread attention and prioritizes errors across tabs", function()
    local blocked = { program_status = { { state = "blocked", attention = true } } }
    local failed = { program_status = { { state = "error", attention = true } } }
    local bell = { has_bell = true }
    assert.is_nil(status.attention_level({ { program_status = { { state = "working" } } } }))
    assert.equals("warn", status.attention_level({ blocked, bell }))
    local workspace = { tabs = { { panes = { blocked, bell } }, { panes = { failed } } } }
    assert.equals("error", status.workspace_attention_level(workspace))
    failed.program_status[1].attention = false
    assert.equals("warn", status.workspace_attention_level(workspace))
    blocked.program_status[1].attention = false
    assert.equals("warn", status.workspace_attention_level(workspace))
    bell.has_bell = false
    assert.is_nil(status.workspace_attention_level(workspace))
  end)

  it("shows no badge without reports", function()
    assert.is_nil(status.badge({ { program_status = {} } }))
  end)

  it("prioritizes errors and blocked work across panes", function()
    assert.equals(
      "󰒃 ",
      status.badge({
        { program_status = { { state = "working", progress = 30 } } },
        { program_status = { { state = "blocked", kind = "permission" } } },
      })
    )
    assert.equals(
      "✗ ",
      status.badge({
        {
          program_status = {
            { state = "blocked", kind = "auth" },
            { state = "error" },
          },
        },
      })
    )
  end)

  it("formats progress without rendering program-provided markup", function()
    assert.equals(
      "⠋ 0% ",
      status.badge({
        {
          program_status = {
            { state = "working", progress = 0, title = "<fake>", message = "<script>" },
          },
        },
      }, 0)
    )
  end)

  it("hides idle and animates working without new reports", function()
    assert.is_nil(status.badge({ { program_status = { { state = "idle" } } } }))
    local panes = { { program_status = { { state = "working" } } } }
    local first, state, deadline = status.badge(panes, 0)
    assert.equals("⠋ ", first)
    assert.equals("working", state)
    assert.equals(100, deadline)
    assert.equals(first, status.badge(panes, 99))
    assert.equals("⠙ ", status.badge(panes, 100))
    assert.equals(first, status.badge(panes, 1000))
    local done, _, expiry = status.badge({ { program_status = { { state = "done" } } } }, 0)
    assert.equals("✓ ", done)
    assert.is_nil(expiry)
  end)

  it("uses distinct blocked kinds and state colors", function()
    local env = harness.boot()
    local palette = env.hollow.theme.current().palette
    assert.equals(palette.bright_blue, status.color("working"))
    assert.equals(palette.bright_green, status.color("done"))
    assert.equals(palette.bright_red, status.color("error"))
    assert.equals(palette.bright_yellow, status.color("blocked"))
    for kind, icon in pairs({ permission = "󰒃", question = "?", auth = "󰌾" }) do
      assert.equals(
        icon .. " ",
        status.badge({ { program_status = { { state = "blocked", kind = kind } } } })
      )
    end
  end)

  it("adapts host status changes and invalidates bars", function()
    local env = harness.boot()
    local hollow = env.hollow
    hollow.ui.topbar.configure({})
    env.host_api.get_pane_program_status = function()
      return { { id = "build", state = "blocked", kind = "permission", app = "demo" } }
    end
    local state = require("hollow.state").get()
    local payload
    hollow.events.once("term:program_status_changed", function(value)
      payload = value
    end)
    state.ui.topbar_cache_dirty = false
    state.ui.bottombar_cache_dirty = false
    hollow._emit_builtin_event("term:program_status_changed", { pane_id = 101 })
    assert.equals(101, payload.pane.id)
    assert.equals("blocked", payload.pane.program_status[1].state)
    assert.equals("permission", hollow.term.current_pane().program_status[1].kind)
    assert.is_true(state.ui.topbar_cache_dirty)
    assert.is_true(state.ui.bottombar_cache_dirty)
  end)
end)
