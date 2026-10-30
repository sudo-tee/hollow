--- Key composition.
---
--- Each arg is either a behavior (extracts .handlers) or a raw key table.
--- Later entries win on conflict.
---
--- Supports Vim-style modifier syntax: "<C-r>", "<C-S-enter>", "<CR>", etc.
--- Pipe-separated aliases are expanded: "tab|arrow_right".
--- Supports _else catch-all.
---
--- Bare keys (no modifier tag) match any mods as fallback,
--- but a specific mods-key binding takes priority.

local M = {}
local hollow = _G.hollow

local function expand_aliases(key)
  local parts = {}
  for part in key:gmatch("[^|]+") do
    parts[#parts + 1] = part
  end
  return parts
end

--- Parse a chord spec using hollow's keymap parser.
--- For bare key names (no `<>`), returns them as-is with empty mods.
---@param raw string
---@return string mods, string key
local function parse_key_spec(raw)
  if raw:sub(1, 1) == "<" and raw:sub(-1, -1) == ">" then
    local key, mods = hollow.keymap.parse_chord(raw)
    return hollow.keymap.format_mods(mods), key
  end
  return "", raw
end

---@param ... table
---@return function
function M.keys(...)
  local merged = {}
  local catch_all = nil

  for _, arg in ipairs({ ... }) do
    if type(arg) == "table" then
      local handlers = arg.handlers or arg
      for key, handler in pairs(handlers) do
        if key == "_else" then
          catch_all = handler
        else
          local aliases = expand_aliases(key)
          for _, alias in ipairs(aliases) do
            local mods, bare_key = parse_key_spec(alias)
            local combined = mods .. ":" .. bare_key
            merged[combined] = handler
          end
        end
      end
    end
  end

  return function(key, mods)
    local combined = (mods or "") .. ":" .. key
    local handler = merged[combined]
    if handler then
      handler(key, mods)
      return true
    end

    if (mods or "") ~= "" then
      handler = merged[":" .. key]
      if handler then
        handler(key, mods)
        return true
      end
    end

    if catch_all then
      local consumed = catch_all(key, mods)
      if consumed ~= false then
        return true
      end
    end

    return false
  end
end

return M
