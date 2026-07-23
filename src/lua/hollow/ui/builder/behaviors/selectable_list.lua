local click_registry = require("hollow.ui.builder.internal.click_registry")
local scroll_nav = require("hollow.ui.builder.behaviors.scroll_nav").scroll_nav

local M = {}
local next_instance_id = 0

---@param opts { id_prefix: string, items: fun(): table[], row_budget: fun(): integer, row_count_fn?: (fun(item: any): integer), on_activate: fun(index: integer) }
---@return table
function M.selectable_list(opts)
  next_instance_id = next_instance_id + 1

  local instance_id = tostring(next_instance_id)
  local nav = scroll_nav(0, { row_count_fn = opts.row_count_fn })
  local row_id_prefix = opts.id_prefix .. ":item:" .. instance_id .. ":"
  local scrollbar_id = opts.id_prefix .. ":scrollbar:" .. instance_id
  local self = { nav = nav }

  function self.visible_range()
    local items = opts.items()
    local start_idx, end_idx, show_scrollbar, thumb_index, thumb_ratio, thumb_size =
      nav.visible_range(items, opts.row_budget())
    return {
      start_idx = start_idx,
      end_idx = end_idx,
      show_scrollbar = show_scrollbar,
      thumb_index = thumb_index,
      thumb_ratio = thumb_ratio,
      thumb_size = thumb_size,
    }
  end

  function self.row(index, key, visible_index, viewport)
    local row_id = row_id_prefix .. tostring(key)
    click_registry.register(row_id, function()
      nav.index = index
      opts.on_activate(index)
    end)
    return row_id,
      {
        id = row_id,
        scrollbar_track = viewport.show_scrollbar,
        scrollbar_thumb = viewport.show_scrollbar and visible_index == viewport.thumb_index,
        scrollbar_id = scrollbar_id,
        scrollbar_thumb_ratio = viewport.thumb_ratio,
        scrollbar_thumb_size = viewport.thumb_size,
      }
  end

  function self.on_event(name, payload)
    if name == "overlay:scroll" then
      local delta = payload and payload.delta or 0
      if delta == 0 then
        return true
      end
      local items = opts.items()
      if #items > 0 then
        local direction = delta < 0 and 1 or -1
        nav.scroll_by(items, direction, opts.row_budget())
      end
      return true
    elseif name == "overlay:scrollbar" and payload and payload.id == scrollbar_id then
      nav.scroll_to_ratio(opts.items(), payload.ratio or 0, opts.row_budget())
      return true
    end
    return false
  end

  return self
end

return M
