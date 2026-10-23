package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("typed action invocation", function()
  local env, hollow, shape, calls, seen

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    shape = hollow.shape
    calls = 0
    hollow.action.register("typed", {
      arguments = shape.strict_object({
        text = shape.string(),
        count = shape.integer():default(2),
        enabled = shape.boolean():default(false),
      }),
      run = function(args)
        calls = calls + 1
        seen = hollow.action.context()
        return { text = args.text, count = args.count, enabled = args.enabled }
      end,
    })
  end)

  it("validates arguments, applies defaults, and returns structured values", function()
    local args = { text = "hello" }
    local result = hollow.action.invoke("typed", args, {
      origin = "api",
      caller = { pane_id = 999 },
    })
    assert.same(
      { success = true, status = "ok", value = { text = "hello", count = 2, enabled = false } },
      result
    )
    assert.is_nil(args.count)
    assert.equal("api", seen.origin)
    assert.equal(999, seen.caller.pane_id)
    assert.equal(101, seen.pane.id) -- Caller metadata must not retarget focus.
    assert.equal(1, seen.args.n)
    assert.is_nil(hollow.action.context())
  end)

  it("rejects missing, unknown, malformed and non-finite arguments before overrides", function()
    local overrides = 0
    hollow.action.override("typed", function()
      overrides = overrides + 1
    end)
    for _, args in ipairs({
      {},
      { text = "x", extra = true },
      { text = false },
      { text = "x", count = 1.5 },
      { text = "x", count = math.huge },
      { text = "x", count = 0 / 0 },
      { text = "x", enabled = 1 },
      false,
    }) do
      assert.equal("invalid_arguments", hollow.action.invoke("typed", args).status)
    end
    assert.equal(0, calls)
    assert.equal(0, overrides)
    assert.has_error(function()
      hollow.action.typed(false)
    end)
    assert.has_error(function()
      hollow.action.typed({ text = "x" }, "extra")
    end)
    assert.equal("hello", hollow.action.typed({ text = "hello" }).text)
    assert.equal("lua", seen.origin)
  end)

  it("preserves legacy positional arguments, nils, and multiple returns", function()
    hollow.action.register("legacy", {
      run = function(...)
        return ...
      end,
    })
    local a, b, c = hollow.action.legacy("first", nil, "last")
    assert.equal("first", a)
    assert.is_nil(b)
    assert.equal("last", c)
    assert.equal("ok", hollow.action.invoke("legacy").status)
  end)

  it("restores outer context after nested calls and failures", function()
    hollow.action.register("broken", {
      run = function()
        assert.equal("lua", hollow.action.context().origin)
        error("boom")
      end,
    })
    hollow.action.register("outer", {
      run = function()
        local ctx = hollow.action.context()
        assert.has_error(hollow.action.broken)
        assert.same(ctx, hollow.action.context())
        local result = hollow.action.invoke("broken")
        assert.equal("action_failed", result.status)
        assert.matches("boom", result.error)
        assert.same(ctx, hollow.action.context())
      end,
    })
    assert.is_true(hollow.action.invoke("outer", nil, { origin = "key" }).success)
    assert.is_nil(hollow.action.context())
  end)

  it("gives overrides validated arguments and isolated invocation context", function()
    local metadata = { origin = "api", caller = { pane_id = 999 } }
    hollow.action.override("typed", function(ctx)
      assert.equal("api", ctx.origin)
      assert.equal(999, ctx.caller.pane_id)
      assert.equal(2, ctx.args[1].count)
      local snapshot = hollow.action.context()
      snapshot.caller.pane_id = 1
      snapshot.args[1].text = "changed"
      assert.equal(999, hollow.action.context().caller.pane_id)
      assert.equal("original", hollow.action.context().args[1].text)
      return true
    end)
    assert.is_true(hollow.action.invoke("typed", { text = "original" }, metadata).success)
    assert.equal(999, metadata.caller.pane_id)
    assert.equal(0, calls)
  end)

  it("passes key arguments and origin through simple, sequence, and leader bindings", function()
    hollow.keymap.set("<C-y>", "typed", { args = { text = "simple" } })
    hollow.keymap.set("yz", { action = "typed", args = { text = "sequence" } })
    hollow.keymap.set_leader("<C-b>")
    hollow.keymap.set("<leader>y", "typed", { args = { text = "leader" } })
    local key = env.get_key_handler()
    key("y", 2)
    assert.equal("simple", seen.args[1].text)
    assert.equal("key", seen.origin)
    key("y", 0)
    key("z", 0)
    assert.equal("sequence", seen.args[1].text)
    key("b", 2)
    key("y", 0)
    assert.equal("leader", seen.args[1].text)
    assert.equal(3, calls)
  end)

  it("uses palette origin and defaults", function()
    hollow.action.register("palette_typed", {
      arguments = shape.strict_object({ text = shape.string():default("palette") }),
      run = function()
        seen = hollow.action.context()
      end,
    })
    hollow.ui.command_palette.open({ query = "palette_typed" })
    env.get_key_handler()("arrow_down", 0)
    env.get_key_handler()("enter", 0)
    assert.equal("palette", seen.origin)
    assert.equal("palette", seen.args[1].text)
  end)

  it("preserves schema identity and methods in registration and discovery", function()
    local contract = shape.strict_object({ count = shape.integer():default(3) })
    hollow.action.register("isolated", {
      arguments = contract,
      run = function(args)
        return args.count
      end,
    })
    local discovered
    for _, entry in ipairs(hollow.action.list()) do
      if entry.name == "isolated" then
        discovered = entry.arguments
      end
    end
    assert.equal(contract, discovered)
    assert.is_true(discovered:safe_parse({}).success)
    assert.equal(3, discovered:parse({}).count)
    assert.equal(3, hollow.action.invoke("isolated").value)
  end)

  it("parses nested schemas, constraints and transforms once per invocation", function()
    local transforms = 0
    hollow.action.register("nested", {
      arguments = shape
        .strict_object({
          target = shape.strict_object({
            kind = shape.enum({ "pane", "tab" }),
            ids = shape.integer():min(1):array(),
          }),
          amount = shape.string():convert(tonumber):min(1),
        })
        :transform(function(args)
          transforms = transforms + 1
          args.amount = args.amount + 1
          return args
        end),
      run = function(args)
        return args
      end,
    })
    local input = { target = { kind = "pane", ids = { 101, 102 } }, amount = "2" }
    assert.equal(3, hollow.action.invoke("nested", input).value.amount)
    assert.equal(1, transforms)
    assert.equal(3, hollow.action.nested(input).amount)
    assert.equal(2, transforms)
    assert.equal("2", input.amount)
    local invalid = hollow.action.invoke("nested", {
      target = { kind = "pane", ids = { 0 } },
      amount = "2",
    })
    assert.equal("invalid_arguments", invalid.status)
    assert.matches("%$%.target%.ids%[1%]", invalid.error)
    assert.equal(2, transforms)
  end)

  it("isolates caller input from schema transforms and callback mutations", function()
    hollow.action.register("mutating", {
      arguments = shape.strict_object({ nested = shape.table() }):transform(function(args)
        args.nested.changed = true
        return args
      end),
      run = function(args)
        args.nested.callback = true
      end,
    })
    local input = { nested = {} }
    assert.is_true(hollow.action.invoke("mutating", input).success)
    assert.same({ nested = {} }, input)
  end)

  it("rejects invalid registration without replacing an existing action", function()
    for _, contract in ipairs({
      true,
      "string",
      {},
      { text = "string" },
      { parse = function() end },
    }) do
      assert.has_error(function()
        hollow.action.register("typed", { arguments = contract, run = function() end })
      end)
    end
    assert.has_error(function()
      hollow.action.register("typed", {})
    end)
    assert.equal("ok", hollow.action.invoke("typed", { text = "still valid" }).status)
    for _, name in ipairs({ "invoke", "context" }) do
      assert.has_error(function()
        hollow.action.register(name, { run = function() end })
      end)
    end
    assert.equal("unknown_action", hollow.action.invoke("missing").status)
    assert.equal("invalid_context", hollow.action.invoke("typed", {}, { origin = false }).status)
  end)
end)
