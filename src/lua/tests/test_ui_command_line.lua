package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("compact command line", function()
  local env, ui, stack
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
  end)
  after_each(function()
    _G.__cmdline_value = nil
  end)

  local function key(name, mods)
    assert.is_true(ui.dispatch_overlay_key(name, mods or 0))
  end
  local function paste(value)
    require("hollow.state").get().host_api.clipboard_read = function()
      return value
    end
    key("v", 2)
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
  local function contains(value)
    assert.is_truthy(text():find(value, 1, true), text())
  end

  it("opens via action and default shortcut and preserves draft on Escape", function()
    env.hollow.action.command_line()
    assert.equals(1, #stack)
    contains("Action > ")
    assert.equals(ui.command_line.open(), ui.command_line.open())
    paste("split_")
    key("escape")
    assert.equals(0, #stack)
    dofile("conf/init.lua")
    env.hollow.keymap.apply_defaults()
    local on_key = env.get_key_handler()
    local leader, mods = env.hollow.keymap.parse_chord("<C-Space>")
    assert.is_true(on_key(leader, mods))
    assert.is_true(on_key("c", 0)) -- Physical letter key, no Shift required.
    contains("split_")
  end)

  it("invokes actions once with validated arguments and origin, then closes", function()
    local calls, seen = 0
    env.hollow.action.register("counted", {
      arguments = env.hollow.shape.strict_object({ count = env.hollow.shape.integer():default(2) }),
      run = function(args)
        calls, seen = calls + 1, env.hollow.action.context()
        assert.equals(3, args.count)
      end,
    })
    ui.command_line.open()
    paste('counted {"count":3}')
    key("enter")
    assert.equals(1, calls)
    assert.equals("command_line", seen.origin)
    assert.equals(0, #stack)
  end)

  it("keeps invalid JSON, schema failures, unknown actions and thrown errors editable", function()
    local calls = 0
    env.hollow.action.register("checked", {
      arguments = env.hollow.shape.strict_object({ count = env.hollow.shape.integer() }),
      run = function()
        calls = calls + 1
      end,
    })
    for _, source in ipairs({
      "checked {",
      'checked {"count":"bad"}',
      "unknown_command",
      "checked []",
    }) do
      ui.command_line.open({ text = source })
      key("enter")
      assert.equals(1, #stack)
      contains(source)
      assert.is_falsy(stack[1]._notify)
      key("escape")
    end
    assert.equals(0, calls)
    env.hollow.action.register("bad", {
      run = function()
        error("kaboom")
      end,
    })
    ui.command_line.open({ text = "bad" })
    key("enter")
    contains("kaboom")
    key("u", 2)
    paste("split_vertical")
    key("enter")
    assert.equals(0, #stack)
  end)

  it("closes before invoking an action that opens another modal", function()
    env.hollow.action.register("dialog", {
      run = function()
        ui.input.open({ prompt = "New dialog" })
      end,
    })
    ui.command_line.open({ text = "dialog" })
    key("enter")
    assert.equals(1, #stack)
    contains("New dialog")
    assert.is_falsy(text():find("Action >", 1, true))
  end)

  it("runs explicit Lua in the live runtime and closes statements without output", function()
    ui.command_line.open({ text = "=__cmdline_value = 42" })
    contains("Lua > ")
    assert.is_nil(_G.__cmdline_value)
    key("enter")
    assert.equals(42, _G.__cmdline_value)
    assert.equals(0, #stack)
  end)

  it("shows returned values and prints in a dismissible result notification", function()
    ui.command_line.open({ text = "=print('hello'); return { answer = 42 }" })
    key("enter")
    assert.equals(1, #stack)
    assert.is_true(stack[1]._notify)
    contains("Lua result")
    contains("hello")
    contains("answer = 42")
    key("escape")
    assert.equals(0, #stack)
  end)

  it("bounds large result previews", function()
    ui.command_line.open({ text = "=for i = 1, 10000 do print('line-' .. i) end" })
    key("enter")
    contains("line-1")
    contains("line-6")
    contains("truncated")
    assert.is_falsy(text():find("line-7", 1, true))
  end)

  it("keeps Lua compile and runtime errors editable and out of successful history", function()
    for _, source in ipairs({ "=if true then", "=error('Lua boom')" }) do
      ui.command_line.open({ text = source })
      key("enter")
      assert.equals(1, #stack)
      contains(source)
      assert.is_falsy(stack[1]._notify)
      key("escape")
    end
    ui.command_line.open({ text = "" })
    key("arrow_up")
    assert.is_falsy(text():find("Lua boom", 1, true))
  end)

  it("shares Lua completion/signatures, filters edits, and accepts without executing", function()
    ui.command_line.open({ text = "=hollow.term." })
    key("tab")
    contains("matches")
    key("c")
    contains("matches")
    key("arrow_down")
    key("enter")
    assert.equals(1, #stack)
    assert.is_falsy(text():find("matches", 1, true))
    contains("=hollow.term.c")
    key("escape")
    ui.command_line.open({ text = "=hollow.config.snaps" })
    key("tab")
    contains("=hollow.config.snapshot")
    contains("hollow.config.snapshot(): HollowConfig")
  end)

  it("completes action names and schema field names without running parsers", function()
    local parses = 0
    env.hollow.action.register("custom_fields", {
      arguments = env.hollow.shape.strict_object({
        count = env.hollow.shape.integer():transform(function(value)
          parses = parses + 1
          return value
        end),
        caption = env.hollow.shape.string(),
      }),
      run = function() end,
    })
    ui.command_line.open({ text = "custom_f" })
    key("tab")
    contains("custom_fields")
    key("u", 2)
    paste('custom_fields {"co')
    key("tab")
    contains('custom_fields {"count": ')
    assert.equals(0, parses)
  end)

  it("promotes a Lua draft to REPL without executing, including existing REPL", function()
    ui.lua_repl.open({ text = "old draft" })
    ui.command_line.open({ text = "=__cmdline_value = 9" })
    key("r", 2)
    assert.equals(1, #stack)
    contains("Lua REPL")
    contains("__cmdline_value = 9")
    assert.is_nil(_G.__cmdline_value)
    key("enter")
    assert.equals(9, _G.__cmdline_value)
  end)

  it("keeps history separate from REPL and filters arrow history by draft prefix", function()
    ui.command_line.open({ text = "split_vertical" })
    key("enter")
    ui.command_line.open({ text = "split_horizontal" })
    key("enter")
    ui.command_line.open({ text = "split_v" })
    key("arrow_up")
    contains("split_vertical")
    key("arrow_down")
    contains("split_v")
    assert.is_falsy(text():find("split_vertical", 1, true))
    key("escape")
    ui.lua_repl.open()
    key("arrow_up")
    assert.is_falsy(text():find("split_vertical", 1, true))
  end)

  it("persists action and multiline Lua history separately across restarts", function()
    ui.lua_repl.open({ text = "123" })
    key("enter")
    key("escape")
    ui.command_line.open({ text = "split_vertical" })
    key("enter")
    local source = '=local path = "C:\\\\temp"\nreturn path'
    ui.command_line.open({ text = source })
    key("enter")
    key("escape") -- Result notification.
    local saved, repl_path, command_path = {}, nil, nil
    for path, contents in pairs(env.recorded.files) do
      saved[path] = contents
      if path:match("command_line_history$") then
        command_path = path
      end
      if path:match("lua_repl_history$") then
        repl_path = path
      end
    end
    assert.is_string(command_path)
    assert.is_string(repl_path)
    assert.equals("123\n", saved[repl_path])
    assert.is_truthy(saved[command_path]:find("split_vertical\n", 1, true))

    env = harness.boot()
    ui = env.hollow.ui
    for path, contents in pairs(saved) do
      env.recorded.files[path] = contents
    end
    ui.command_line.open()
    key("arrow_up")
    contains('local path = "C:\\\\temp"')
    contains("return path")
    key("arrow_up")
    contains("split_vertical")
    key("escape")
    ui.lua_repl.open()
    key("arrow_up")
    contains("123")
    assert.is_falsy(text():find("split_vertical", 1, true))
  end)

  it("tolerates unavailable history storage", function()
    local host = require("hollow.state").get().host_api
    host.path_exists = function()
      error("read unavailable")
    end
    host.write_file = function()
      error("write unavailable")
    end
    ui.command_line.open({ text = "split_vertical" })
    key("enter")
    assert.equals(0, #stack)
    ui.command_line.open()
    key("arrow_up")
    contains("split_vertical")
  end)

  it("does not replace an unfinished modal", function()
    ui.input.open({ prompt = "Keep me" })
    assert.is_nil(ui.command_line.open({ text = "ignored" }))
    contains("Keep me")
  end)
end)
