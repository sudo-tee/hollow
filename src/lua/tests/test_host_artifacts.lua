local harness = require("tests.harness")

describe("hollow.host.artifacts", function()
  local env
  local executable_dir = "/opt/hollow"
  local root = executable_dir .. "/agents"
  local hash_x = string.rep("A", 64)
  local hash_a = string.rep("b", 64)

  local function manifest(x, a)
    return (x or hash_x) .. "  linux-x86_64/hollow-agent\n"
      .. (a or hash_a) .. "  linux-aarch64/hollow-agent\n"
  end

  local function fulfilled(value)
    return require("hollow.async").promise(function(resolve) resolve(value) end)
  end

  local function rejected(err)
    return require("hollow.async").promise(function(_, reject) reject(err) end)
  end

  local function fixture(config)
    config = config or {}
    local calls = { info = 0, reads = {}, stats = {} }
    local host = { fs = {} }
    function host:info()
      calls.info = calls.info + 1
      return config.info_promise or fulfilled(config.info or { executable_dir = executable_dir })
    end
    function host.fs.read(path, opts)
      calls.reads[#calls.reads + 1] = { path = path, opts = opts }
      if config.pending_read then return config.pending_read end
      local value = config.files and config.files[path]
      if value == nil then return rejected({ code = "not_found", message = "missing" }) end
      return fulfilled(value)
    end
    function host.fs.stat(path)
      calls.stats[#calls.stats + 1] = path
      local value = config.stat and config.stat[path]
      if value == nil then value = { kind = "file", size = 1 } end
      if value == false then return rejected({ code = "not_found", message = "missing" }) end
      return fulfilled(value)
    end
    local info_dir = config.info and config.info.executable_dir or executable_dir
    local adjacent = info_dir .. (info_dir:sub(-1) == "/" and "" or "/") .. "agents"
    local default_files = {
      [adjacent .. "/SHA256SUMS"] = { bytes = manifest(), eof = true },
      [info_dir .. "/../agents/SHA256SUMS"] = { bytes = manifest(), eof = true },
    }
    config.files = config.files or default_files
    return host, calls
  end

  before_each(function() env = harness.boot() end)

  it("discovers two verified agents beneath executable directory", function()
    local host, calls = fixture()
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("fulfilled", p:status())
    assert.are.same({ path = root .. "/linux-x86_64/hollow-agent", sha256 = hash_x:lower() }, p:value().x86_64)
    assert.are.same({ path = root .. "/linux-aarch64/hollow-agent", sha256 = hash_a }, p:value().aarch64)
    assert.are.same({ limit = 4096 }, calls.reads[1].opts)
  end)

  it("accepts reversed records, CRLF, and uppercase digests", function()
    local host = fixture({ files = { [root .. "/SHA256SUMS"] = { bytes = hash_a:upper() .. "  linux-aarch64/hollow-agent\r\n" .. hash_x .. "  linux-x86_64/hollow-agent\r\n", eof = true } } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("fulfilled", p:status())
    assert.are.equal(hash_a, p:value().aarch64.sha256)
  end)

  it("falls back to prefix agents only for a bin layout and missing adjacent manifest", function()
    local bin = executable_dir .. "/bin"
    local host, calls = fixture({ info = { executable_dir = bin }, files = { [bin .. "/../agents/SHA256SUMS"] = { bytes = manifest(), eof = true } } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("fulfilled", p:status())
    assert.are.equal(bin .. "/../agents/linux-x86_64/hollow-agent", p:value().x86_64.path)
    assert.are.equal(2, #calls.reads)
  end)

  it("never searches outside a flat release directory", function()
    local host, calls = fixture({ files = { [executable_dir .. "/../agents/SHA256SUMS"] = { bytes = manifest(), eof = true } } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("rejected", p:status())
    assert.are.equal(1, #calls.reads)
  end)

  it("does not interpret POSIX backslash bytes as a bin directory separator", function()
    local dir = "/opt/bin\\"
    local host, calls = fixture({ info = { os = "linux", executable_dir = dir }, files = {
      [dir .. "/../agents/SHA256SUMS"] = { bytes = manifest(), eof = true },
    } })
    assert.are.equal("rejected", require("hollow.host.artifacts").discover(host):status())
    assert.are.equal(1, #calls.reads)
  end)

  it("recognizes native Windows bin directory separators", function()
    local dir = "C:\\hollow\\bin"
    local host = fixture({ info = { os = "windows", executable_dir = dir }, files = {
      [dir .. "/../agents/SHA256SUMS"] = { bytes = manifest(), eof = true },
    } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("fulfilled", p:status())
    assert.are.equal(dir .. "/../agents/linux-x86_64/hollow-agent", p:value().x86_64.path)
  end)

  it("does not fall back when adjacent manifest exists but is corrupt", function()
    local host, calls = fixture({ files = {
      [root .. "/SHA256SUMS"] = { bytes = "bad\n", eof = true },
      [executable_dir .. "/../agents/SHA256SUMS"] = { bytes = manifest(), eof = true },
    } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("rejected", p:status())
    assert.are.equal("agent_install_unavailable", p:error().code)
    assert.are.equal(1, #calls.reads)
  end)

  it("uses explicit agent directory exclusively and skips host info", function()
    local directory = "/bundle"
    local host, calls = fixture({ files = { [directory .. "/SHA256SUMS"] = { bytes = manifest(), eof = true } } })
    local p = require("hollow.host.artifacts").discover(host, directory)
    assert.are.equal("fulfilled", p:status())
    assert.are.equal(0, calls.info)
    assert.are.equal(directory .. "/linux-aarch64/hollow-agent", p:value().aarch64.path)
    assert.are.equal(1, #calls.reads)
  end)

  it("rejects invalid explicit agent directory before host effects", function()
    local host, calls = fixture()
    assert.has_error(function() require("hollow.host.artifacts").discover(host, "relative") end)
    assert.are.equal(0, calls.info)
    assert.are.equal(0, #calls.reads)
    assert.are.equal(0, #calls.stats)
  end)

  it("requires executable directory info to be absolute", function()
    local host = fixture({ info = { executable_dir = "relative" } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("rejected", p:status())
    assert.are.equal("agent_install_unavailable", p:error().code)
  end)

  it("rejects malformed manifest records", function()
    local invalid = {
      "",
      hash_x .. "  linux-x86_64/hollow-agent\n" .. hash_a .. "  linux-aarch64/hollow-agent\nextra\n",
      hash_x .. "  ../hollow-agent\n" .. hash_a .. "  linux-aarch64/hollow-agent\n",
      hash_x .. "  /linux-x86_64/hollow-agent\n" .. hash_a .. "  linux-aarch64/hollow-agent\n",
      hash_x .. "  ..\\linux-x86_64\\hollow-agent\n" .. hash_a .. "  linux-aarch64/hollow-agent\n",
      hash_x .. "  linux-x86_64/hollow-agent\n" .. hash_x .. "  linux-x86_64/hollow-agent\n",
      hash_x .. "  linux-x86_64/hollow-agent\n\n" .. hash_a .. "  linux-aarch64/hollow-agent\n",
      hash_x .. "  linux-x86_64/hollow-agent\0\n" .. hash_a .. "  linux-aarch64/hollow-agent\n",
      string.rep("a", 63) .. "  linux-x86_64/hollow-agent\n" .. hash_a .. "  linux-aarch64/hollow-agent\n",
      hash_x .. "  linux-x86_64/hollow-agent\n",
    }
    for _, bytes in ipairs(invalid) do
      local host = fixture({ files = { [root .. "/SHA256SUMS"] = { bytes = bytes, eof = true } } })
      local p = require("hollow.host.artifacts").discover(host)
      assert.are.equal("rejected", p:status())
      assert.are.equal("agent_install_unavailable", p:error().code)
    end
  end)

  it("rejects a truncated manifest even if its records look valid", function()
    local host = fixture({ files = { [root .. "/SHA256SUMS"] = { bytes = manifest(), eof = false } } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("rejected", p:status())
    assert.is_truthy(p:error().message:find("size limit", 1, true))
  end)

  it("rejects empty, directory, and symlink stat results", function()
    for _, value in ipairs({ { kind = "file", size = 0 }, { kind = "directory", size = 1 }, { kind = "symlink", size = 1 } }) do
      local host = fixture({ stat = { [root .. "/linux-x86_64/hollow-agent"] = value } })
      local p = require("hollow.host.artifacts").discover(host)
      assert.are.equal("rejected", p:status())
      assert.is_truthy(p:error().message:find("nonempty regular file", 1, true))
    end
  end)

  it("maps missing artifact stat to structured installation failure", function()
    local path = root .. "/linux-x86_64/hollow-agent"
    local host = fixture({ stat = { [path] = false } })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("rejected", p:status())
    assert.are.equal("agent_install_unavailable", p:error().code)
    assert.is_truthy(p:error().message:find("file is unavailable", 1, true))
  end)

  it("preserves absolute paths byte-for-byte and uses forward-slash joins", function()
    for _, dir in ipairs({ "/release/", "/line\nbreak\\part\\", "C:\\release\\", "\\\\server\\share\\release" }) do
      local host, calls = fixture({ info = { executable_dir = dir } })
      local p = require("hollow.host.artifacts").discover(host)
      assert.are.equal("fulfilled", p:status())
      assert.are.equal(dir .. (dir:sub(-1) == "/" and "" or "/") .. "agents/linux-x86_64/hollow-agent", p:value().x86_64.path)
      assert.are.equal(dir .. (dir:sub(-1) == "/" and "" or "/") .. "agents/SHA256SUMS", calls.reads[1].path)
    end
  end)

  it("forwards cancellation to one pending read and ignores late completion", function()
    local resolve, cancels = nil, 0
    local pending = require("hollow.async").promise(function(r) resolve = r end)
    function pending:cancel() cancels = cancels + 1 end
    local host = fixture({ pending_read = pending })
    local p = require("hollow.host.artifacts").discover(host)
    assert.are.equal("pending", p:status())
    assert.is_true(p:cancel())
    assert.is_false(p:cancel())
    assert.are.equal(1, cancels)
    resolve({ bytes = manifest(), eof = true })
    assert.are.equal("rejected", p:status())
    assert.are.equal("cancelled", p:error().code)
  end)

  it("returns independent mutable maps for independent discoveries", function()
    local host = fixture()
    local first = require("hollow.host.artifacts").discover(host):value()
    local second = require("hollow.host.artifacts").discover(host):value()
    first.x86_64.path = "/mutated"
    first.aarch64.sha256 = "changed"
    assert.are.not_equal(first, second)
    assert.are.equal(root .. "/linux-x86_64/hollow-agent", second.x86_64.path)
    assert.are.equal(hash_a, second.aarch64.sha256)
  end)
end)
