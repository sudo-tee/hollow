package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("terminal Find bar", function()
  local env, ui, host, calls, stack
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    host = require("hollow.state").get().host_api
    stack = require("hollow.state").get().ui.overlay_stack
    calls = {}
    host.terminal_find = function(id, session, operation, query)
      calls[#calls + 1] = { id = id, session = session, operation = operation, query = query }
      return true
    end
  end)

  local function key(name, mods)
    assert.is_true(ui.dispatch_overlay_key(name, mods or 0))
  end
  local function text()
    ui._layout_prepare(1000, 700, 8, 19)
    local runs = {}
    for _, node in ipairs(ui._layout_tree or {}) do
      if node.text then
        runs[#runs + 1] = node.text
      end
    end
    return table.concat(runs, "\n")
  end
  local function node(suffix)
    for _, item in ipairs(ui._layout_tree or {}) do
      if item.id and item.id:sub(-#suffix) == suffix then
        return item
      end
    end
  end
  local function emit(query, count, index, complete, override)
    local request = calls[1]
    env.hollow._emit_builtin_event("terminal_find:changed", override or {
      pane_id = request.id,
      session = request.session,
      active = true,
      query = query,
      match_count = count,
      match_index = index,
      complete = complete,
    })
  end

  it("opens through action/default binding without entering copy mode", function()
    env.hollow.action.find()
    assert.equals(1, #stack)
    assert.equals("query", calls[1].operation)
    assert.is_false(require("hollow.copy_mode").is_active())
    local rendered = text()
    assert.is_truthy(rendered:find(require("hollow.ui.icons").search, 1, true))
    assert.is_falsy(rendered:find("Find", 1, true))
    assert.equals(1, node("find:row").align_y)
    local panel = node("dialog")
    assert.equals(panel.padding.top, panel.padding.bottom)
    assert.is_true(ui._layout_frame.height > 2.5)
    assert.equals(ui.find.open(), ui.find.open())
    ui.find.close()
    dofile("conf/init.lua")
    env.hollow.keymap.apply_defaults()
    local leader, mods = env.hollow.keymap.parse_chord("<C-Space>")
    local on_key = env.get_key_handler()
    assert.is_true(on_key(leader, mods))
    assert.is_true(on_key("f", 0))
    assert.equals(1, #stack)
  end)

  it("sends literal queries on edit/paste and keeps Enter navigation open", function()
    ui.find.open({ query = "foo.bar" })
    assert.equals("foo.bar", calls[1].query)
    key("x")
    assert.equals("foo.barx", calls[#calls].query)
    host.clipboard_read = function()
      return " one\r\ntwo"
    end
    key("v", 2)
    assert.equals("foo.barx one two", calls[#calls].query)
    key("enter")
    assert.equals("next", calls[#calls].operation)
    key("enter", 1)
    assert.equals("prev", calls[#calls].operation)
    assert.equals(1, #stack)
    key("escape")
    assert.equals(0, #stack)
    assert.equals("close", calls[#calls].operation)
    ui.find.open()
    assert.equals("foo.barx one two", calls[#calls].query)
  end)

  it("shows progress, ignores stale queries/sessions and closes on native cancellation", function()
    ui.find.open({ query = "foo" })
    emit("foo", 12, 2, false)
    assert.is_truthy(text():find("2/12…", 1, true))
    emit("old query", 999, 999, true)
    assert.is_truthy(text():find("2/12", 1, true))
    emit(
      nil,
      nil,
      nil,
      nil,
      { pane_id = calls[1].id, session = calls[1].session + 1, active = false }
    )
    assert.equals(1, #stack)
    emit("foo", 12, 3, true)
    local rendered = text()
    assert.is_truthy(rendered:find("3/12", 1, true))
    assert.is_falsy(rendered:find("…", 1, true))
    emit(nil, nil, nil, nil, { pane_id = calls[1].id, session = calls[1].session, active = false })
    assert.equals(0, #stack)
  end)

  it("renders one compact row without status or hints for an empty query", function()
    ui.find.open({ query = "" })
    local rendered = text()
    assert.is_truthy(rendered:gsub("\n", ""):find("Search scrollback", 1, true))
    assert.is_falsy(rendered:find("Literal", 1, true))
    assert.is_falsy(rendered:find("Enter", 1, true))
    assert.is_falsy(rendered:find("0/0", 1, true))
    assert.is_falsy(rendered:find("copy mode", 1, true))
    assert.is_truthy(rendered:find("×", 1, true))
  end)

  it("hands the query to copy mode as a literal search on Tab", function()
    local entered, query = false, nil
    host.copy_mode_enter = function()
      entered = true
    end
    host.copy_mode_search_set_query = function(value)
      query = value
    end
    ui.find.open({ query = "foo.bar" })
    key("tab")
    assert.equals(0, #stack)
    assert.equals("close", calls[#calls].operation)
    assert.is_true(entered)
    assert.equals("\\Vfoo.bar", query)
  end)

  it("routes the default leader search binding to Find, not copy-mode search", function()
    dofile("conf/init.lua")
    env.hollow.keymap.apply_defaults()
    local leader, mods = env.hollow.keymap.parse_chord("<C-Space>")
    local on_key = env.get_key_handler()
    local searched = false
    host.copy_mode_open_search = function()
      searched = true
    end
    assert.is_true(on_key(leader, mods))
    assert.is_true(on_key("slash", 0))
    assert.is_false(searched)
    assert.equals(1, #stack)
    assert.is_false(require("hollow.copy_mode").is_active())
  end)

  it("does not replace unfinished exclusive dialogs or search Lua panes", function()
    ui.input.open({ default = "unfinished" })
    assert.is_nil(ui.find.open())
    assert.equals(0, #calls)
    assert.equals(1, #stack)
    key("escape")
    local original = env.hollow.term.current_pane
    env.hollow.term.current_pane = function()
      return { id = 99, kind = "lua" }
    end
    assert.is_nil(ui.find.open())
    assert.equals(0, #calls)
    env.hollow.term.current_pane = original
  end)

  it("ignores an old close event after reopening on the same pane", function()
    ui.find.open({ query = "old" })
    local old = calls[1]
    ui.find.close()
    ui.find.open({ query = "new" })
    assert.is_true(calls[#calls].session > old.session)
    env.hollow._emit_builtin_event("terminal_find:changed", {
      pane_id = old.id,
      session = old.session,
      active = false,
    })
    assert.equals(1, #stack)
    assert.is_truthy(text():find("new", 1, true))
  end)

  it("exposes rejected native requests without sending terminal input", function()
    host.terminal_find = function()
      return false
    end
    ui.find.open({ query = "foo" })
    assert.is_truthy(text():find("Rejected", 1, true))
    key("f1")
    key("escape")
    assert.equals(0, #stack)
  end)
end)
