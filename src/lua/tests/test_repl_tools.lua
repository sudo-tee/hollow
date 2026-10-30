package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local tools = require("hollow.ui.repl_tools")

describe("REPL introspection", function()
  it("prints nested tables, quoted keys, stable scalar ordering and empty tables", function()
    assert.equals(
      '{\n  a = 1,\n  b = {\n    ["odd key"] = "text",\n  },\n}',
      tools.inspect({ b = { ["odd key"] = "text" }, a = 1 })
    )
    assert.equals("{}", tools.inspect({}))
    assert.equals("nil", tools.format(nil))
    assert.equals("hello", tools.format("hello"))
    assert.equals('"hello"', tools.inspect("hello"))
  end)

  it("detects cycles/shared references and bounds depth, entries and strings", function()
    local t = {}
    t.self = t
    assert.matches("<cycle #1>", tools.inspect(t), 1, true)
    local shared = {}
    assert.matches("<ref #2>", tools.inspect({ a = shared, b = shared }), 1, true)
    assert.matches("<max depth>", tools.inspect({ { { { { 1 } } } } }), 1, true)
    local big = {}
    for i = 1, 1000 do
      big[i] = string.rep("x", 10000)
    end
    local result = tools.inspect(big)
    assert.is_true(#result <= 8192)
    assert.matches("<output limit>", result, 1, true)
    local many = {}
    for i = 1, 100 do
      many[i] = i
    end
    assert.matches("<item limit>", tools.inspect(many), 1, true)
  end)

  it("does not invoke metamethods while printing or completing", function()
    local calls = 0
    local function unexpected()
      calls = calls + 1
      error("must not run")
    end
    local object = setmetatable(
      { visible = 1 },
      { __index = unexpected, __pairs = unexpected, __tostring = unexpected }
    )
    assert.matches("visible = 1", tools.inspect(object), 1, true)
    local result = tools.complete("obj.", 4, { obj = object })
    assert.same({ "visible" }, result.items)
    assert.is_nil(tools.complete("obj.missing.", 12, { obj = object }))
    assert.equals(0, calls)
  end)

  it("follows table prototypes without loops and sorts unique matches", function()
    local prototype = { zebra = true, alpha = function() end }
    local object = setmetatable({ alpha = 1, apple = 2 }, { __index = prototype })
    setmetatable(prototype, { __index = object })
    local result = tools.complete("obj.a", 5, { obj = object })
    assert.same({ "alpha", "apple" }, result.items)
    assert.equals("a", result.common)
    assert.equals(5, result.start)
    assert.equals(5, result.stop)
    assert.same({ alpha = "number", apple = "number" }, result.kinds)
  end)

  it("sinks private names unless the query asks for them", function()
    local env = { obj = { _hidden = 1, beta = 2, alpha = function() end } }
    local result = tools.complete("obj.", 4, env)
    assert.same({ "alpha", "beta", "_hidden" }, result.items)
    assert.equals("function", result.kinds.alpha)
    assert.same({ "_hidden" }, tools.complete("obj._", 5, env).items)
  end)

  it("never evaluates calls/index expressions and rejects strings/comments", function()
    local env = {
      obj = { field = 1 },
      factory = function()
        error("called")
      end,
    }
    for _, source in ipairs({
      "'obj.",
      '"obj.',
      "-- obj.",
      "--[[ obj.",
      "[=[obj.",
      "factory().",
      "factory().obj.",
      "obj['field'].",
      "obj[1].",
    }) do
      assert.is_nil(tools.complete(source, #source, env), source)
    end
    assert.is_table(tools.complete("-- ignored\nobj.", 15, env))
    assert.is_table(tools.complete("[=[ignored]=];obj.", 18, env))
  end)

  it("preserves suffix text and handles global and colon completion", function()
    local env = { hollow = { term = { current_pane = function() end } } }
    local source = "print(hollow.term.curXXX, 3)"
    local result = tools.complete(source, 21, env)
    assert.same({ "current_pane" }, result.items)
    assert.equals("hollow.term.", result.path)
    assert.equals("print(hollow.term.", source:sub(1, result.start - 1))
    assert.equals(", 3)", source:sub(result.stop + 1))
    assert.same({ "hollow" }, tools.complete("hol", 3, env).items)
    assert.same({ "current_pane" }, tools.complete("hollow.term:cur", 15, env).items)
  end)

  it("shows typed signatures for nested calls, aliases and incomplete string arguments", function()
    local fn = function()
      error("must not execute")
    end
    local env = { hollow = { term = { send_text = fn } }, alias = fn }
    local hint = tools.hint("hollow.term.send_text(", 22, env)
    assert.matches("text: string", hint, 1, true)
    assert.matches("pane_id", hint, 1, true)
    assert.matches("alias(", tools.hint("alias", 5, env), 1, true)
    local source = "hollow.term.send_text('hello"
    assert.matches("text: string", tools.hint(source, #source, env), 1, true)
    source = "hollow.term.send_text(tostring(1), "
    assert.matches("pane_id", tools.hint(source, #source, env), 1, true)
    assert.is_nil(tools.hint("'hollow.term.send_text", 21, env))
  end)
end)
