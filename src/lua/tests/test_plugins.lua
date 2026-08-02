package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("plugins test suite", function()
  local env
  local hollow
  local recorded

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  describe("plugin setup", function()
    it("loads local plugins", function()
      local repo_root = assert(os.getenv("PWD"), "PWD should be set for runtime tests")
      local plugin_root = repo_root .. "/src/lua/tests/fixtures/plugins/localplugin"
      recorded.dirs[plugin_root] = true
      recorded.dirs[plugin_root .. "/lua"] = true
      recorded.dirs[plugin_root .. "/lua/localplugin"] = true
      recorded.dirs[plugin_root .. "/hollow_plugin"] = true
      recorded.files[plugin_root .. "/hollow_plugin/localplugin.lua"] = true
      _G.__plugin_autoloaded = nil
      _G.__plugin_setup_opts = nil
      hollow.plugins.setup({
        plugins = {
          { plugin_root, opts = { greeting = "hello" } },
        },
      })
    end)

    it("sources autoload files", function()
      harness.assert_true(_G.__plugin_autoloaded == true, "plugin autoload files should be sourced")
    end)

    it("passes opts to plugin setup", function()
      harness.assert_equal(
        _G.__plugin_setup_opts.greeting,
        "hello",
        "plugin setup should receive opts"
      )
    end)

    it("normalizes local plugin specs", function()
      local repo_root = assert(os.getenv("PWD"), "PWD should be set for runtime tests")
      local plugin_root = repo_root .. "/src/lua/tests/fixtures/plugins/localplugin"
      harness.assert_equal(
        hollow.plugins._specs[1].source,
        "local",
        "plugin setup should normalize local plugin specs"
      )
      harness.assert_equal(
        hollow.plugins._specs[1].path,
        plugin_root,
        "plugin setup should keep absolute local plugin paths"
      )
    end)
  end)
end)
