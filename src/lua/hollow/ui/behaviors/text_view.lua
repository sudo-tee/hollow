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
      local word_length = util.display_width(word)
      if length > 0 and length + 1 + word_length > width then
        lines[#lines + 1], line, length = line, "", 0
      end
      if length > 0 then
        line, length = line .. " ", length + 1
      end
      -- Never split a grapheme cluster, including when breaking long URLs.
      for _, cluster in ipairs(util.text_graphemes(word)) do
        if length > 0 and length + cluster.width > width then
          lines[#lines + 1], line, length = line, "", 0
        end
        line, length = line .. cluster.text, length + cluster.width
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

  -- Read-only behavior supplies visible text and scrollbar state, never
  -- presentation nodes. Consumers render these in their own component tree.
  function self.visible()
    local viewport = list.visible_range()
    local visible = {}
    for index = viewport.start_idx, viewport.end_idx do
      visible[#visible + 1] = lines[index]
    end
    return {
      lines = visible,
      scrollbar = viewport.show_scrollbar and {
        id = viewport.scrollbar_id,
        ratio = viewport.thumb_ratio,
        size = viewport.thumb_size,
      } or nil,
    }
  end

  self.set(opts.text or "")
  return self
end

return M
