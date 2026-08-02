package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("fonts test suite", function()
  local env
  local hollow

  setup(function()
    env = harness.boot()
    hollow = env.hollow
  end)

  describe("fonts.list", function()
    it("returns host-provided families", function()
      local font_list = hollow.fonts.list()
      harness.assert_equal(
        font_list[1].family,
        "Consolas",
        "fonts.list should return host-provided families"
      )
    end)

    it("preserves style arrays", function()
      local font_list = hollow.fonts.list()
      harness.assert_equal(
        font_list[2].styles[2],
        "Italic",
        "fonts.list should preserve style arrays"
      )
    end)
  end)

  describe("fonts.find", function()
    it("matches normalized family names", function()
      harness.assert_true(
        #hollow.fonts.find("mono") >= 1,
        "fonts.find should match normalized family names"
      )
    end)
  end)

  describe("fonts.has", function()
    it("detects installed families", function()
      harness.assert_true(
        hollow.fonts.has("Cascadia Mono"),
        "fonts.has should detect installed families"
      )
    end)

    it("detects installed styles", function()
      harness.assert_true(
        hollow.fonts.has("Cascadia Mono", "Italic"),
        "fonts.has should detect installed styles"
      )
    end)

    it("rejects missing styles", function()
      harness.assert_true(
        not hollow.fonts.has("Cascadia Mono", "Black"),
        "fonts.has should reject missing styles"
      )
    end)
  end)

  describe("fonts.pick", function()
    it("returns the first available family", function()
      harness.assert_equal(
        hollow.fonts.pick({ "Missing Font", "Cascadia Mono", "Consolas" }),
        "Cascadia Mono",
        "fonts.pick should return the first available family"
      )
    end)

    it("returns nil when no candidate exists", function()
      harness.assert_equal(
        hollow.fonts.pick({ "Missing Font" }),
        nil,
        "fonts.pick should return nil when no candidate exists"
      )
    end)
  end)
end)
