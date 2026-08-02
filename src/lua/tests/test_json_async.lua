package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("json and async test suite", function()
  local env
  local hollow

  setup(function()
    env = harness.boot()
    hollow = env.hollow
  end)

  describe("module exposure", function()
    it("exposes json.encode", function()
      harness.assert_true(type(hollow.json.encode) == "function", "json.encode should be exposed")
    end)

    it("exposes json.decode", function()
      harness.assert_true(type(hollow.json.decode) == "function", "json.decode should be exposed")
    end)

    it("exposes async.run", function()
      harness.assert_true(type(hollow.async.run) == "function", "async.run should be exposed")
    end)

    it("exposes async.await", function()
      harness.assert_true(type(hollow.async.await) == "function", "async.await should be exposed")
    end)
  end)

  describe("async", function()
    it("resumes coroutines with resolved values", function()
      local async_value = nil
      hollow.async.run(function()
        async_value = hollow.async.await(function(resolve)
          resolve("ok")
        end)
      end)
      harness.assert_equal(
        async_value,
        "ok",
        "async.await should resume coroutines with resolved values"
      )
    end)

    it("invokes chained promise handlers", function()
      local promise_value = nil
      local promise = hollow.async.promise(function(resolve)
        resolve(42)
      end)
      promise:next(function(value)
        promise_value = value
        return value
      end)
      harness.assert_equal(promise_value, 42, "async.promise should invoke chained handlers")
    end)
  end)
end)
