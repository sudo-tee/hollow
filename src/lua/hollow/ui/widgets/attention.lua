local hollow = _G.hollow
local ui = hollow.ui

local M = {}

local function collect_attention_panes()
  local result = {}
  local workspaces = hollow.term.mux_tree() or {}
  for _, ws in ipairs(workspaces) do
    for _, tab in ipairs(ws.tabs or {}) do
      for _, pane in ipairs(tab.panes or {}) do
        if pane.has_bell then
          result[#result + 1] = {
            pane = pane,
            tab = tab,
            workspace = ws,
          }
        end
      end
    end
  end
  return result
end

local function has_attention_anywhere()
  local workspaces = hollow.term.mux_tree() or {}
  for _, ws in ipairs(workspaces) do
    for _, tab in ipairs(ws.tabs or {}) do
      for _, pane in ipairs(tab.panes or {}) do
        if pane.has_bell and not pane.is_focused then
          return true
        end
      end
    end
  end
  return false
end

local function label_for_entry(entry)
  local tab_title = entry.tab.title or ""
  local pane_title = entry.pane.title or ""
  local parts = {}
  if tab_title ~= "" then
    parts[#parts + 1] = tab_title
  end
  if pane_title ~= "" and pane_title ~= tab_title then
    parts[#parts + 1] = pane_title
  end
  if #parts == 0 then
    parts[#parts + 1] = "pane " .. entry.pane.id
  end
  return table.concat(parts, " - ")
end

function M.topbar_button()
  return ui.bar.custom({
    id = "attention-button",
    render = function()
      if has_attention_anywhere() then
        return ui.span("●", { fg = "#ffcc66", bold = true })
      end
      return nil
    end,
    on_click = function()
      local items = collect_attention_panes()
      if #items == 0 then
        return
      end

      ui.select.open({
        prompt = "Attention",
        items = items,
        width = 80,
        max_height = 20,
        fuzzy = false,
        label = function(entry)
          return label_for_entry(entry)
        end,
        detail = function(entry)
          local parts = {}
          if entry.workspace and entry.workspace.name then
            parts[#parts + 1] = entry.workspace.name
          end
          if entry.pane.foreground_process and entry.pane.foreground_process ~= "" then
            parts[#parts + 1] = entry.pane.foreground_process
          end
          return table.concat(parts, " ")
        end,
        search_text = function(entry)
          return label_for_entry(entry)
            .. "\n"
            .. (entry.workspace and entry.workspace.name or "")
            .. "\n"
            .. (entry.pane.foreground_process or "")
        end,
        actions = {
          {
            name = "focus",
            desc = "focus pane",
            fn = function(entry)
              ui.select.close()
              if entry and entry.pane and entry.pane.id then
                hollow.term.focus_pane_by_id(entry.pane.id)
              end
            end,
          },
        },
      })
    end,
    cache_ttl_ms = 300,
  })
end

return M
