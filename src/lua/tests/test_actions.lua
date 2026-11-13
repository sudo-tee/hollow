package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("actions test suite", function()
  local env
  local hollow
  local recorded

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  describe("quick_select actions", function()
    it("requests URL opening", function()
      hollow.action.quick_select()
      harness.assert_equal(
        recorded.quick_select,
        "open",
        "quick_select action should request URL opening"
      )
    end)

    it("requests clipboard copy", function()
      hollow.action.quick_select_copy()
      harness.assert_equal(
        recorded.quick_select,
        "copy",
        "quick_select_copy action should request clipboard copy"
      )
    end)
  end)

  describe("workspace actions", function()
    it("registers save_workspace in the action list", function()
      local entry
      for _, candidate in ipairs(hollow.action.list()) do
        if candidate.name == "save_workspace" then
          entry = candidate
          break
        end
      end
      harness.assert_true(entry ~= nil, "save_workspace should be discoverable")
      harness.assert_equal(
        entry.category,
        "workspace",
        "save_workspace should be listed under workspace actions"
      )
    end)

    it("exports to the active project directory", function()
      local saved_path
      local original_export_to = hollow.workspace.export_to
      local original_notify = hollow.ui.notify.info
      hollow.workspace.export_to = function(path)
        saved_path = path
      end
      hollow.ui.notify.info = function() end

      hollow.action.save_workspace()

      hollow.workspace.export_to = original_export_to
      hollow.ui.notify.info = original_notify
      harness.assert_equal(
        saved_path,
        "\\\\wsl.localhost\\main\\tmp\\project\\.hollow\\workspace.json",
        "save_workspace should export to the project-local workspace path"
      )
    end)
  end)

  describe("registered action metadata", function()
    it("filters unavailable actions using the current action context", function()
      local available_context
      local hidden_runs = 0
      hollow.action.register("contextual_available", {
        run = function() end,
        desc = "Contextual visible marker",
        available = function(ctx)
          available_context = ctx
          return true
        end,
      })
      hollow.action.register("contextual_unavailable", {
        run = function()
          hidden_runs = hidden_runs + 1
        end,
        desc = "Contextual hidden marker",
        available = function()
          return false
        end,
      })

      local visible, hidden = false, false
      for _, entry in ipairs(hollow.action.list()) do
        visible = visible or entry.name == "contextual_available"
        hidden = hidden or entry.name == "contextual_unavailable"
      end

      harness.assert_true(visible, "registered actions should remain available through action.list")
      harness.assert_true(hidden, "action.list should retain unavailable action metadata")

      hollow.ui.command_palette.open({ query = "contextual" })
      hollow.ui._layout_prepare(1000, 800, 8, 19)
      local has_visible_row, has_hidden_row = false, false
      for _, row in ipairs(hollow.ui._layout_tree) do
        if row.list_item then
          local row_text = row.label or ""
          has_visible_row = has_visible_row
            or row_text:find("Contextual visible marker", 1, true) ~= nil
          has_hidden_row = has_hidden_row
            or row_text:find("Contextual hidden marker", 1, true) ~= nil
        end
      end
      harness.assert_equal(available_context.name, "contextual_available")
      harness.assert_equal(available_context.args.n, 0)
      harness.assert_equal(available_context.pane.id, 101)
      harness.assert_equal(available_context.tab.id, 201)
      harness.assert_equal(available_context.workspace.name, "main")
      harness.assert_true(has_visible_row, "available action should have a palette row")
      harness.assert_true(not has_hidden_row, "unavailable action should have no palette row")
      hollow.ui.overlay.clear()
      hollow.action.contextual_unavailable()
      harness.assert_equal(hidden_runs, 1, "availability should only affect palette visibility")
    end)

    it("hides actions when availability checks fail", function()
      hollow.action.register("contextual_broken", {
        run = function() end,
        desc = "Contextual broken marker",
        available = function()
          error("availability failed")
        end,
      })

      local found = false
      for _, entry in ipairs(hollow.action.list()) do
        found = found or entry.name == "contextual_broken"
      end
      harness.assert_true(found, "action.list should retain actions whose check fails")

      hollow.ui.command_palette.open({ query = "Contextual broken marker" })
      hollow.ui._layout_prepare(1000, 800, 8, 19)
      local has_broken_row = false
      for _, row in ipairs(hollow.ui._layout_tree) do
        if row.list_item then
          has_broken_row = has_broken_row
            or (row.label or ""):find("Contextual broken marker", 1, true) ~= nil
        end
      end
      harness.assert_true(not has_broken_row, "failed availability check should fail closed")
      hollow.ui.overlay.clear()
    end)

    it("registers declared chords as defaults", function()
      hollow.action.register("contextual_key_action", {
        run = function() end,
        keys = { "<C-S-h>" },
      })
      hollow.keymap.apply_defaults()

      harness.assert_equal(
        hollow.keymap.get("<C-S-h>"),
        "contextual_key_action",
        "action keys should be installed through keymap defaults"
      )
    end)
  end)

  describe("configured quick-select", function()
    local selected_custom_text = nil
    local configured_matches
    local configured_command

    it("registers configured patterns and actions", function()
      hollow.config.set({
        quick_select = {
          actions = {
            filename = "open",
          },
          patterns = {
            {
              pattern = "ISSUE%-%d+",
              action = function(text, context)
                selected_custom_text = text .. ":" .. context.kind
              end,
            },
            {
              pattern = "FILE:%S+",
              action = { command = { "code", "{match}" } },
            },
          },
        },
      })
      configured_matches = recorded.quick_select_match_handler("open ISSUE-42 FILE:notes.txt")
    end)

    it("adds matches for configured patterns", function()
      harness.assert_equal(
        #configured_matches,
        2,
        "configured quick-select patterns should add matches"
      )
      harness.assert_equal(
        configured_matches[1].text,
        "ISSUE-42",
        "configured pattern should return matched text"
      )
      harness.assert_equal(
        configured_matches[1].start_col,
        5,
        "configured pattern should return zero-based start column"
      )
    end)

    it("makes built-in pattern actions configurable", function()
      harness.assert_equal(
        recorded.quick_select_action_handler("filename", 0, "src/main.zig", "copy"),
        "open",
        "built-in pattern actions should be configurable"
      )
    end)

    it("handles matches with custom callbacks", function()
      harness.assert_equal(
        recorded.quick_select_action_handler("custom", 1, "ISSUE-42", "copy"),
        "handled",
        "custom callback action should handle match"
      )
      harness.assert_equal(
        selected_custom_text,
        "ISSUE-42:custom",
        "custom callback should receive text and context"
      )
    end)

    it("substitutes matched text into command actions", function()
      configured_command =
        recorded.quick_select_action_handler("custom", 2, "FILE:notes.txt", "copy")
      harness.assert_equal(
        configured_command[1],
        "code",
        "command action should return configured executable"
      )
      harness.assert_equal(
        configured_command[2],
        "FILE:notes.txt",
        "command action should substitute matched text"
      )
    end)
  end)

  describe("cross-domain panes", function()
    local dialog, workspace, docks, originals

    before_each(function()
      dialog, docks = nil, {}
      recorded.split_pane, recorded.new_tab, recorded.new_workspace = nil, nil, nil
      originals = {
        current_workspace = hollow.term.current_workspace,
        docks = hollow.term.docks,
        confirm = hollow.ui.confirm.open,
        entries = hollow.ui.command_palette.build_domain_entries,
      }
      hollow.config.set({
        default_domain = "wsl",
        domains = { wsl = { persist = true }, remote = { persist = true }, pwsh = {} },
      })
      hollow.term.current_workspace = function()
        return workspace
      end
      hollow.term.docks = function()
        return docks
      end
      hollow.ui.confirm.open = function(opts)
        dialog = opts
      end
    end)

    after_each(function()
      hollow.term.current_workspace = originals.current_workspace
      hollow.term.docks = originals.docks
      hollow.ui.confirm.open = originals.confirm
      hollow.ui.command_palette.build_domain_entries = originals.entries
    end)

    local function target(domain)
      hollow.ui.command_palette.build_domain_entries = function()
        return { { domain_name = domain } }
      end
    end

    local function labels()
      local result = {}
      for _, button in ipairs(dialog.buttons) do
        result[#result + 1] = button.text
      end
      return table.concat(result, " | ")
    end

    it("splits directly when the domain matches the session", function()
      workspace = { session_id = "s1", domain = "wsl" }
      target("wsl")
      hollow.action.split_vertical_in_domain()
      harness.assert_equal(dialog, nil, "no dialog")
      harness.assert_equal(recorded.split_pane.domain, "wsl", "split sent")
    end)

    it("offers a workspace or a global dock for an ordinary domain", function()
      workspace = { session_id = "s1", domain = "wsl" }
      target("pwsh")
      hollow.action.split_horizontal_in_domain()
      harness.assert_equal(recorded.split_pane, nil, "nothing sent before choosing")
      harness.assert_equal(labels(), "New workspace | Global dock | Cancel", "both choices offered")
      dialog.on_confirm("dock")
      harness.assert_equal(recorded.split_pane.dock, "global", "global dock")
      harness.assert_equal(recorded.split_pane.edge, "bottom", "edge follows the split")
      harness.assert_equal(recorded.split_pane.domain, "pwsh", "target domain kept")
    end)

    it("moves to a free edge when the preferred dock edge is taken", function()
      workspace = { session_id = "s1", domain = "wsl" }
      docks = { { dock = { scope = "global", edge = "right" } } }
      target("pwsh")
      hollow.action.split_vertical_in_domain()
      dialog.on_confirm("dock")
      harness.assert_equal(recorded.split_pane.edge, "bottom", "next free edge")
    end)

    it("offers only a new workspace for another persistent domain", function()
      workspace = { session_id = "s1", domain = "wsl" }
      target("remote")
      hollow.action.new_tab_in_domain()
      harness.assert_equal(labels(), "New workspace | Cancel", "no dock for sessions")
      dialog.on_confirm("workspace")
      harness.assert_equal(recorded.new_workspace.domain, "remote", "workspace on the target")
      harness.assert_equal(recorded.new_tab, nil, "no tab sent")
    end)

    it("offers a session workspace for a persistent domain from an ordinary workspace", function()
      workspace = { domain = "pwsh" }
      target("remote")
      hollow.action.split_vertical_in_domain()
      harness.assert_equal(labels(), "New session workspace | Cancel", "session choice")
      dialog.on_confirm(false)
      harness.assert_equal(recorded.split_pane, nil, "cancel sends nothing")
      harness.assert_equal(recorded.new_workspace, nil, "cancel creates nothing")
    end)
  end)
end)
