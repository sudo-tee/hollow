package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI composition helpers", function()
  local hollow
  local ui
  local shared

  setup(function()
    hollow = harness.boot().hollow
    ui = hollow.ui
    shared = require("hollow.ui.shared")
  end)

  it("selects when branches lazily and returns false for empty results", function()
    local then_calls, else_calls = 0, 0
    local yes = ui.when(true, function()
      then_calls = then_calls + 1
      return "yes"
    end, function()
      else_calls = else_calls + 1
      return "no"
    end)
    assert.equals("yes", yes)
    assert.equals(1, then_calls)
    assert.equals(0, else_calls)

    local no = ui.when(false, function()
      then_calls = then_calls + 1
      return "yes"
    end, function()
      else_calls = else_calls + 1
      return "no"
    end)
    assert.equals("no", no)
    assert.equals(1, then_calls)
    assert.equals(1, else_calls)

    assert.is_false(ui.when(false, "yes"))
    assert.is_false(ui.when(false, "yes", function()
      return nil
    end))
    assert.is_false(ui.when(false, "yes", function()
      return false
    end))

    -- Preserve documented cond-and-or behavior: falsy then branch falls through.
    assert.equals("fallback", ui.when(true, false, "fallback"))
  end)

  it("maps lists with 1-based indexes and drops falsy callback results in groups", function()
    local indexes = {}
    local result = ui.each({ "a", "b", "c" }, function(item, index)
      indexes[#indexes + 1] = index
      if item == "b" then
        return false
      elseif item == "c" then
        return nil
      end
      return item
    end)
    assert.same({ 1, 2, 3 }, indexes)
    assert.equals("a", shared.nodes_plain_text(ui.group(result).children))
    assert.same(
      {},
      ui.each(nil, function()
        error("callback must not run for nil list")
      end)
    )

    local wrapped = hollow.tbl({ "x", "y" })
    assert.same(
      { "x1", "y2" },
      ui.each(wrapped, function(item, index)
        return item .. index
      end)
    )
  end)

  it("joins surviving items without edge separators", function()
    assert.same({}, ui.join({}, ","))
    assert.same({ "only" }, ui.join({ "only" }, ","))
    assert.same({ "a", ",", "b" }, ui.join({ "a", "b" }, ","))
    assert.same({ "a", ",", "b" }, ui.join({ false, "a", nil, "b", false }, ","))
  end)

  it("supports node and indexed function separators only between surviving items", function()
    local separator = ui.span("|")
    local joined = ui.join({ false, "a", "b", nil, "c" }, separator)
    assert.equals(5, #joined)
    assert.equals(separator, joined[2])
    assert.equals(separator, joined[4])

    local indexes = {}
    local with_functions = ui.join({ "a", false, "b", "c" }, function(index)
      indexes[#indexes + 1] = index
      return tostring(index)
    end)
    assert.same({ "a", "1", "b", "2", "c" }, with_functions)
    assert.same({ 1, 2 }, indexes)

    local calls = 0
    assert.same(
      { "single" },
      ui.join({ "single" }, function()
        calls = calls + 1
      end)
    )
    assert.same(
      {},
      ui.join({ false, nil }, function()
        calls = calls + 1
      end)
    )
    assert.equals(0, calls)
  end)

  it("preserves nested fragments as items while joining", function()
    local nested = { "inside", { "nested" } }
    local joined = ui.join({ nested, "outside" }, ",")
    assert.equals(nested, joined[1])
    assert.equals(",", joined[2])
    assert.equals("outside", joined[3])
  end)
end)
