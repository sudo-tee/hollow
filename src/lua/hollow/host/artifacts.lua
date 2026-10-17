-- Installed-release discovery only: no CWD, PATH, user cache, or network search.
local M = {}
local async = require("hollow.async")
local paths = { ["linux-x86_64/hollow-agent"] = "x86_64", ["linux-aarch64/hollow-agent"] = "aarch64" }

local function unavailable(message)
  return { code = "agent_install_unavailable", message = message .. "; configure artifacts, agent_dir, or agent_path" }
end

function M.absolute(path)
  return type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
    and (path:sub(1, 1) == "/" or path:match("^[A-Za-z]:[/\\]") ~= nil or path:match("^\\\\") ~= nil)
end

local function join(root, suffix)
  if root:sub(-1) == "/" then return root .. suffix end
  return root .. "/" .. suffix
end

local function parse(bytes, root)
  if type(bytes) ~= "string" or #bytes == 0 or #bytes > 4096 or bytes:sub(-1) ~= "\n" then
    return nil, unavailable("invalid bundled SHA256SUMS")
  end
  local result, count = {}, 0
  for line in bytes:gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local digest, path = line:match("^(%x+)  (.+)$")
    local arch = path and paths[path]
    if not arch or #digest ~= 64 or result[arch] then return nil, unavailable("invalid bundled SHA256SUMS record") end
    result[arch] = { path = join(root, path), sha256 = digest:lower() }
    count = count + 1
  end
  if count ~= 2 then return nil, unavailable("bundled SHA256SUMS must describe both supported agents") end
  return result
end

-- Return copied configuration, never a mutable global cache. All filesystem
-- work runs through the native-local host's asynchronous operations.
function M.discover(host, directory)
  if directory ~= nil and not M.absolute(directory) then error("agent_dir must be a client-native absolute path", 2) end
  local resolve, reject
  local promise = async.promise(function(r, j) resolve, reject = r, j end)
  local active, settled = nil, false
  local function fail(err)
    if settled then return end
    settled = true
    reject(type(err) == "table" and err.code and err or unavailable(tostring(err)))
  end
  local function observe(start, next_step, failed)
    if settled then return end
    local ok, p = pcall(start)
    if not ok then fail(p); return end
    active = p
    p:next(function(value)
      if active == p then active = nil end
      if settled then return end
      local success, err = pcall(next_step, value)
      if not success then fail(err) end
    end, function(err)
      if active == p then active = nil end
      if settled then return end
      if failed then
        local success, thrown = pcall(failed, err)
        if not success then fail(thrown) end
      else fail(err) end
    end)
  end
  function promise:cancel()
    if settled then return false end
    settled = true
    if active and active.cancel then pcall(active.cancel, active) end
    reject({ code = "cancelled", message = "agent discovery cancelled" })
    return true
  end
  local function validate(artifacts)
    local order = { "x86_64", "aarch64" }
    local function stat(index)
      if index > #order then settled = true; resolve(artifacts); return end
      observe(function() return host.fs.stat(artifacts[order[index]].path) end, function(value)
        if type(value) ~= "table" or value.kind ~= "file" or type(value.size) ~= "number" or value.size <= 0 then
          fail(unavailable("bundled agent is not a nonempty regular file")); return
        end
        stat(index + 1)
      end, function() fail(unavailable("bundled agent file is unavailable")) end)
    end
    stat(1)
  end
  local function scan(roots, index)
    local root = roots[index]
    if not root then fail(unavailable("no installed agent bundle found beside executable")); return end
    observe(function() return host.fs.read(join(root, "SHA256SUMS"), { limit = 4096 }) end, function(value)
      if type(value) ~= "table" or value.eof ~= true then fail(unavailable("bundled SHA256SUMS exceeds size limit")); return end
      local artifacts, err = parse(value.bytes, root)
      if not artifacts then fail(err); return end
      validate(artifacts)
    end, function(err)
      if type(err) == "table" and err.code == "not_found" then scan(roots, index + 1)
      else fail(unavailable("cannot read installed agent manifest")) end
    end)
  end
  if directory then scan({ directory }, 1) else
    observe(function() return host:info() end, function(info)
      if type(info) ~= "table" or not M.absolute(info.executable_dir) then
        fail(unavailable("native executable directory is unavailable")); return
      end
      local roots = { join(info.executable_dir, "agents") }
      -- Only a conventional prefix/bin layout may use a sibling agents tree.
      -- A flat release must not trust arbitrary assets outside its directory.
      local leaf
      if info.os == "windows" then
        leaf = info.executable_dir:gsub("[/\\]+$", ""):match("([^/\\]+)$")
      else
        leaf = info.executable_dir:gsub("/+$", ""):match("([^/]+)$")
      end
      if leaf == "bin" or (info.os == "windows" and leaf and leaf:lower() == "bin") then
        roots[#roots + 1] = join(info.executable_dir, "../agents")
      end
      scan(roots, 1)
    end)
  end
  return promise
end

return M
