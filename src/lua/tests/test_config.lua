package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("config test suite", function()
  local env
  local hollow
  local recorded

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  describe("config.set", function()
    it("forwards config to the host", function()
      hollow.config.set({ theme = { ui = { accent = "#abcdef" } } })
      harness.assert_equal(
        recorded.config.theme.ui.accent,
        "#abcdef",
        "config.set should forward config to the host"
      )
    end)

    it("updates stored state", function()
      harness.assert_equal(
        hollow.config.get("theme").ui.accent,
        "#abcdef",
        "config.set should update stored state"
      )
    end)
  end)

  describe("config.snapshot", function()
    it("clones values", function()
      local snapshot = hollow.config.snapshot()
      snapshot.theme.ui.accent = "#000000"
      harness.assert_equal(
        hollow.config.get("theme").ui.accent,
        "#abcdef",
        "config.snapshot should clone values"
      )
    end)
  end)

  describe("package.path wiring", function()
    it("adds the config directory to package.path", function()
      harness.assert_equal(
        require("user_module").source,
        "config",
        "config directory should be added to package.path"
      )
    end)

    it("adds lib_dir to package.path", function()
      hollow.config.set({ lib_dir = "src/lua/tests/fixtures/lib" })
      harness.assert_equal(
        require("custom.module").source,
        "lib",
        "lib_dir should be added to package.path"
      )
    end)
  end)
end)
