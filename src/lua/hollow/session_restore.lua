-- Remembers persistent sessions between launches and reattaches them.
-- Local and WSL hosts are listed at startup; SSH hosts are never contacted
-- until the user asks. A session whose open outcome is uncertain is never
-- replaced by a fresh one, so a reachable owner is not duplicated.
local util = require("hollow.util")

local M = {}

M.max_entries = 64
M.file_name = "sessions.json"

local hollow
local host_api
-- Keys ("domain\0id") with an attach in flight, so restores never overlap.
local inflight = {}
local prompts = {}
local prompt_open = false
-- Lists, prompts, and attaches still running; each attach focuses its
-- workspace, so the last active session is refocused once this drops to 0.
local restoring = 0
local focus_target

local function key(domain, id)
  return domain .. "\0" .. id
end

local function path()
  return util.join_path(host_api.data_dir(), M.file_name)
end

local function valid_entry(entry)
  return type(entry) == "table"
    and type(entry.domain) == "string"
    and entry.domain ~= ""
    and type(entry.id) == "string"
    and entry.id ~= ""
    and #entry.id <= 128
    and (entry.host == nil or type(entry.host) == "string")
end

-- Read failures and corrupt files only forget sessions; they never raise.
local function load()
  local ok, decoded = pcall(function()
    local file = path()
    if not host_api.path_exists(file) then
      return nil
    end
    return hollow.json.decode(host_api.read_file(file))
  end)
  local entries, active = {}, nil
  if ok and type(decoded) == "table" and type(decoded.sessions) == "table" then
    for _, entry in ipairs(decoded.sessions) do
      if valid_entry(entry) then
        entries[#entries + 1] = { domain = entry.domain, id = entry.id, host = entry.host }
      end
    end
    if valid_entry(decoded.active) then
      active = { domain = decoded.active.domain, id = decoded.active.id }
    end
  end
  while #entries > M.max_entries do
    table.remove(entries, 1)
  end
  return entries, active
end

--- `active` is the session focused last.
local function save(entries, active)
  while #entries > M.max_entries do
    table.remove(entries, 1)
  end
  pcall(function()
    host_api.write_file(
      path(),
      hollow.json.encode({ version = 1, sessions = entries, active = active }) .. "\n"
    )
  end)
end

local function focus_restored()
  if restoring > 0 or focus_target == nil then
    return
  end
  local target = focus_target
  focus_target = nil
  for _, workspace in ipairs(hollow.term.workspaces()) do
    if workspace.session_id == target.id then
      if not workspace.is_active then
        hollow.term.switch_workspace(workspace.index)
      end
      return
    end
  end
end

local function busy(delta)
  restoring = restoring + delta
  focus_restored()
end

local function domain_config(domain)
  local domains = hollow.config.get("domains")
  local config = type(domains) == "table" and domains[domain] or nil
  return type(config) == "table" and config or nil
end

--- True when sessions in `domain` are remembered and restored.
function M.enabled(domain)
  local config = type(domain) == "string" and domain_config(domain)
  return config ~= nil and config.persist == true and config.restore ~= false
end

function M.remember(domain, id, host)
  if not M.enabled(domain) or not valid_entry({ domain = domain, id = id, host = host }) then
    return
  end
  local entries, active = load()
  for index = #entries, 1, -1 do
    if entries[index].domain == domain and entries[index].id == id then
      table.remove(entries, index)
    end
  end
  entries[#entries + 1] = { domain = domain, id = id, host = host }
  save(entries, active)
end

--- Record the focused session. Restores in progress focus their own
--- workspaces and must not overwrite the one to return to.
function M.activate(domain, id)
  if restoring > 0 or not M.enabled(domain) then
    return
  end
  local entries, active = load()
  if active and active.domain == domain and active.id == id then
    return
  end
  for _, entry in ipairs(entries) do
    if entry.domain == domain and entry.id == id then
      save(entries, { domain = domain, id = id })
      return
    end
  end
end

--- Forget `id`. A nil domain matches every domain.
function M.forget(domain, id)
  local entries, active = load()
  local changed = false
  for index = #entries, 1, -1 do
    local entry = entries[index]
    if entry.id == id and (domain == nil or entry.domain == domain) then
      table.remove(entries, index)
      changed = true
    end
  end
  if active and active.id == id and (domain == nil or active.domain == domain) then
    active = nil
  end
  if changed then
    save(entries, active)
  end
end

function M.entries()
  return load()
end

local function notify(message, opts)
  local ui = hollow.ui and hollow.ui.notify
  if ui and ui.show then
    ui.show(message, opts)
  end
end

local function next_prompt()
  if prompt_open or #prompts == 0 then
    return
  end
  local prompt = table.remove(prompts, 1)
  prompt_open = true
  local answered = false
  local function answer(value)
    if answered then
      return
    end
    answered = true
    prompt_open = false
    prompt.on_answer(value == true)
    next_prompt()
  end
  local ok = pcall(hollow.ui.confirm.open, {
    title = "Restore sessions",
    prompt = prompt.text,
    on_confirm = answer,
    on_cancel = function()
      answer(false)
    end,
  })
  if not ok then
    answer(false)
  end
end

local function ask(text, on_answer)
  prompts[#prompts + 1] = { text = text, on_answer = on_answer }
  next_prompt()
end

-- Restores one local/WSL domain. `fallback` creates a fresh session once the
-- owner confirmed nothing remembered survives and no outcome is uncertain.
local function restore_domain(domain, entries, fallback)
  local state = { pending = 0, restored = 0, uncertain = false, prompting = false }

  local function settle()
    if state.pending > 0 or state.prompting or not fallback then
      return
    end
    if state.restored == 0 and not state.uncertain then
      fallback = nil
      hollow.term.new_workspace({ domain = domain })
    end
  end

  local function attach(entry)
    local entry_key = key(domain, entry.id)
    if inflight[entry_key] then
      state.uncertain = true
      return
    end
    inflight[entry_key] = true
    state.pending = state.pending + 1
    busy(1)
    local ok = pcall(hollow.term.attach_session, entry.id, {
      domain = domain,
      trace_intent = "restore",
      on_complete = function(result)
        inflight[entry_key] = nil
        state.pending = state.pending - 1
        if result and result.success then
          state.restored = state.restored + 1
        elseif result and result.status == "session_not_found" then
          M.forget(domain, entry.id)
        elseif not result or result.outcome ~= "not_sent" then
          state.uncertain = true
        end
        settle()
        busy(-1)
      end,
    })
    if not ok then
      inflight[entry_key] = nil
      state.pending = state.pending - 1
      busy(-1)
    end
  end

  state.pending = 1
  busy(1)
  local ok, queued = pcall(hollow.term.list_sessions, {
    domain = domain,
    on_complete = function(result)
      state.pending = state.pending - 1
      if not (result and result.success and type(result.sessions) == "table") then
        state.uncertain = true
        notify("Could not list sessions in " .. domain .. "; nothing was restored.", {
          level = "warn",
          title = "Session restore",
        })
        busy(-1)
        return
      end
      local live = {}
      for _, session in ipairs(result.sessions) do
        if type(session) == "table" and type(session.id) == "string" then
          live[session.id] = session
        end
      end
      local elsewhere = {}
      for _, entry in ipairs(entries) do
        local session = live[entry.id]
        local moved = entry.host ~= nil and result.host ~= nil and entry.host ~= result.host
        if moved then
          -- Another host answers for this domain now; keep the entry for it.
          session = nil
        elseif session == nil then
          M.forget(domain, entry.id)
        elseif session.open then
          state.restored = state.restored + 1
        elseif session.attached then
          elsewhere[#elsewhere + 1] = entry
        else
          attach(entry)
        end
      end
      if #elsewhere > 0 then
        state.prompting = true
        busy(1)
        local noun = #elsewhere == 1 and "session is" or "sessions are"
        ask(
          string.format(
            "%d remembered %s in %s attached in another window. Take over?",
            #elsewhere,
            noun,
            domain
          ),
          function(take_over)
            state.prompting = false
            if take_over then
              for _, entry in ipairs(elsewhere) do
                attach(entry)
              end
            end
            settle()
            busy(-1)
          end
        )
      end
      settle()
      busy(-1)
    end,
  })
  if not ok or not queued then
    state.pending = state.pending - 1
    busy(-1)
    state.uncertain = true
    notify("Could not list sessions in " .. domain .. "; nothing was restored.", {
      level = "warn",
      title = "Session restore",
    })
  end
end

local function group(entries, only_domain)
  local order, groups = {}, {}
  for _, entry in ipairs(entries) do
    if (only_domain == nil or entry.domain == only_domain) and M.enabled(entry.domain) then
      if groups[entry.domain] == nil then
        groups[entry.domain] = {}
        order[#order + 1] = entry.domain
      end
      table.insert(groups[entry.domain], entry)
    end
  end
  return order, groups
end

local function local_kind(kind)
  return kind == "local" or kind == "wsl"
end

--- Reattach remembered sessions. Never creates a fresh session.
--- `opts.domain` limits the restore to one domain.
function M.restore(opts)
  opts = opts or {}
  local pty = require("hollow.host.pty")
  local order, groups = group(load(), opts.domain)
  for _, domain in ipairs(order) do
    if pty.session_kind(domain) ~= nil then
      restore_domain(domain, groups[domain], nil)
    end
  end
  return #order
end

--- Startup hook called once by the app. Returns true when Lua took over
--- creating the persistent default domain's first session.
function M.startup(default_domain)
  local pty = require("hollow.host.pty")
  local entries, active = load()
  local order, groups = group(entries, nil)
  focus_target = active
  local took_over = false
  local remote = 0
  for _, domain in ipairs(order) do
    local kind = pty.session_kind(domain)
    if local_kind(kind) then
      local fallback = domain == default_domain or nil
      took_over = took_over or fallback == true
      restore_domain(domain, groups[domain], fallback)
    elseif kind ~= nil then
      remote = remote + #groups[domain]
    end
  end
  if remote > 0 then
    hollow.defer(function()
      notify(
        string.format(
          "%d remembered remote session%s can be restored.",
          remote,
          remote == 1 and "" or "s"
        ),
        {
          level = "info",
          title = "Session restore",
          action = {
            label = "Restore",
            fn = function()
              M.restore()
            end,
          },
        }
      )
    end)
  end
  focus_restored()
  return took_over
end

function M.setup(hollow_ref, host_api_ref)
  hollow = hollow_ref
  host_api = host_api_ref

  hollow.events.on("workspace:new", function(event)
    local workspace = event and event.workspace
    if type(workspace) ~= "table" or type(workspace.session_id) ~= "string" then
      return
    end
    local domain = workspace.domain
    if type(domain) ~= "string" or domain == "" then
      domain = hollow.config.get("default_domain")
    end
    M.remember(domain, workspace.session_id, workspace.session_host)
  end)

  hollow.events.on("workspace:changed", function(event)
    local workspace = event and event.workspace
    if type(workspace) == "table" and type(workspace.session_id) == "string" then
      M.activate(workspace.domain or hollow.config.get("default_domain"), workspace.session_id)
    end
  end)

  hollow.events.on("workspace:closed", function(event)
    if event and event.session_ended == true and type(event.session_id) == "string" then
      M.forget(nil, event.session_id)
    end
  end)

  local kill_session = hollow.term.kill_session
  function hollow.term.kill_session(session_id, opts)
    if opts ~= nil and type(opts) ~= "table" then
      return kill_session(session_id, opts)
    end
    local wrapped = {}
    for field, value in pairs(opts or {}) do
      wrapped[field] = value
    end
    local on_complete = wrapped.on_complete
    if on_complete ~= nil and type(on_complete) ~= "function" then
      return kill_session(session_id, opts)
    end
    wrapped.on_complete = function(result)
      if result and result.success then
        M.forget(result.domain or wrapped.domain, session_id)
      end
      if on_complete then
        on_complete(result)
      end
    end
    return kill_session(session_id, wrapped)
  end

  function hollow.term.restore_sessions(opts)
    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.restore_sessions(opts) expects opts to be a table or nil")
    end
    if opts and opts.domain ~= nil and type(opts.domain) ~= "string" then
      error("hollow.term.restore_sessions(opts) expects opts.domain to be a string")
    end
    return M.restore(opts)
  end

  function hollow.term.remembered_sessions()
    return load()
  end

  hollow._session_startup = M.startup
end

return M
