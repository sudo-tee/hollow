-- Persistent sessions shown in the workspace switcher. Local and WSL hosts
-- are listed whenever the switcher opens; SSH hosts only when asked, so
-- opening the switcher never starts remote traffic.
local M = {}

---@type Hollow
local hollow = _G.hollow

local domains = {}
local revision = 0

local function changed()
  revision = revision + 1
  hollow.events.emit("workspace:items_changed", { revision = revision })
end

local function local_kind(kind)
  return kind == "local" or kind == "wsl"
end

--- Persist domains that can own sessions, sorted, with their host kind.
local function persist_domains()
  local configured = hollow.config.get("domains")
  local pty = require("hollow.host.pty")
  local out = {}
  if type(configured) ~= "table" then
    return out
  end
  for name, config in pairs(configured) do
    if type(name) == "string" and type(config) == "table" and config.persist == true then
      local kind = pty.session_kind(name)
      if kind ~= nil then
        out[#out + 1] = { name = name, kind = kind }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

local function domain_state(name)
  domains[name] = domains[name] or { status = "idle", sessions = {}, pending = {} }
  return domains[name]
end

--- List one domain's sessions. A list already in flight is not repeated.
function M.refresh(name)
  local entry = domain_state(name)
  if entry.status == "loading" then
    return
  end
  entry.status = "loading"
  entry.error = nil
  local ok, queued, err = pcall(hollow.term.list_sessions, {
    domain = name,
    on_complete = function(result)
      if result and result.success and type(result.sessions) == "table" then
        entry.status = "ready"
        entry.sessions = result.sessions
        entry.host = result.host
      else
        entry.status = "failed"
        entry.error = result and (result.error or result.status) or "unknown error"
      end
      changed()
    end,
  })
  if not ok or not queued then
    entry.status = "failed"
    entry.error = tostring(ok and err or queued)
  end
  changed()
end

--- True when some domain can list persistent sessions.
function M.enabled()
  return #persist_domains() > 0
end

--- Called when the switcher opens: list local hosts and re-list any remote
--- host the user already loaded.
function M.refresh_on_open()
  for _, domain in ipairs(persist_domains()) do
    local entry = domains[domain.name]
    if local_kind(domain.kind) or (entry and entry.status ~= "idle") then
      M.refresh(domain.name)
    end
  end
end

--- Re-list every host already loaded, plus local ones.
function M.refresh_all()
  M.refresh_on_open()
end

local function forget_row(domain, id)
  local entry = domains[domain]
  if not entry then
    return
  end
  for index = #entry.sessions, 1, -1 do
    if entry.sessions[index].id == id then
      table.remove(entry.sessions, index)
    end
  end
  changed()
end

local function first_cwd(session)
  local pane = type(session.panes) == "table" and session.panes[1] or nil
  return type(pane) == "table" and type(pane.cwd) == "string" and pane.cwd ~= "" and pane.cwd or nil
end

local function session_item(domain, session)
  local panes = type(session.panes) == "table" and #session.panes or 0
  local exited = 0
  for _, pane in ipairs(type(session.panes) == "table" and session.panes or {}) do
    if pane.exited then
      exited = exited + 1
    end
  end
  local badge = session.attached and "attached elsewhere"
    or (panes == 1 and "1 pane" or (panes .. " panes"))
  if exited > 0 then
    badge = badge .. ", " .. exited .. " exited"
  end
  local name = type(session.name) == "string" and session.name ~= "" and session.name
    or ("session " .. session.id:sub(1, 8))
  return {
    id = "session:" .. domain .. ":" .. session.id,
    name = name,
    cwd = first_cwd(session) or "Detached session",
    domain = domain,
    source = "session",
    is_open = false,
    is_active = false,
    has_bell = false,
    session_id = session.id,
    session_attached = session.attached == true,
    session_badge = badge,
  }
end

local function status_item(domain, entry)
  local name, badge
  if entry.status == "loading" then
    name, badge = "Loading sessions…", "loading"
  elseif entry.status == "failed" then
    name, badge = "Sessions unavailable", "retry"
  else
    name, badge = "Load sessions", "remote"
  end
  return {
    id = "session-load:" .. domain,
    name = name,
    cwd = entry.status == "failed" and entry.error or ("Persistent sessions on " .. domain),
    domain = domain,
    source = "session_load",
    is_open = false,
    is_active = false,
    has_bell = false,
    session_badge = badge,
  }
end

--- Switcher rows: detached sessions, then load/retry rows for hosts that are
--- not listed yet or failed.
function M.items()
  local items = {}
  for _, domain in ipairs(persist_domains()) do
    local entry = domain_state(domain.name)
    if entry.status == "ready" then
      for _, session in ipairs(entry.sessions) do
        if
          type(session) == "table"
          and type(session.id) == "string"
          and not session.open
          and not entry.pending[session.id]
        then
          items[#items + 1] = session_item(domain.name, session)
        end
      end
    elseif entry.status == "failed" or not local_kind(domain.kind) then
      items[#items + 1] = status_item(domain.name, entry)
    end
  end
  return items
end

local function attach(item)
  local entry = domain_state(item.domain)
  entry.pending[item.session_id] = true
  changed()
  local ok = pcall(hollow.term.attach_session, item.session_id, {
    domain = item.domain,
    on_complete = function(result)
      entry.pending[item.session_id] = nil
      if result and result.success then
        forget_row(item.domain, item.session_id)
      elseif result and result.status == "session_not_found" then
        forget_row(item.domain, item.session_id)
      else
        changed()
      end
    end,
  })
  if not ok then
    entry.pending[item.session_id] = nil
    changed()
  end
end

--- Enter on a session row. Taking over another window's session asks first.
function M.activate(item)
  if item.source == "session_load" then
    M.refresh(item.domain)
    return false
  end
  if not item.session_attached then
    attach(item)
    return true
  end
  hollow.ui.confirm.open({
    title = "Take over session",
    prompt = item.name .. " is attached in another window. Take it over?",
    on_confirm = function(value)
      if value == true then
        attach(item)
      end
    end,
  })
  return true
end

--- Kill a session row after confirmation.
function M.kill(item)
  hollow.ui.confirm.open({
    title = "Kill session",
    prompt = "Kill " .. item.name .. " and every process in it?",
    on_confirm = function(value)
      if value ~= true then
        return
      end
      local queued, err = hollow.term.kill_session(item.session_id, {
        domain = item.domain,
        on_complete = function(result)
          if result and result.success then
            forget_row(item.domain, item.session_id)
            return
          end
          local reason = result and (result.remote or result.error) or "unknown error"
          if result and result.outcome == "uncertain" then
            reason = reason .. "; it may have ended, refresh to check"
          end
          hollow.ui.notify.show("Could not kill " .. item.name .. ": " .. tostring(reason), {
            level = "warn",
            title = "Session",
          })
          M.refresh(item.domain)
        end,
      })
      if not queued then
        hollow.ui.notify.show("Could not kill " .. item.name .. ": " .. tostring(err), {
          level = "warn",
          title = "Session",
        })
      end
    end,
  })
end

--- Test hook: drop cached host state.
function M._reset()
  domains = {}
  revision = 0
end

return M
