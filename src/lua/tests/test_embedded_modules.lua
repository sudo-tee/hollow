local harness = require("tests.harness")

describe("embedded Lua module registry", function()
  it("boots core without filesystem module searchers", function()
    local file = assert(io.open("src/lua_bridge.zig", "r"))
    local registry = file:read("*a")
    file:close()
    local previous = {}
    local function preload(name, path)
      previous[name] = { value = package.preload[name] }
      package.preload[name] = assert(loadfile(path))
    end
    for name, path in registry:gmatch('%.name%s*=%s*"([^"]+)"%s*,%s*%.source%s*=%s*@embedFile%("([^"]+)"%)') do
      preload(name, "src/" .. path)
    end
    preload("core", "src/lua/core.lua")
    local loaders = package.loaders
    package.loaders = { loaders[1] } -- package.preload only, like packaged startup
    local ok, result = pcall(harness.boot)
    package.loaders = loaders
    for name, original in pairs(previous) do package.preload[name] = original.value end
    assert.is_true(ok, tostring(result))
    assert.is_table(result.hollow.ui.workspace)
    assert.is_function(require("hollow.workspace.hosts").acquire)
  end)
end)
