-- Activity policy: keep acknowledgement separate from terminal state and toast TTL.
local Store = require("hollow.activity.store")
local util = require("hollow.util")
local M = {}

---@param hollow Hollow
---@param host_api HollowHostBridge
function M.setup(hollow, host_api)
  local store = Store.new()
  local statuses = {}
  -- A long-lived agent's shell command is not evidence that its task is still
  -- working after the agent clears its own status. Reset only for a new command.
  local program_commands = {}
  local api = {}
  hollow.activity = api

  local function now()
    return util.host_now_ms(host_api)
  end

  local function changed()
    hollow.ui.topbar.invalidate()
    hollow.ui.bottombar.invalidate()
    hollow.events.emit("activity:changed", {})
  end

  local function background(pane)
    return not hollow.ui.is_focused() or (pane ~= nil and pane.is_focused ~= true)
  end

  local function context(pane)
    if not pane then
      return {}
    end
    local result = { pane_id = pane.id, pane_title = pane.title, cwd = pane.cwd }
    for _, workspace in ipairs(hollow.term.mux_tree()) do
      for _, tab in ipairs(workspace.tabs or {}) do
        for _, candidate in ipairs(tab.panes or {}) do
          if candidate.id == pane.id then
            result.workspace = workspace.name
            result.tab_title = tab.title
            return result
          end
        end
      end
    end
    return result
  end

  function api.list(opts)
    opts = opts or {}
    local view = opts.view or "inbox"
    assert(view == "inbox" or view == "history" or view == "running", "invalid activity view")
    local entries = view == "running" and api.running() or store:list(view)
    local result = {}
    for _, entry in ipairs(entries) do
      if
        (not opts.pane_id or entry.pane_id == opts.pane_id)
        and (not opts.workspace or entry.workspace == opts.workspace)
        and (not opts.activity_kind or entry.kind == opts.activity_kind)
        and (not opts.level or entry.level == opts.level)
      then
        result[#result + 1] = entry
      end
    end
    return result
  end

  function api.summary()
    return store:summary()
  end

  function api.dismiss(id)
    if not store:dismiss(id) then
      return false
    end
    hollow.events.emit("activity:dismissed", { id = id })
    changed()
    return true
  end

  function api.dismiss_all()
    for _, entry in ipairs(store:list("inbox")) do
      api.dismiss(entry.id)
    end
  end

  function api.clear_history()
    store:clear_history()
    changed()
  end

  -- Native reload transfers this value in memory only, never to a session file.
  function api._export()
    local panes = {}
    for pane_id, records in pairs(statuses) do
      panes[#panes + 1] = {
        pane_id = pane_id,
        records = records,
        program_command = program_commands[pane_id] == true,
      }
    end
    for pane_id in pairs(program_commands) do
      if statuses[pane_id] == nil then
        panes[#panes + 1] = { pane_id = pane_id, records = {}, program_command = true }
      end
    end
    return util.clone_value({ entries = store.entries, next_id = store.next_id, statuses = panes })
  end

  function api._restore(snapshot)
    local startup_entries = store.entries
    store.entries = util.clone_value(snapshot.entries)
    store.next_id = snapshot.next_id
    statuses = {}
    program_commands = {}
    for _, pane in ipairs(snapshot.statuses) do
      statuses[pane.pane_id] = util.clone_value(pane.records)
      local program_command = pane.program_command
      if program_command == nil then
        program_command = next(pane.records) ~= nil
      end
      program_commands[pane.pane_id] = program_command or nil
    end
    -- Config scripts may already have posted new toasts. Preserve those too,
    -- remapping their activity IDs so they cannot dismiss a restored entry.
    local remapped = {}
    for _, entry in ipairs(startup_entries) do
      remapped[entry.id] = store:append(entry).id
    end
    for _, widget in ipairs(require("hollow.state").get().ui.overlay_stack) do
      if widget._activity_id then
        widget._activity_id = remapped[widget._activity_id]
      end
    end
    changed()
  end

  -- Internal toast bridge; ui.notify is also used by plugins and application errors.
  function api._notification(message, opts)
    local pane = opts.pane_id and hollow.term.pane_by_id(opts.pane_id) or nil
    local key = opts.id and ("notification:" .. opts.id) or nil
    local previous = key and store:pending(key)
    if previous then
      api.dismiss(previous.id)
    end
    local entry = context(pane)
    entry.kind = "notification"
    entry.key = key
    entry.title = opts.title or "Notification"
    entry.message = message
    entry.level = opts.level or "info"
    entry.timestamp_ms = now()
    entry.pending = background(pane)
    local id = store:append(entry).id
    changed()
    return id
  end

  function api._dismiss_notifications(notification_id)
    for _, entry in ipairs(store:list("inbox")) do
      if
        entry.kind == "notification"
        and (notification_id == nil or entry.key == "notification:" .. notification_id)
      then
        api.dismiss(entry.id)
      end
    end
  end

  function api.running()
    local result = {}
    for _, workspace in ipairs(hollow.term.mux_tree()) do
      for _, tab in ipairs(workspace.tabs or {}) do
        for _, pane in ipairs(tab.panes or {}) do
          local has_status = #(pane.program_status or {}) > 0
          if has_status then
            program_commands[pane.id] = true
          end
          for _, record in ipairs(pane.program_status or {}) do
            if record.state == "working" or record.state == "blocked" then
              result[#result + 1] = {
                id = "program:" .. pane.id .. ":" .. (record.id or ""),
                kind = "program",
                app = record.app,
                program_id = record.id,
                level = record.state == "blocked" and "warn" or "info",
                pending = false,
                state = record.state,
                block_kind = record.kind,
                title = record.title ~= "" and record.title or record.app,
                message = record.message,
                progress = record.progress,
                pane_id = pane.id,
                pane_title = pane.title,
                workspace = workspace.name,
                cwd = pane.cwd,
              }
            end
          end
          if not has_status and not program_commands[pane.id] and pane.running then
            result[#result + 1] = {
              id = "command:" .. pane.id,
              kind = "program",
              app = "Command",
              level = "info",
              pending = false,
              state = "working",
              title = pane.running.command,
              pane_id = pane.id,
              pane_title = pane.title,
              workspace = workspace.name,
              cwd = pane.cwd,
            }
          end
        end
      end
    end
    return result
  end

  local function status_changed(event)
    local pane = event.pane
    if not pane then
      return
    end
    local previous = statuses[pane.id] or {}
    if #(pane.program_status or {}) > 0 then
      program_commands[pane.id] = true
    end
    local current = {}
    for _, record in ipairs(pane.program_status or {}) do
      local id = record.id or ""
      local old = previous[id]
      local same_state = old and old.state == record.state and old.kind == record.kind
      local entry = same_state and store:find(old.entry_id)
      if record.state == "blocked" or record.state == "done" or record.state == "error" then
        if not same_state then
          entry = context(pane)
          entry.kind = "program"
          entry.program_id = id
          entry.state = record.state
          entry.block_kind = record.kind
          entry.level = record.state == "error" and "error"
            or record.state == "done" and "success"
            or "warn"
          entry.timestamp_ms = now()
          entry.pending = background(pane)
          entry = store:append(entry)
        end
        if entry then
          entry.app = record.app
          entry.title = record.title ~= "" and record.title or record.app
          entry.message = record.message
        end
      end
      current[id] = { state = record.state, kind = record.kind, entry_id = entry and entry.id }
    end
    -- Inbox reflects live status, while History retains cleared/replaced reports.
    -- Scan retained entries too: older runtime versions could leave orphaned
    -- completion entries after the per-program cache had already moved on.
    for _, entry in ipairs(store.entries) do
      if entry.pending and entry.kind == "program" and entry.pane_id == pane.id then
        local live = current[entry.program_id or ""]
        if not live or live.entry_id ~= entry.id then
          api.dismiss(entry.id)
        end
      end
    end
    statuses[pane.id] = current
    changed()
  end

  hollow.events.on("activity:dismissed", function(event)
    hollow.ui.notify._dismiss_activity(event.id)
  end)
  hollow.events.on("term:program_status_changed", status_changed)
  hollow.events.on("term:command_started", function(event)
    if event.pane then
      program_commands[event.pane.id] = nil
    end
    changed()
  end)
  hollow.events.on("term:bell", function(event)
    local pane = event.pane
    if not pane then
      return
    end
    local key = "bell:" .. pane.id
    local entry = store:pending(key)
    if entry then
      entry.count = entry.count + 1
      entry.timestamp_ms = now()
    else
      entry = context(pane)
      entry.kind, entry.key, entry.title = "bell", key, "Terminal bell"
      entry.level, entry.timestamp_ms, entry.pending = "warn", now(), background(pane)
      store:append(entry)
    end
    changed()
  end)
  hollow.events.on("term:pane_closed", function(event)
    if not event.pane then
      return
    end
    statuses[event.pane.id] = nil
    program_commands[event.pane.id] = nil
    for _, entry in ipairs(store.entries) do
      if entry.pane_id == event.pane.id then
        entry.pane_closed = true
        if entry.kind == "program" then
          api.dismiss(entry.id)
        end
      end
    end
    changed()
  end)
  local function sync_statuses()
    for _, workspace in ipairs(hollow.term.mux_tree()) do
      for _, tab in ipairs(workspace.tabs or {}) do
        for _, pane in ipairs(tab.panes or {}) do
          status_changed({ pane = pane })
        end
      end
    end
  end
  hollow.events.on("gui:ready", sync_statuses)
  hollow.events.on("config:reloaded", sync_statuses)
end

return M
