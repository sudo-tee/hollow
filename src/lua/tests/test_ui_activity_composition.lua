package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("activity composition", function()
  local env
  local hollow
  local theme = {
    title = "#112233",
    muted = "#223344",
    selection_fg = "#334455",
    selected_muted = "#445566",
    stale = "#556677",
  }

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    -- Preserve the legacy inline-segment/column serialization contract.
    hollow.ui.layout.configure({ backend = "legacy" })
    env.recorded.now_ms = 3601234
    local entries = {
      {
        id = 1,
        kind = "notification",
        title = "First",
        message = "Detail",
        level = "info",
        workspace = "main",
        pending = false,
        timestamp_ms = 1234,
        pane_closed = true,
      },
      {
        id = 2,
        kind = "notification",
        title = "Second",
        message = "Detail",
        level = "info",
        workspace = "",
        pending = false,
        timestamp_ms = 1234,
      },
    }
    hollow.activity.list = function()
      return entries
    end
    hollow.activity.running = function()
      return {}
    end
    hollow.activity.summary = function()
      return { count = 0 }
    end
  end)

  local function item(id)
    for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
      if row.id and row.id:match(":" .. id .. "$") then
        return row.segments
      end
    end
    error("missing activity row: " .. id)
  end

  local function text(nodes, value)
    for _, node in ipairs(nodes) do
      if node.text == value then
        return node
      end
    end
    error("missing text: " .. value)
  end

  it("preserves read, selected and stale style precedence", function()
    hollow.ui.activity.open({ theme = theme })
    local first, second = item(1), item(2)
    assert.equals(theme.selection_fg, text(first, "First").fg)
    assert.is_false(text(first, "First").bold)
    assert.equals(theme.selected_muted, text(first, "Detail").fg)
    assert.equals(theme.selection_fg, text(first, "  1h").fg)
    assert.equals(theme.stale, text(first, "pane closed  ").fg)
    assert.equals(theme.muted, text(second, "Second").fg)
    assert.equals(theme.stale, text(second, "  1h").fg)
    env.get_key_handler()("arrow_down", 0)
    assert.equals(theme.muted, text(item(1), "First").fg)
    assert.equals(theme.stale, text(item(1), "  1h").fg)
    assert.equals(theme.selection_fg, text(item(2), "Second").fg)
    assert.equals(theme.selection_fg, text(item(2), "  1h").fg)
  end)

  it("keeps blank workspace and dismiss slots aligned", function()
    local calls = {}
    require("hollow.ui.workspace.source").switcher_state().workspace_color_fn = function(name)
      calls[#calls + 1] = name
      return { fg = "#abcdef", bg = "#123456" }
    end
    hollow.ui.activity.open({ theme = theme })
    local rows = hollow.ui._overlay_state()[1].rows
    local first, second = rows[3].segments, rows[4].segments
    assert.same({ "main" }, calls)
    assert.equals("#abcdef", text(first, "main").fg)
    assert.equals("#123456", text(first, "main").bg)
    assert.same({ left = 8, right = 8, top = 3, bottom = 3 }, text(second, "    ").padding)
    assert.same({ left = 4, right = 4, top = 0, bottom = 0 }, second[#second].padding)
    assert.equals(" ", second[#second].text)
  end)

  it("remeasures workspace columns when activity changes between renders", function()
    hollow.ui.activity.open({ theme = theme })
    local entries = hollow.activity.list()
    entries[1].workspace = "long-workspace"
    env.get_key_handler()("arrow_down", 0)
    assert.is_truthy(text(item(1), "long-workspace"))
    assert.same(
      { left = 8, right = 8, top = 3, bottom = 3 },
      text(item(2), string.rep(" ", 14)).padding
    )

    entries[1].workspace = ""
    env.get_key_handler()("arrow_up", 0)
    for _, id in ipairs({ 1, 2 }) do
      for _, segment in ipairs(item(id)) do
        assert.is_false(segment.padding and segment.padding.left == 8 or false)
      end
    end
  end)

  it("keeps search prompt unbolded when the empty-result branch is shown", function()
    hollow.ui.activity.open({ theme = theme })
    env.get_key_handler()("slash", 0)
    env.get_key_handler()("z", 0)
    local rows = hollow.ui._overlay_state()[1].rows
    assert.equals("/ ", rows[3].segments[1].text)
    assert.equals(theme.title, rows[3].segments[1].fg)
    assert.is_false(rows[3].segments[1].bold)
    assert.equals("No matching activity", rows[5].segments[1].text)
  end)
end)
