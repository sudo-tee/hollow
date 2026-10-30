local util = require("hollow.util")

describe("UTF-8 utility truncation", function()
  local fixtures = {
    { "a", "b", "c", "d", "e", "f", "g" },
    { "é", "ø", "ñ", "ü", "ç", "å", "ß" },
    { "中", "文", "字", "符", "測", "試", "界" },
    { "😀", "🚀", "🌍", "🎉", "🐱", "🍕", "💡" },
    { "a", "é", "中", "😀", "b", "ø", "界" },
    { "e", "́", "x", "y", "z", "a", "b" },
  }

  it("slices only at codepoint boundaries for every truncation width", function()
    for _, codepoints in ipairs(fixtures) do
      local value = table.concat(codepoints)
      for width = 0, #codepoints + 1 do
        local expected_end, expected_start
        if width >= #codepoints then
          expected_end, expected_start = value, value
        elseif width == 0 then
          expected_end, expected_start = "", ""
        else
          local count = width <= 3 and width or width - 3
          expected_end = table.concat(codepoints, "", 1, count)
          expected_start = table.concat(codepoints, "", #codepoints - count + 1)
          if width > 3 then
            expected_end = expected_end .. "..."
            expected_start = "..." .. expected_start
          end
        end
        assert.equals(expected_end, util.truncate_end(value, width))
        assert.equals(expected_start, util.truncate_start(value, width))
      end
    end
  end)

  it("returns empty text for nonpositive widths", function()
    for _, width in ipairs({ -10, -1, 0 }) do
      assert.equals("", util.truncate_end("é中😀", width))
      assert.equals("", util.truncate_start("é中😀", width))
    end
  end)

  it("preserves coercion and text that already fits", function()
    for _, truncate in ipairs({ util.truncate_end, util.truncate_start }) do
      assert.equals("", truncate(nil, 4))
      assert.equals("", truncate(false, 4))
      assert.equals("123", truncate(123, 3))
      assert.equals("é中😀", truncate("é中😀", 3))
      assert.equals("", truncate("", 1))
    end
  end)
end)
