package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local harness = require("tests.harness")

describe("event filters", function()
  local env, events
  before_each(function()
    env = harness.boot()
    events = env.hollow.events
  end)

  it("chains replacements in order without mutating the input", function()
    events.filter("custom:spec", function(spec)
      spec.env.EDITOR = "nvim"
      return spec
    end)
    events.filter("custom:spec", function(spec)
      assert.equal("nvim", spec.env.EDITOR)
      return { env = spec.env, done = true }
    end)
    local input = { env = {} }
    local result = events.apply_filters("custom:spec", input)
    assert.same({ env = { EDITOR = "nvim" }, done = true }, result)
    assert.same({ env = {} }, input)
  end)

  it("rolls back nil, errors and invalid returns, then continues", function()
    for _, mode in ipairs({ "nil", "error", "invalid" }) do
      events.filter("rollback", function(spec)
        spec.nested.value = mode
        if mode == "error" then
          error("failed")
        end
        if mode == "invalid" then
          return false
        end
      end)
    end
    events.filter("rollback", function(spec)
      assert.equal("original", spec.nested.value)
      spec.done = true
      return spec
    end)
    assert.same(
      { nested = { value = "original" }, done = true },
      events.apply_filters("rollback", { nested = { value = "original" } })
    )
  end)

  it("supports removal and defers registrations until the next application", function()
    local late, removed
    events.filter("mutation", function(spec)
      events.off(removed)
      if not late then
        late = events.filter("mutation", function(value)
          value.late = true
          return value
        end)
      end
      return spec
    end)
    removed = events.filter("mutation", function()
      error("removed filter ran")
    end)
    assert.same({}, events.apply_filters("mutation", {}))
    assert.same({ late = true }, events.apply_filters("mutation", {}))
    events.off(late)
    events.off(late)
  end)

  it("keeps notifications separate and bypasses same-name recursion", function()
    local calls = 0
    events.filter("custom", function(spec)
      calls = calls + 1
      return events.apply_filters("custom", spec)
    end)
    events.on("custom", function()
      calls = calls + 10
    end)
    events.emit("custom", {})
    assert.equal(10, calls)
    events.apply_filters("custom", {})
    assert.equal(11, calls)
  end)

  it("validates registration and application", function()
    assert.has_error(function()
      events.filter("", function() end)
    end)
    assert.has_error(function()
      events.filter("custom", false)
    end)
    assert.has_error(function()
      events.apply_filters("custom", false)
    end)
    assert.has_error(function()
      events.apply_filters(false, {})
    end)
  end)

  it("copies accepted results so retained references cannot mutate the chain", function()
    local retained
    events.filter("retained", function(spec)
      retained = spec
      spec.value = "accepted"
      return spec
    end)
    events.filter("retained", function(spec)
      retained.value = "changed later"
      assert.equal("accepted", spec.value)
      return spec
    end)
    assert.equal("accepted", events.apply_filters("retained", {}).value)
  end)

  local function spawn_spec()
    return {
      shell = "/bin/sh",
      domain = "local",
      cwd = "/home/user",
      env = {
        HOLLOW_PANE_ID = "101",
        TERM = "xterm-256color",
        EDITOR = "vi",
      },
    }
  end

  it("customizes local launch cwd and env", function()
    events.filter("term:spawn", function(spec)
      spec.cwd = "/project"
      spec.env.EDITOR = "nvim"
      return spec
    end)
    local result = env.hollow._filter_spawn(spawn_spec())
    assert.equal("/project", result.cwd)
    assert.equal("nvim", result.env.EDITOR)
  end)

  it("allows inheriting host cwd and removing ordinary environment overrides", function()
    events.filter("term:spawn", function(spec)
      spec.cwd = nil
      spec.env.EDITOR = nil
      spec.env.EMPTY = ""
      return spec
    end)
    local result = env.hollow._filter_spawn(spawn_spec())
    assert.is_nil(result.cwd)
    assert.is_nil(result.env.EDITOR)
    assert.equal("", result.env.EMPTY)
    assert.equal("101", result.env.HOLLOW_PANE_ID)
  end)

  it("rejects invalid spawn changes independently", function()
    local changes = {
      function(s)
        s.env.HOLLOW_PANE_ID = "fake"
      end,
      function(s)
        s.env.HOLLOW_NEW = "fake"
      end,
      function(s)
        s.env.hollow_pane_id = "fake"
      end,
      function(s)
        s.env.TERM = nil
      end,
      function(s)
        s.env.term = "fake"
      end,
      function(s)
        s.env.BAD = 1
      end,
      function(s)
        s.env["A=B"] = "bad"
      end,
      function(s)
        s.env.BAD = "a\0b"
      end,
      function(s)
        s.cwd = "a\0b"
      end,
      function(s)
        s.shell = "other"
      end,
      function(s)
        s.domain = "remote"
      end,
      function(s)
        s.extra = true
      end,
    }
    for _, change in ipairs(changes) do
      events.filter("term:spawn", function(spec)
        change(spec)
        return spec
      end)
    end
    assert.same(spawn_spec(), env.hollow._filter_spawn(spawn_spec()))
  end)

  it("discards late spawn answers without claiming to preempt callbacks", function()
    events.filter("term:spawn", function(spec)
      env.recorded.now_ms = env.recorded.now_ms + 51
      spec.cwd = "/too-late"
      return spec
    end)
    events.filter("term:spawn", function(spec)
      spec.env.EDITOR = "nvim"
      return spec
    end)
    local result = env.hollow._filter_spawn(spawn_spec())
    assert.equal("/home/user", result.cwd)
    assert.equal("nvim", result.env.EDITOR)
  end)
end)
