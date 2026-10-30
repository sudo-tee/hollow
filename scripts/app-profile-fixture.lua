-- Isolated synthetic picker fixture for app profiling; no workspace actions.
local hollow = require("hollow")
local picker = assert(os.getenv("HOLLOW_PROFILE_PICKER"))
assert(picker == "palette" or picker == "workspace")
hollow.config.set({ default_domain = "cmd", vsync = false, debug_overlay = false })
local entries = {}
for i = 1, 100 do
  if picker == "palette" then
    entries[i] =
      { name = "command_" .. i, desc = "Command " .. i, category = "general", chords = {} }
  else
    entries[i] =
      { name = "workspace " .. i, cwd = "/srv/project/" .. i, domain = "remote", workspace_id = i }
  end
end
local list
local original_list = hollow.ui.selectable_list
hollow.ui.selectable_list = function(opts)
  list = original_list(opts)
  local on_event = list.on_event
  local reported = false
  list.on_event = function(name, payload)
    if name == "overlay:scroll" and not reported then
      local before = list.visible_range().start_idx
      local consumed = on_event(name, payload)
      local after = list.visible_range().start_idx
      if before ~= after then
        reported = true
        hollow.log(
          string.format(
            "HOLLOW_PROFILE_SCROLL_CHANGED before=%d after=%d delta=%s",
            before,
            after,
            tostring(payload.delta)
          )
        )
      end
      return consumed
    end
    return on_event(name, payload)
  end
  return list
end
local dispatch = hollow.ui.dispatch_overlay_key
local key_reported = false
hollow.ui.dispatch_overlay_key = function(key, mods)
  local before = list and list.nav.index
  local consumed = dispatch(key, mods)
  local after = list and list.nav.index
  if not key_reported and before and after and before ~= after then
    key_reported = true
    hollow.log(
      string.format("HOLLOW_PROFILE_KEY_CHANGED key=%s before=%d after=%d", key, before, after)
    )
  end
  return consumed
end
local sizes = {}
hollow.events.on("window:resized", function(event)
  local size = event.size or {}
  local signature = tostring(size.width) .. "x" .. tostring(size.height)
  if not sizes[signature] then
    sizes[signature] = true
    hollow.log("HOLLOW_PROFILE_RESIZED " .. signature)
  end
end)
hollow.events.on("gui:ready", function()
  if picker == "palette" then
    hollow.ui.command_palette.open({ entries = entries })
  else
    require("hollow.ui.workspace.source").items = function()
      return entries
    end
    hollow.ui.workspace.open_switcher()
  end
  local overlay = hollow.ui._overlay_state()
  assert(list and overlay[1] and overlay[1].clay == true, "profile picker did not open")
  hollow.log("HOLLOW_PROFILE_FIXTURE_READY " .. picker)
end)
