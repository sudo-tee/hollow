package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("workspace test suite", function()
  local env
  local hollow
  local recorded
  local host_api
  local flush_deferred
  local get_gui_ready_handler

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    host_api = env.host_api
    flush_deferred = env.flush_deferred
    get_gui_ready_handler = env.get_gui_ready_handler
  end)

  describe("workspace bootstrap", function()
    it("sets workspace default cwd", function()
      hollow.workspace.bootstrap({
        name = "proj",
        tabs = {
          {
            name = "editor",
            panes = {
              { cwd = ".", command = "nvim" },
              { cwd = "server", command = "npm run dev", size = 0.25 },
            },
          },
        },
      }, { base_dir = "/tmp/project" })
      flush_deferred()
      harness.assert_equal(
        recorded.workspace_default_cwd,
        "/tmp/project",
        "workspace bootstrap should set workspace default cwd"
      )
    end)

    it("creates split panes with commands", function()
      harness.assert_equal(
        recorded.split_pane.command,
        "npm run dev",
        "workspace bootstrap should create split panes"
      )
    end)

    it("maps pane size to split ratio", function()
      harness.assert_equal(
        recorded.split_pane.ratio,
        0.25,
        "workspace bootstrap should map pane size to split ratio"
      )
    end)

    it("creates one split for a two-pane tab", function()
      harness.assert_equal(
        #recorded.split_pane_calls,
        1,
        "workspace bootstrap should create one split for a two-pane tab"
      )
    end)
  end)

  describe("main pane focus", function()
    it("focuses the pane marked main", function()
      hollow.workspace.bootstrap({
        tabs = {
          {
            panes = {
              { command = "nvim" },
              { command = "npm run dev", main = true },
            },
          },
        },
      })
      flush_deferred()
      harness.assert_equal(
        recorded.focus_pane_by_id,
        103,
        "workspace bootstrap should focus the pane marked main"
      )
    end)

    it("marks the focused pane as main on export", function()
      local exported_main = hollow.workspace.export_current()
      harness.assert_equal(
        exported_main.tabs[1].panes[3].main,
        true,
        "workspace export should mark the focused pane as main"
      )
    end)
  end)

  describe("linear splits", function()
    it("creates each linear split in sequence", function()
      local split_count_before_linear = #recorded.split_pane_calls
      hollow.workspace.bootstrap({
        tabs = {
          {
            panes = {
              { command = "nvim", domain = "wsl" },
              { direction = "horizontal", domain = "wsl" },
              { direction = "vertical", domain = "wsl" },
            },
          },
        },
      })
      flush_deferred()
      harness.assert_equal(
        #recorded.split_pane_calls - split_count_before_linear,
        2,
        "workspace bootstrap should create each linear split in sequence"
      )
      harness.assert_equal(
        recorded.split_pane_calls[split_count_before_linear + 1].direction,
        "horizontal",
        "workspace bootstrap should preserve the second pane split direction"
      )
      harness.assert_equal(
        recorded.split_pane_calls[split_count_before_linear + 2].direction,
        "vertical",
        "workspace bootstrap should preserve the third pane split direction"
      )
    end)
  end)

  describe("project-local paths", function()
    it("resolves the project-local path", function()
      hollow.term.set_pane_tags({ "test-runner", "primary" }, 101)
      hollow.term.focus_pane_by_id(101)
      harness.assert_equal(
        hollow.workspace.project_local_path("/tmp/project"),
        "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json",
        "workspace helper should resolve project-local path"
      )
    end)
  end)

  describe("auto bootstrap", function()
    it("requires explicit always mode", function()
      recorded.files["\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json"] =
        "__workspace_spec__"
      harness.assert_equal(
        hollow.workspace.resolve_auto_bootstrap_path(),
        nil,
        "workspace auto bootstrap should require explicit always mode"
      )
    end)

    it("ignores startup auto-bootstrap mode for explicit project bootstrap", function()
      harness.assert_true(
        hollow.workspace.bootstrap_project("/tmp/project"),
        "explicit project bootstrap should ignore startup auto-bootstrap mode"
      )
    end)

    it("prefers project-local workspace files in always mode", function()
      hollow.config.set({ workspace = { auto_bootstrap = "always", default_layout = "default" } })
      harness.assert_equal(
        hollow.workspace.resolve_auto_bootstrap_path(),
        "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json",
        "auto bootstrap should prefer project-local workspace files"
      )
    end)

    it("runs on gui ready using the active pane cwd", function()
      local gui_ready = get_gui_ready_handler()
      harness.assert_true(type(gui_ready) == "function", "core should register a gui ready handler")
      recorded.files["\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json"] =
        "__workspace_spec__"
      gui_ready()
      harness.assert_equal(
        recorded.new_workspace.cwd,
        "/tmp/project",
        "auto bootstrap should run on gui ready using the active pane cwd"
      )
    end)
  end)

  describe("workspace export", function()
    it("includes the active workspace name", function()
      local exported = hollow.workspace.export_current()
      harness.assert_equal(
        exported.name,
        "main",
        "workspace export should include active workspace name"
      )
    end)

    it("includes pane cwd", function()
      local exported = hollow.workspace.export_current()
      harness.assert_equal(
        exported.tabs[1].panes[1].cwd,
        "/tmp/project",
        "workspace export should include pane cwd"
      )
    end)

    it("includes pane tags", function()
      local exported = hollow.workspace.export_current()
      harness.assert_equal(
        exported.tabs[1].panes[1].tags[1],
        "primary",
        "workspace export should include pane tags"
      )
      harness.assert_equal(
        exported.tabs[1].panes[1].tags[2],
        "test-runner",
        "workspace export should preserve pane tags"
      )
    end)
  end)
end)
