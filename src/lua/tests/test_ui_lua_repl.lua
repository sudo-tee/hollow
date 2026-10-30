package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("Clay Lua REPL", function()
  local env, ui, stack
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    stack = require("hollow.state").get().ui.overlay_stack
  end)
  after_each(function()
    _G.__repl_test_value = nil
  end)

  local function key(name, mods)
    assert.is_true(ui.dispatch_overlay_key(name, mods or 0))
  end
  local function paste(text)
    require("hollow.state").get().host_api.clipboard_read = function()
      return text
    end
    key("v", 2)
  end
  local function text()
    ui._layout_prepare(1000, 700, 8, 19)
    local result = {}
    for _, node in ipairs(ui._layout_tree or {}) do
      if node.text then
        result[#result + 1] = node.text
      end
    end
    return table.concat(result, "\n")
  end
  local function contains(value)
    assert.is_truthy(text():find(value, 1, true), text())
  end
  local function input_text()
    text()
    local runs, inside = {}, false
    for _, node in ipairs(ui._layout_tree) do
      if node.id and node.id:match("repl:input$") then
        inside = true
      end
      if node.id and node.id:match("repl:footer$") then
        break
      end
      if inside and node.text then
        runs[#runs + 1] = node.text
      end
    end
    return table.concat(runs)
  end

  it("opens through the action and caches a Clay surface", function()
    env.hollow.action.lua_repl()
    assert.equals(1, #stack)
    assert.is_true(ui._overlay_state()[1].clay)
    contains("Lua REPL")
    local revision = ui._layout_revision
    text()
    assert.equals(revision, ui._layout_revision)
    assert.equals(ui.lua_repl.open(), ui.lua_repl.open())
    key("escape")
    assert.equals(0, #stack)
  end)

  it("opens through the default leader shortcut", function()
    dofile("conf/init.lua")
    env.hollow.keymap.apply_defaults()
    local on_key = env.get_key_handler()
    local leader, mods = env.hollow.keymap.parse_chord("<C-Space>")
    assert.is_true(on_key(leader, mods))
    assert.is_true(on_key("l", 0))
    assert.equals(1, #stack)
    contains("Lua REPL")
  end)

  it("evaluates expressions, nil returns and live API calls", function()
    ui.lua_repl.open()
    paste("1 + 2")
    key("enter")
    contains("3")
    paste("return nil, 42, nil")
    key("enter")
    contains("nil\t42\tnil")
    paste("hollow.term.current_pane().id")
    key("enter")
    contains("101")
  end)

  it("pastes multiline code without executing until Enter", function()
    ui.lua_repl.open()
    paste("__repl_test_value = 17\r\nprint('pasted', __repl_test_value)")
    assert.is_nil(_G.__repl_test_value)
    local old_print = _G.print
    key("enter")
    assert.equals(17, _G.__repl_test_value)
    assert.equals(old_print, _G.print)
    contains("pasted\t17")
    paste("__repl_test_value + 1")
    key("enter")
    contains("18")
  end)

  it("continues incomplete blocks and supports explicit newlines", function()
    ui.lua_repl.open()
    paste("if true then")
    key("enter")
    paste("print('continued')")
    key("enter", 1)
    paste("end")
    key("enter")
    contains("continued")
    assert.is_falsy(text():find("<eof>", 1, true))
  end)

  it("shows compile/runtime errors and keeps accepting code", function()
    ui.lua_repl.open()
    paste("local =")
    key("enter")
    contains("Lua REPL")
    paste("error('boom')")
    key("enter")
    contains("boom")
    contains("stack traceback")
    paste("6 * 7")
    key("enter")
    contains("42")
  end)

  it("keeps history and draft across closing and restores history edits", function()
    ui.lua_repl.open()
    paste("123")
    key("enter")
    paste("draft")
    key("arrow_up")
    key("arrow_down")
    contains("draft")
    key("escape")
    ui.lua_repl.open()
    contains("draft")
    key("u", 2)
    key("arrow_up")
    key("enter")
    contains("123")
    key("l", 2)
    assert.is_falsy(text():find("123", 1, true))
  end)

  it("saves history and restores it after a restart", function()
    ui.lua_repl.open()
    paste("1 + 1")
    key("enter")
    paste("if true then\n  print('two')\nend")
    key("enter")
    local path, saved
    for name, contents in pairs(env.recorded.files) do
      if name:match("lua_repl_history$") then
        path, saved = name, contents
      end
    end
    assert.equals("1 + 1\nif true then\\n  print('two')\\nend\n", saved)

    env = harness.boot()
    ui = env.hollow.ui
    env.recorded.files[path] = saved
    ui.lua_repl.open()
    key("arrow_up")
    assert.equals("> if true then..   print('two').. end ", input_text())
    key("arrow_up")
    assert.equals("> 1 + 1 ", input_text())
  end)

  it("edits UTF-8 without splitting codepoints and swallows unknown shortcuts", function()
    ui.lua_repl.open()
    paste("'é🙂'")
    key("arrow_left")
    key("backspace")
    key("enter")
    contains("é")
    key("q", 2)
    assert.equals(1, #stack)
  end)

  it("does not replace another modal", function()
    ui.input.open({ prompt = "Keep me" })
    assert.is_nil(ui.lua_repl.open())
    assert.equals(1, #stack)
    ui.input.close()
    assert.is_table(ui.lua_repl.open())
  end)

  it("scrolls bounded transcript without changing input/history", function()
    ui.lua_repl.open()
    paste("for i = 1, 50 do print('line-' .. i) end")
    key("enter")
    contains("line-50")
    assert.is_falsy(text():find("line-1\n", 1, true))
    key("page_up")
    contains("line-40")
    assert.is_falsy(text():find("line-50", 1, true))
    key("page_down")
    contains("line-50")
    paste("kept draft")
    stack[1].on_event("overlay:scroll", { delta = 2 })
    contains("kept draft")
    assert.is_falsy(text():find("line-50", 1, true))
  end)

  it("routes wheel, scrollbar and line keys to the transcript", function()
    ui.lua_repl.open()
    paste("for i = 1, 50 do print('line-' .. i) end")
    key("enter")
    text()
    local scrollbar
    for _, node in ipairs(ui._layout_tree) do
      if node.scrollbar_id and node.scrollbar_id:match("repl:output:scrollbar$") then
        scrollbar = node
      end
    end
    assert.is_table(scrollbar)
    stack[1].on_event("overlay:scroll", { id = "repl:input", delta = 1 })
    contains("3 more below")
    stack[1].on_event("overlay:scroll", { id = "repl:input", delta = -1 })
    contains("PgUp/PgDn scroll")
    key("arrow_up", 1)
    contains("1 more below")
    stack[1].on_event("overlay:scrollbar", { id = scrollbar.scrollbar_id, ratio = 0 })
    contains("line-1")
    assert.is_falsy(text():find("line-50", 1, true))
    key("end", 2)
    contains("line-50")
    assert.is_falsy(text():find("more below", 1, true))
  end)

  it("scrolls and clicks completion candidates", function()
    ui.lua_repl.open()
    paste("hollow.config.")
    key("tab")
    text()
    local candidate
    for _, node in ipairs(ui._layout_tree) do
      if node.id and node.id:match("repl:candidate:1$") then
        candidate = node.id
      end
    end
    stack[1].on_event("overlay:scroll", { id = candidate, delta = -1 })
    contains("2/")
    stack[1].on_event("overlay:click", { id = candidate })
    assert.equals("> hollow.config.get ", input_text())
    assert.is_falsy(text():find("matches", 1, true))
  end)

  it("force-submits incomplete code and does not invoke table tostring", function()
    ui.lua_repl.open()
    paste("if true then")
    key("enter", 2)
    contains("<eof>")
    paste("setmetatable({}, {__tostring = function() error('bad tostring') end})")
    key("enter")
    contains("{}")
    paste("5 + 5")
    key("enter")
    contains("10")
  end)

  it("pretty-prints returned and printed tables with an inspect helper", function()
    ui.lua_repl.open()
    paste("{ enabled = true, nested = { answer = 42 } }")
    key("enter")
    contains("enabled = true")
    contains("answer = 42")
    paste("print({ message = 'hello' })")
    key("enter")
    contains('message = "hello"')
    paste("inspect({ helper = true })")
    key("enter")
    contains("helper = true")
    assert.is_nil(_G.inspect)
  end)

  it("Tab-completes an API function and shows its signature without executing", function()
    ui.lua_repl.open()
    paste("hollow.config.snaps")
    key("tab")
    contains("hollow.config.snapshot")
    contains("hollow.config.snapshot(): HollowConfig")
    key("enter") -- a single match was inserted, so Enter runs it
    contains("<function>")
  end)

  it("cycles multiple matches and accepts separately from execution", function()
    ui.lua_repl.open()
    paste("hollow.config.")
    key("tab")
    contains("matches")
    key("tab", 1)
    contains("hollow.config.snapshot")
    key("tab")
    contains("hollow.config.get")
    key("enter") -- accepts the candidate, does not execute
    contains("hollow.config.get(key: string): any")
    assert.is_falsy(text():find("matches", 1, true))
    key("enter")
    contains("<function>")
  end)

  it("dismisses completion before closing and resets it on editing", function()
    ui.lua_repl.open()
    paste("hollow.term.")
    key("tab")
    contains("matches")
    key("escape")
    assert.equals(1, #stack)
    key("tab")
    key("c")
    assert.is_falsy(text():find("matches", 1, true))
    key("escape")
    assert.equals(0, #stack)
  end)

  it("places completion above input and navigates candidates with arrow keys", function()
    ui.lua_repl.open()
    paste("123")
    key("enter")
    paste("hollow.config.")
    key("tab")
    text()
    local menu, input
    for index, node in ipairs(ui._layout_tree) do
      if node.id and node.id:match("repl:completion$") then
        menu = index
      end
      if node.id and node.id:match("repl:input$") then
        input = index
      end
    end
    assert.is_number(menu)
    assert.is_number(input)
    assert.is_true(menu < input)
    key("arrow_down")
    contains("hollow.config.populate_wsl_domains")
    contains("matches")
    key("arrow_up")
    contains("hollow.config.get")
    key("arrow_up") -- wrap to last candidate
    contains("hollow.config.snapshot")
    contains("matches")
    key("arrow_down")
    key("enter") -- accept, not execute
    contains("hollow.config.get(key: string): any")
    assert.is_falsy(text():find("matches", 1, true))
    key("arrow_up") -- menu closed: history works again
    contains("123")
    key("arrow_down")
    contains("hollow.config.get")
  end)

  it(
    "keeps browsing separate from input and highlights candidates without prompt markers",
    function()
      ui.lua_repl.open()
      paste("hollow.config.")
      local original = input_text()
      key("tab")
      assert.equals(original, input_text())
      key("arrow_down")
      assert.equals(original, input_text())
      local prompt_count, selected = 0, false
      for _, node in ipairs(ui._layout_tree) do
        if node.text == "> " then
          prompt_count = prompt_count + 1
        end
        if node.id and node.id:match("repl:candidate:2$") then
          selected = node.bg ~= nil
        end
      end
      assert.equals(1, prompt_count)
      assert.is_true(selected)
      contains("↑/↓ select · Enter insert · Esc dismiss")
      assert.is_falsy(text():find("Enter run", 1, true))
      key("escape")
      assert.equals(original, input_text())
      contains("Enter run · Tab complete · Esc close")
      key("tab")
      key("enter")
      assert.equals("> hollow.config.get ", input_text())
    end
  )

  it("extends to the shared prefix and labels candidate kinds", function()
    _G.__repl_test_value = { prefix_alpha = 1, prefix_beta = function() end }
    ui.lua_repl.open()
    paste("__repl_test_value.p")
    key("tab")
    assert.equals("> __repl_test_value.prefix_ ", input_text())
    contains("2 matches")
    contains("number")
    contains("fn")
    key("tab")
    key("enter")
    assert.equals("> __repl_test_value.prefix_beta ", input_text())
  end)

  it("sizes empty and completion panels to content while preserving explicit height", function()
    ui.lua_repl.open()
    text()
    assert.equals(80, ui._layout_frame.width)
    assert.is_true(ui._layout_frame.height < 7)
    assert.is_falsy(text():find("Live runtime", 1, true))
    paste("hollow.")
    key("tab")
    text()
    assert.is_true(ui._layout_frame.height < 16)
    key("escape")
    key("escape")
    ui.lua_repl.open({ height = 26 })
    text()
    assert.equals(26, ui._layout_frame.height)
  end)
end)
