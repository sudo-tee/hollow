-- Read-only, wrapped text with keyboard, wheel, and scrollbar navigation.
-- Composes inside a modal; does not create or replace an overlay.
local ui = _G.hollow.ui
local util = require("hollow.util")
local M = {}

local function wrap(text, width)
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    local line, length = "", 0
    for word in paragraph:gmatch("%S+") do
      local word_length = util.utf8_len(word)
      if length > 0 and length + 1 + word_length > width then
        lines[#lines + 1], line, length = line, "", 0
      end
      if length > 0 then
        line, length = line .. " ", length + 1
      end
      -- Never split a UTF-8 sequence, including when breaking long URLs.
      for character in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if length == width then
          lines[#lines + 1], line, length = line, "", 0
        end
        line, length = line .. character, length + 1
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

function M.text_view(opts)
  opts = opts or {}
  local lines = {}
  local self = {}
  local list = ui.selectable_list({
    id_prefix = opts.id or "text-view",
    items = function()
      return lines
    end,
    row_budget = function()
      return math.max(1, opts.row_budget or 16)
    end,
    on_activate = function() end,
  })
  self.nav = list.nav
  self.on_event = list.on_event
  self.keys = ui.keys(list.nav, {
    ["arrow_down|j"] = function()
      list.nav.index = math.min(#lines, list.nav.index + 1)
    end,
    ["arrow_up|k"] = function()
      list.nav.index = math.max(1, list.nav.index - 1)
    end,
  })

  function self.set(text)
    lines = wrap(text, math.max(1, opts.width or 80))
    list.nav.index = 1
  end

  function self.render(theme)
    local rows = {}
    local viewport = list.visible_range()
    for index = viewport.start_idx, viewport.end_idx do
      local _, options = list.row(index, index, index - viewport.start_idx + 1, viewport)
      options.scrollbar_track_color = theme.scrollbar_track
      options.scrollbar_thumb_color = theme.scrollbar_thumb
      rows[#rows + 1] = ui.row({ ui.text(lines[index], { fg = theme.fg }) }, options)
    end
    return rows
  end

  self.set(opts.text or "")
  return self
end

return M
