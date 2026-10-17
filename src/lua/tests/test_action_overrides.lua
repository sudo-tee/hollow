package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("action overrides", function()
  local env, hollow, recorded

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  it("runs in order and stops on the first truthy result", function()
    local calls = {}
    hollow.action.override("new_tab", function()
      calls[#calls + 1] = 1
      return false
    end)
    hollow.action.override("new_tab", function()
      calls[#calls + 1] = 2
      return "handled"
    end)
    hollow.action.override("new_tab", function()
      calls[#calls + 1] = 3
    end)
    hollow.action.new_tab()
    assert.same({ 1, 2 }, calls)
    assert.equal(0, recorded.new_tab_calls)
  end)

  it("passes arguments and snapshots, then falls through unchanged", function()
    local opts = { cwd = "/tmp", insert_at_end = true }
    local context
    hollow.action.override("new_tab", function(ctx)
      context = ctx
    end)
    hollow.action.new_tab(opts, nil, "last")
    assert.equal("new_tab", context.name)
    assert.equal(opts, context.args[1])
    assert.equal(3, context.args.n)
    assert.is_nil(context.args[2])
    assert.equal("last", context.args[3])
    assert.equal(101, context.pane.id)
    assert.equal(201, context.tab.id)
    assert.equal("main", context.workspace.name)
    assert.equal(1, recorded.new_tab_calls)
    assert.equal(opts, recorded.new_tab)
  end)

  it("intercepts action list callbacks used by the palette", function()
    local calls = 0
    for _, entry in ipairs(hollow.action.list()) do
      if entry.name == "new_tab" then
        hollow.action.override("new_tab", function()
          calls = calls + 1
          return true
        end)
        entry.run()
      end
    end
    assert.equal(1, calls)
    assert.equal(0, recorded.new_tab_calls)
  end)

  it("intercepts named keymaps", function()
    local calls = 0
    hollow.action.override("new_tab", function()
      calls = calls + 1
      return true
    end)
    hollow.keymap.set("<C-t>", "new_tab")
    env.get_key_handler()("t", 2)
    assert.equal(1, calls)
    assert.equal(0, recorded.new_tab_calls)
  end)

  it("intercepts targeted tab-close buttons without changing the target", function()
    local context
    local remove = hollow.action.override("close_tab", function(ctx)
      context = ctx
      return true
    end)
    hollow.action.close_tab({ tab_id = 201 })
    assert.equal(201, context.args[1].tab_id)
    assert.is_nil(recorded.close_tab_by_id)
    remove()
    hollow.action.close_tab({ tab_id = 201 })
    assert.equal(201, recorded.close_tab_by_id)
  end)

  it("bypasses same-action and cross-action overrides while a handler runs", function()
    local calls, nested_calls = 0, 0
    hollow.action.override("close_pane", function()
      nested_calls = nested_calls + 1
    end)
    hollow.action.override("new_tab", function(ctx)
      calls = calls + 1
      hollow.action.new_tab(ctx.args[1])
      hollow.action.close_pane()
      return true
    end)
    hollow.action.new_tab({ cwd = "/tmp" })
    assert.equal(1, calls)
    assert.equal(0, nested_calls)
    assert.equal(1, recorded.new_tab_calls)
    assert.is_not_nil(recorded.close_pane)
  end)

  it("reports failures, continues handlers, and restores the recursion guard", function()
    local errors, calls = {}, 0
    hollow.ui.notify.error = function(message)
      errors[#errors + 1] = message
    end
    hollow.action.override("new_tab", function()
      error("broken override")
    end)
    hollow.action.override("new_tab", function()
      calls = calls + 1
    end)
    hollow.action.new_tab()
    hollow.action.new_tab()
    assert.equal(2, calls)
    assert.equal(2, recorded.new_tab_calls)
    assert.equal(2, #errors)
    assert.matches("broken override", errors[1])
  end)

  it("supports idempotent removal and mutation during dispatch", function()
    local calls, remove_later = {}, nil
    local remove_first = hollow.action.override("new_tab", function()
      calls[#calls + 1] = "first"
      remove_later()
      hollow.action.override("new_tab", function()
        calls[#calls + 1] = "added"
      end)
    end)
    remove_later = hollow.action.override("new_tab", function()
      calls[#calls + 1] = "removed"
    end)
    hollow.action.new_tab()
    assert.same({ "first" }, calls)
    remove_first()
    remove_first()
    hollow.action.new_tab()
    assert.same({ "first", "added" }, calls)
  end)

  it("does not intercept low-level term operations", function()
    local calls = 0
    hollow.action.override("new_tab", function()
      calls = calls + 1
    end)
    hollow.term.new_tab({ cwd = "/tmp" })
    assert.equal(1, recorded.new_tab_calls)
    assert.equal(0, calls)
  end)

  it("keeps separate runtimes isolated", function()
    hollow.action.override("new_tab", function()
      return true
    end)
    local other = harness.boot()
    other.hollow.action.new_tab()
    assert.equal(1, other.recorded.new_tab_calls)
    hollow.action.new_tab()
    assert.equal(0, recorded.new_tab_calls)
  end)

  it("restores the guard after a nested original action throws", function()
    local calls = 0
    hollow.action.register("broken", {
      run = function()
        error("original failed")
      end,
    })
    hollow.action.override("broken", function()
      calls = calls + 1
      hollow.action.broken()
    end)
    assert.has_error(hollow.action.broken)
    assert.has_error(hollow.action.broken)
    assert.equal(2, calls)
  end)

  it("preserves custom action arguments and return values", function()
    local calls = 0
    hollow.action.register("custom", {
      run = function(...)
        return select("#", ...), ...
      end,
    })
    hollow.action.override("custom", function()
      calls = calls + 1
    end)
    local n, first, second, third = hollow.action.custom("first", nil, "third")
    assert.equal(1, calls)
    assert.equal(3, n)
    assert.equal("first", first)
    assert.is_nil(second)
    assert.equal("third", third)
  end)

  it("validates registration", function()
    assert.has_error(function()
      hollow.action.override("missing", function() end)
    end)
    assert.has_error(function()
      hollow.action.override("new_tab", true)
    end)
    assert.has_error(function()
      hollow.action.register("override", { run = function() end })
    end)
  end)
end)
