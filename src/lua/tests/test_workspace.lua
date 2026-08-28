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
              { command = "horizontal-pane", direction = "horizontal", size = 0.25, domain = "wsl" },
              { command = "vertical-pane", direction = "vertical", size = 0.6, domain = "wsl" },
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

      local exported = hollow.workspace.export_current()
      local directions = {}
      for _, pane in ipairs(exported.tabs[1].panes) do
        if pane.command ~= nil then
          directions[pane.command] = pane.direction
        end
      end
      harness.assert_equal(
        directions["horizontal-pane"],
        "horizontal",
        "workspace export should preserve horizontal split direction"
      )
      harness.assert_equal(
        directions["vertical-pane"],
        "vertical",
        "workspace export should preserve vertical split direction"
      )
      local sizes = {}
      for _, pane in ipairs(exported.tabs[1].panes) do
        if pane.command ~= nil then
          sizes[pane.command] = pane.size
        end
      end
      harness.assert_equal(
        sizes["horizontal-pane"],
        0.25,
        "workspace export should preserve horizontal split size"
      )
      harness.assert_equal(
        sizes["vertical-pane"],
        0.6,
        "workspace export should preserve vertical split size"
      )
    end)

    it("does not submit an empty split command", function()
      hollow.term.focus_pane_by_id(101)
      hollow.workspace.bootstrap({
        tabs = {
          {
            panes = {
              {},
              { cwd = "/tmp/project", command = "", direction = "horizontal" },
            },
          },
        },
      })
      flush_deferred()

      harness.assert_equal(
        recorded.split_pane.command,
        nil,
        "workspace bootstrap should treat an empty split command as absent"
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
    it("reuses matching cwd without sending a shell cd", function()
      hollow.term.focus_pane_by_id(101)
      local send_count = #recorded.send_text
      hollow.workspace.bootstrap({
        tabs = {
          {
            panes = {
              { cwd = "/tmp/project", command = "nvim" },
            },
          },
        },
      })
      flush_deferred()

      harness.assert_equal(
        recorded.send_text[send_count + 1],
        "nvim\r",
        "workspace bootstrap should send only restored command when cwd already matches"
      )
      harness.assert_equal(
        #recorded.send_text,
        send_count + 1,
        "workspace bootstrap should not send a cwd-changing shell command"
      )
    end)

    it("creates a workspace with spawn cwd instead of sending a shell cd", function()
      hollow.term.focus_pane_by_id(101)
      local send_count = #recorded.send_text
      hollow.workspace.bootstrap({
        tabs = {
          {
            panes = {
              { cwd = "/tmp/other", command = "nvim" },
            },
          },
        },
      })
      flush_deferred()

      harness.assert_equal(
        recorded.new_workspace.cwd,
        "/tmp/other",
        "workspace bootstrap should pass mismatched cwd to workspace creation"
      )
      harness.assert_equal(
        recorded.new_workspace.command,
        "nvim",
        "workspace bootstrap should pass restored command to workspace creation"
      )
      harness.assert_equal(
        #recorded.send_text,
        send_count,
        "workspace bootstrap should not send a cwd-changing shell command"
      )
    end)

    it("passes cwd to new tabs without replaying their startup command", function()
      hollow.term.focus_pane_by_id(101)
      local send_count = #recorded.send_text
      hollow.workspace.bootstrap({
        tabs = {
          {
            panes = {
              { cwd = "/tmp/project", command = "nvim" },
            },
          },
          {
            name = "server",
            panes = {
              { cwd = "/tmp/other", command = "npm run dev" },
            },
          },
        },
      })
      flush_deferred()

      harness.assert_equal(
        recorded.new_tab.cwd,
        "/tmp/other",
        "workspace bootstrap should pass tab cwd to tab creation"
      )
      harness.assert_equal(
        recorded.new_tab.command,
        "npm run dev",
        "workspace bootstrap should pass tab command to tab creation"
      )
      harness.assert_equal(
        recorded.send_text[send_count + 1],
        "nvim\r",
        "workspace bootstrap should send startup command only to reused pane"
      )
      harness.assert_equal(
        #recorded.send_text,
        send_count + 1,
        "workspace bootstrap should not replay newly created tab command"
      )
    end)

    it("removes generated cwd prefixes when exporting", function()
      host_api.set_pane_foreground_process(
        101,
        "cd -- '/tmp/project' && cd -- '/tmp/project' && nvim"
      )

      local exported = hollow.workspace.export_current()
      harness.assert_equal(
        exported.tabs[1].panes[1].command,
        "nvim",
        "workspace export should persist command without generated cwd prefixes"
      )
    end)

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

    it("omits split metadata for root pane", function()
      local exported = hollow.workspace.export_current()
      harness.assert_equal(
        exported.tabs[1].panes[1].direction,
        nil,
        "workspace export should omit root pane direction"
      )
      harness.assert_equal(
        exported.tabs[1].panes[1].size,
        nil,
        "workspace export should omit root pane size"
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

    it("omits empty commands when exporting", function()
      host_api.set_pane_foreground_process(101, "")

      local exported = hollow.workspace.export_current()
      harness.assert_equal(
        exported.tabs[1].panes[1].command,
        nil,
        "workspace export should omit command when pane has no foreground process"
      )
    end)
  end)
end)
