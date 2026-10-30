local harness = require("tests.harness")

describe("embedded Lua module registry", function()
  it("boots core without filesystem module searchers", function()
    local previous = {}
    local function preload(name, path)
      previous[name] = { value = package.preload[name] }
      package.preload[name] = assert(loadfile(path))
    end
    -- Same rule as build.zig and lua_bridge.zig: every file under src/lua/hollow,
    -- named by its path, with init.lua also registered under its folder name.
    local files = assert(io.popen("find src/lua/hollow -name '*.lua'"))
    local count = 0
    for path in files:lines() do
      local name = path:gsub("^src/lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
      preload(name, path)
      if name:match("%.init$") then
        preload(name:gsub("%.init$", ""), path)
      end
      count = count + 1
    end
    files:close()
    assert.is_true(count > 100, "expected the hollow module tree")
    preload("core", "src/lua/core.lua")
    local loaders = package.loaders
    package.loaders = { loaders[1] } -- package.preload only, like packaged startup
    local ok, result = pcall(harness.boot)
    package.loaders = loaders
    for name, original in pairs(previous) do
      package.preload[name] = original.value
    end
    assert.is_true(ok, tostring(result))
    assert.is_table(result.hollow.ui.workspace)
    local shape = result.hollow.shape
    local schema = shape.strict_object({ count = shape.integer():default(2) })
    assert.same({ count = 2 }, schema:parse({}))
    assert.is_function(require("hollow.workspace.hosts").acquire)
  end)
end)
