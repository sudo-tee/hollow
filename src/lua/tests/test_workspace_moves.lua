package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path
local clay = require("tests.clay_helpers")
local harness = require("tests.harness")

describe("workspace move actions", function()
  for _, kind in ipairs({ "tab", "pane" }) do
    describe("move " .. kind, function()
      local env, hollow, workspaces, picker, warning, failure, moves, switches, accepted

      before_each(function()
        env = harness.boot()
        hollow = env.hollow
        workspaces = {
          { id = 41, index = 1, name = "Source", is_active = true },
          { id = 42, index = 2, name = "Destination" },
          { id = 43, index = 3, name = "Other" },
        }
        picker, warning, failure = nil, nil, nil
        moves, switches, accepted = {}, 0, true
        hollow.term.current_workspace = function()
          return workspaces[1]
        end
        hollow.term.workspaces = function()
          return workspaces
        end
        hollow.ui.command_palette.open = function(opts)
          picker = opts
        end
        hollow.ui.notify.warn = function(message)
          warning = message
        end
        hollow.ui.notify.error = function(message)
          failure = message
        end
        env.host_api.switch_workspace = function()
          switches = switches + 1
        end
        env.host_api["move_" .. kind .. "_to_workspace"] = function(id, index)
          moves[#moves + 1] = { id = id, index = index }
          return accepted
        end
      end)

      local function invoke()
        hollow.action["move_" .. kind .. "_to_workspace"]()
      end

      it("excludes the current workspace and does not switch before confirmation", function()
        invoke()
        assert.equals(2, #picker.entries)
        assert.equals(42, picker.entries[1].workspace_id)
        assert.equals(43, picker.entries[2].workspace_id)
        assert.equals(0, #moves)
        assert.equals(0, switches)
        picker.on_confirm(picker.entries[1])
        assert.equals(kind == "tab" and 201 or 101, moves[1].id)
        assert.equals(1, moves[1].index)
        assert.equals(0, switches)
      end)

      it("explains refusal for attached, taken and disconnected persistent sources", function()
        for _, state in ipairs({ "attached", "taken", "disconnected" }) do
          workspaces[1].session_id = "source-session"
          workspaces[1].session_state = state
          invoke()
          assert.matches("persistent", warning:lower(), 1, true)
          assert.is_nil(picker)
          assert.equals(0, #moves)
          assert.equals(0, switches)
        end
      end)

      it("excludes persistent destinations and directly queues the sole eligible one", function()
        workspaces[2].session_id = "destination-session"
        invoke()
        assert.is_nil(picker)
        assert.equals(1, #moves)
        assert.equals(2, moves[1].index)
        assert.equals(0, switches)
      end)

      it("explains when no supported destination exists", function()
        workspaces[2].session_id = "destination-session"
        table.remove(workspaces, 3)
        invoke()
        assert.matches("No compatible destination workspace", warning, 1, true)
        assert.is_nil(picker)
        assert.equals(0, #moves)
        assert.equals(0, switches)
      end)

      it("does not submit when the picker is canceled", function()
        invoke()
        picker.on_confirm(nil)
        assert.equals(0, #moves)
        assert.equals(0, switches)
        assert.is_nil(warning)
      end)

      it("does not offer the source when it is the only workspace", function()
        workspaces = { workspaces[1] }
        invoke()
        assert.matches("No compatible destination workspace", warning, 1, true)
        assert.is_nil(picker)
        assert.equals(0, #moves)
        assert.equals(0, switches)
      end)

      it("resolves destination IDs after workspace positions change", function()
        invoke()
        local item = picker.entries[2]
        table.remove(workspaces, 2)
        workspaces[2].index = 2
        picker.on_confirm(item)
        assert.equals(1, moves[1].index)
        assert.equals(0, switches)
      end)

      it("warns if the destination disappears while the picker is open", function()
        invoke()
        local item = picker.entries[2]
        table.remove(workspaces, 3)
        picker.on_confirm(item)
        assert.matches("no longer available", warning, 1, true)
        assert.equals(0, #moves)
        assert.equals(0, switches)
      end)

      it("rechecks session ownership before queueing", function()
        invoke()
        workspaces[2].session_id = "new-session"
        picker.on_confirm(picker.entries[1])
        assert.matches("persistent", warning:lower(), 1, true)
        assert.equals(0, #moves)
        assert.equals(0, switches)
      end)

      it("rechecks the source session ownership before queueing", function()
        invoke()
        workspaces[1].session_state = "taken"
        picker.on_confirm(picker.entries[1])
        assert.matches("persistent", warning:lower(), 1, true)
        assert.equals(0, #moves)
        assert.equals(0, switches)
      end)

      it("reports queue rejection without switching workspaces", function()
        accepted = false
        invoke()
        picker.on_confirm(picker.entries[1])
        assert.equals("Could not queue the workspace move.", failure)
        assert.equals(0, switches)
      end)

      it(
        "allows only whole-tab transfers between attached same-domain same-host sessions",
        function()
          for _, workspace in ipairs(workspaces) do
            workspace.session_id = "session-" .. workspace.id
            workspace.session_state = "attached"
            workspace.session_host = "same-owner"
            workspace.domain = "Ubuntu"
          end
          workspaces[3].domain = "Other"
          invoke()
          assert.is_nil(picker)
          if kind == "tab" then
            assert.equals(1, #moves)
            assert.equals(1, moves[1].index)
            assert.is_nil(warning)
          else
            assert.equals(0, #moves)
            assert.matches("move its tab instead", warning, 1, true)
          end
          assert.equals(0, switches)
        end
      )

      it("refuses a persistent destination on another host", function()
        for _, workspace in ipairs(workspaces) do
          workspace.session_id = "session-" .. workspace.id
          workspace.session_state = "attached"
          workspace.domain = "Ubuntu"
          workspace.session_host = workspace.id == 41 and "owner-a" or "owner-b"
        end
        invoke()
        assert.equals(0, #moves)
        assert.is_not_nil(warning)
        assert.equals(0, switches)
      end)
    end)
  end

  it("explains that a docked pane must be undocked first", function()
    local env = harness.boot()
    local hollow = env.hollow
    local message
    hollow.term.current_pane = function()
      return { id = 101, dock = { scope = "global" } }
    end
    hollow.ui.notify.warn = function(value)
      message = value
    end
    hollow.action.move_pane_to_workspace()
    assert.equals("Undock the pane before moving it to another workspace.", message)
    assert.equals(0, hollow.ui.overlay.depth())
  end)

  it("opens a real destination picker from the command palette", function()
    local env = harness.boot()
    local hollow, ui = env.hollow, env.hollow.ui
    local workspaces = {
      { id = 41, index = 1, name = "Source", is_active = true },
      { id = 42, index = 2, name = "Destination" },
      { id = 43, index = 3, name = "Other" },
    }
    hollow.term.workspaces = function()
      return workspaces
    end
    local target
    env.host_api.switch_workspace = function()
      error("must not switch before the queued move succeeds")
    end
    env.host_api.move_tab_to_workspace = function(_, index)
      target = index
      return true
    end
    local function click(label)
      for _, node in ipairs(clay.nodes(ui)) do
        if node.list_item and node.label and node.label:find(label, 1, true) then
          ui.dispatch_widget_event("overlay:click", { id = node.id, index = 1 })
          return
        end
      end
      error("missing picker row: " .. label)
    end
    ui.command_palette.open({ query = "Move current tab to workspace" })
    click("Move current tab to workspace")
    assert.is_nil(target)
    click("Destination")
    assert.equals(1, target)
    assert.equals(0, ui.overlay.depth())
  end)
end)
