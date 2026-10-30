local util = require("hollow.util")

describe("utility display-width provider", function()
  local saved_host
  before_each(function()
    saved_host = rawget(_G, "host_api")
    _G.host_api = nil
  end)
  after_each(function()
    _G.host_api = saved_host
  end)

  it("keeps explicit codepoint fallback without native Unicode data", function()
    assert.equals(2, util.display_width("中文"))
    assert.equals(2, util.display_width("é"))
    assert.equals(5, util.display_width("👨‍👩‍👧"))
    assert.equals("中", util.truncate_end("中文", 1))
  end)

  it("ignores harness catch-all methods and unavailable provider results", function()
    _G.host_api = setmetatable({}, {
      __index = function()
        return function() end
      end,
    })
    assert.equals(2, util.display_width("中文"))
    _G.host_api = {
      text_graphemes = function()
        return nil
      end,
    }
    assert.equals(2, util.display_width("中文"))
  end)

  it("measures printable ASCII without calling the native provider", function()
    _G.host_api = {
      text_graphemes = function()
        error("provider called for printable ASCII")
      end,
    }
    assert.equals(11, util.display_width("workspace 1"))
    assert.equals(0, util.display_width(""))
    assert.equals("works...", util.truncate_end("workspace 1", 8))
    assert.equals("...ace 1", util.truncate_start("workspace 1", 8))
    assert.equals("wor", util.truncate_end("workspace 1", 3))
    assert.equals("e 1", util.truncate_start("workspace 1", 3))
    assert.equals("workspace 1", util.truncate_end("workspace 1", 11))
  end)

  it("uses native-provider clusters without splitting or exceeding cell budget", function()
    -- Provider-contract fixture only. Real Ghostty results are covered by
    -- `zig build test-text-width`; standalone Lua does not ship width tables.
    local input = "中é👨‍👩‍👧ab"
    local clusters = {
      { text = "中", width = 2 },
      { text = "é", width = 1 },
      { text = "👨‍👩‍👧", width = 2 },
      { text = "a", width = 1 },
      { text = "b", width = 1 },
    }
    _G.host_api = {
      text_graphemes = function(value)
        assert.equals(input, value)
        return clusters
      end,
    }
    assert.equals(7, util.display_width(input))
    assert.equals(10, util.utf8_len(input)) -- count is deliberately not display width
    assert.equals("", util.truncate_end(input, 1))
    assert.equals("中", util.truncate_end(input, 2))
    assert.equals("中é", util.truncate_end(input, 3))
    assert.equals("...", util.truncate_end(input, 4)) -- first wide cluster cannot fit
    assert.equals("中...", util.truncate_end(input, 5))
    assert.equals("...ab", util.truncate_start(input, 5))
    assert.equals("...ab", util.truncate_start(input, 6))
    assert.equals("ab", util.truncate_start(input, 2))
    assert.equals(input .. " ", util.pad_right(input, 8))
    assert.equals(" " .. input, util.pad_left(input, 8))
  end)
end)
