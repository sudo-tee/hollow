package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI workspace test suite", function()
  local env
  local hollow
  local recorded
  local on_key
  local workspace_actions

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
    on_key = env.get_key_handler()
    workspace_actions = require("hollow.ui.workspace.actions")
  end)

  describe("workspace switcher", function()
    it("configures switcher sources", function()
      local function resolved(value)
        return { next = function(_, ok) ok(value) end }
      end
      local host = { id = "workspace-test", generation = "g1", fs = {
        list = function()
          return resolved({ entries = { { name = "alpha" }, { name = "_scratch" } }, eof = true })
        end,
        stat = function() return resolved({ kind = "directory" }) end,
      } }
      hollow.ui.workspace.configure({
        cache_ttl_ms = 0,
        sources = {
          {
            name = "Ubuntu",
            domain = "main",
            host = host,
            roots = {
              "/home/francis/Projects",
            },
          },
        },
        filter_item = function(item)
          local basename = hollow.util.basename(item.cwd)
          return basename and basename:sub(1, 1) ~= "_"
        end,
      })
    end)

    it("includes open workspaces and agent-scanned roots", function()
      hollow.ui.workspace.items(true)
      env.flush_deferred()
      local workspace_items = hollow.ui.workspace.items()
      harness.assert_equal(
        #workspace_items,
        2,
        "workspace switcher should include open workspaces and agent-scanned roots"
      )
      harness.assert_equal(
        workspace_items[1].name,
        "main",
        "workspace switcher should dedupe an opened workspace against its known root entry"
      )
      harness.assert_equal(
        workspace_items[1].cwd,
        "/tmp/project",
        "workspace switcher should preserve the remembered cwd for the opened workspace entry"
      )
      harness.assert_equal(
        workspace_items[2].name,
        "alpha",
        "workspace switcher should keep host directory entries"
      )
      harness.assert_equal(
        workspace_items[2].cwd,
        "/home/francis/Projects/alpha",
        "workspace switcher should preserve guest-native cwd for launch"
      )
    end)

    it("bootstraps project layouts with source cwd and domain", function()
      local bootstrapped_dir
      local bootstrapped_domain
      local original_bootstrap_project = hollow.workspace.bootstrap_project_async
      hollow.workspace.bootstrap_project_async = function(dir, domain)
        bootstrapped_dir = dir
        bootstrapped_domain = domain
        return hollow.async.promise(function(resolve) resolve(true) end)
      end

      workspace_actions.switch_to_workspace({
        name = "dots",
        cwd = "/home/francis/dots",
        domain = "unix",
        source = "local",
        is_open = false,
      })

      hollow.workspace.bootstrap_project_async = original_bootstrap_project
      harness.assert_equal(
        bootstrapped_dir,
        "/home/francis/dots",
        "opening a known workspace should bootstrap its project cwd"
      )
      harness.assert_equal(recorded.new_workspace.domain, "unix", "preserve launch domain")
      harness.assert_equal(bootstrapped_domain, "unix", "preserve bootstrap host domain")
    end)

    it("waits for canonical WSL cwd before bootstrapping project layouts", function()
      hollow.config.set({ domains = { UbuntuWSL = { wsl_distro = "Ubuntu" } } })
      local bootstrapped_dir
      local original_bootstrap_project = hollow.workspace.bootstrap_project_async
      hollow.workspace.bootstrap_project_async = function(dir)
        bootstrapped_dir = dir
        return hollow.async.promise(function(resolve) resolve(true) end)
      end

      workspace_actions.switch_to_workspace({
        name = "dots",
        cwd = "/home/francis/Projects/dotfiles",
        domain = "UbuntuWSL",
        source = "local",
        is_open = false,
      })
      harness.assert_equal(
        bootstrapped_dir,
        nil,
        "WSL workspace bootstrap should wait for shell cwd resolution"
      )

      hollow._emit_builtin_event("term:cwd_changed", {
        pane_id = 101,
        old_cwd = "/home/francis/Projects/dotfiles",
        new_cwd = "/home/francis/dots",
      })
      hollow.workspace.bootstrap_project_async = original_bootstrap_project
      harness.assert_equal(
        bootstrapped_dir,
        "/home/francis/dots",
        "WSL workspace bootstrap should use canonical shell cwd"
      )
    end)

    it("passes SSH workspace cwd to the new pane", function()
      workspace_actions.open_new_workspace_from_item({
        name = "remote",
        cwd = "/srv/project",
        domain = "devbox",
        source = "ssh",
      })

      harness.assert_equal(
        recorded.new_workspace.cwd,
        "/srv/project",
        "SSH workspace opening should pass remote cwd through pane creation"
      )
      harness.assert_equal(
        recorded.new_workspace.command,
        nil,
        "SSH workspace opening should not inject cwd as a startup command"
      )
    end)
  end)

  describe("workspace switcher overlay", function()
    local resolved_select_theme
    local workspace_overlay

    it("creates an overlay with semantic rows", function()
      hollow.ui.workspace.open_switcher()
      workspace_overlay = hollow.ui._overlay_state()
      harness.assert_true(workspace_overlay ~= nil, "workspace switcher should create an overlay")
      harness.assert_equal(
        workspace_overlay[1].rows[1].hoverable,
        false,
        "select title should not be hoverable"
      )
      harness.assert_equal(
        workspace_overlay[1].rows[3].hoverable,
        false,
        "select filter should not be hoverable"
      )
      resolved_select_theme = hollow.ui.resolve_theme("select")
      harness.assert_equal(
        workspace_overlay[1].chrome.bg,
        resolved_select_theme.panel_bg,
        "workspace switcher should use the select panel background"
      )
      harness.assert_equal(
        workspace_overlay[1].chrome.alpha,
        255,
        "workspace switcher should default overlay chrome alpha to opaque"
      )
      harness.assert_equal(
        workspace_overlay[1].rows[5].fill_bg,
        resolved_select_theme.selection_bg,
        "workspace switcher should use the select selected background for the active row"
      )
      harness.assert_true(
        type(workspace_overlay[1].rows[5].id) == "string"
          and workspace_overlay[1].rows[5].id:find("select:item:", 1, true) == 1,
        "workspace switcher entries should expose stable semantic row ids"
      )
    end)

    it("filters by the first key", function()
      harness.assert_true(on_key("a", 0), "workspace switcher should consume first-key filtering")
      workspace_overlay = hollow.ui._overlay_state()
      harness.assert_true(
        workspace_overlay ~= nil,
        "workspace switcher should remain open while filtering"
      )
      local filtered_workspace_text = ""
      for _, row in ipairs(workspace_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          filtered_workspace_text = filtered_workspace_text .. (segment.text or "")
        end
        filtered_workspace_text = filtered_workspace_text .. "\n"
      end
      harness.assert_true(
        filtered_workspace_text:find("alpha", 1, true) ~= nil,
        "workspace switcher should match alpha on the first key"
      )
      hollow.ui.overlay.clear()
    end)

    it("searches by basename", function()
      hollow.ui.workspace.open_switcher()
      workspace_overlay = hollow.ui._overlay_state()
      harness.assert_true(
        workspace_overlay ~= nil,
        "workspace switcher should reopen for basename search test"
      )
      harness.assert_true(
        on_key("h", 0),
        "workspace switcher should consume first key for basename search"
      )
      harness.assert_true(
        on_key("o", 0),
        "workspace switcher should consume second key for basename search"
      )
      workspace_overlay = hollow.ui._overlay_state()
      harness.assert_true(
        workspace_overlay ~= nil,
        "workspace switcher should remain open during basename search"
      )
      local basename_search_text = ""
      for _, row in ipairs(workspace_overlay[1].rows or {}) do
        for _, segment in ipairs(row.segments or {}) do
          basename_search_text = basename_search_text .. (segment.text or "")
        end
        basename_search_text = basename_search_text .. "\n"
      end
      harness.assert_true(
        basename_search_text:find("alpha", 1, true) == nil,
        "workspace switcher search should not match every /home path entry"
      )
      hollow.ui.overlay.clear()
    end)
  end)
end)

describe("Workspace switcher cross-domain metadata", function()
  local hollow
  local env

  before_each(function()
    env = harness.boot()
    hollow = env.hollow
    env.host_api.split_pane({ domain = "UbuntuWSL", cwd = "/srv/remote" })
    env.host_api.get_workspace_count = function() return 2 end
    env.host_api.get_workspace_name = function(index) return index == 0 and "main" or "remote" end
    env.host_api.get_workspace_id = function(index) return index + 41 end
    env.host_api.get_workspace_tab_count = function() return 1 end
    env.host_api.get_workspace_tab_id_at = function(index) return index == 0 and 201 or 202 end
    env.host_api.get_tab_active_pane_id = function(tab_id)
      return tab_id == 202 and 102 or 101
    end
    local pane_domain = env.host_api.get_pane_domain
    env.host_api.get_pane_domain = function(pane_id)
      return pane_id == 102 and "UbuntuWSL" or pane_domain(pane_id)
    end
    local pane_cwd = env.host_api.get_pane_cwd
    env.host_api.get_pane_cwd = function(pane_id)
      return pane_id == 102 and "/srv/remote" or pane_cwd(pane_id)
    end
    env.host_api.get_tab_pane_count = function() return 1 end
    env.host_api.get_tab_pane_id_at = function(tab_id) return tab_id == 202 and 102 or 101 end
  end)

  it("snapshots each workspace's own domain", function()
    local workspaces = hollow.term.workspaces()
    assert.equal("main", workspaces[1].domain)
    assert.equal("UbuntuWSL", workspaces[2].domain)
  end)

  it("keeps nested pane paths and domains when focus changes", function()
    local function remote_item()
      for _, item in ipairs(hollow.ui.workspace.items()) do
        if item.name == "remote" then return item end
      end
    end
    assert.equal("/srv/remote", remote_item().cwd)
    assert.equal("UbuntuWSL", remote_item().domain)
    env.host_api.get_active_workspace_index = function() return 1 end
    env.host_api.current_tab_id = function() return 202 end
    assert.equal("/srv/remote", remote_item().cwd)
    assert.equal("UbuntuWSL", remote_item().domain)
  end)

  it("renders compact rounded domain badges at the right edge after paths", function()
    hollow.ui.workspace.open_switcher()
    local found_domain, found_path = false, false
    for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
      local saw_path, saw_spacer = false, false
      for _, segment in ipairs(row.segments or {}) do
        local text = segment.text or ""
        if segment.spacer then saw_spacer = true end
        if text:find("UbuntuWSL", 1, true) then
          found_domain = true
          assert.is_not_nil(segment.bg)
          assert.equal(4, segment.radius)
          assert.equal(" UbuntuWSL ", text)
          assert.is_true(saw_path)
          assert.is_true(saw_spacer)
          assert.equal(segment, row.segments[#row.segments])
          assert.is_nil(text:find("[UbuntuWSL]", 1, true))
          assert.is_nil(text:find("/srv/remote", 1, true))
        end
        if text:find("/srv/remote", 1, true) then
          found_path = true
          saw_path = true
        end
        assert.is_nil(text:find("Open workspace", 1, true))
      end
    end
    assert.is_true(found_domain)
    assert.is_true(found_path)
  end)

  it("preserves right-alignment spacers while filtering", function()
    hollow.ui.workspace.open_switcher()
    assert.is_true(env.get_key_handler()("r", 0))
    local found_domain = false
    for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
      local saw_spacer = false
      for _, segment in ipairs(row.segments or {}) do
        if segment.spacer then saw_spacer = true end
        if (segment.text or ""):find("UbuntuWSL", 1, true) then
          found_domain = true
          assert.is_true(saw_spacer)
          assert.equal(segment, row.segments[#row.segments])
        end
      end
    end
    assert.is_true(found_domain)
  end)

  it("hides domain pills and reclaims path width for a single domain", function()
    local function path_width()
      for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
        for _, segment in ipairs(row.segments or {}) do
          if (segment.text or ""):find("/srv/remote", 1, true) then
            return #segment.text
          end
        end
      end
    end
    hollow.ui.workspace.open_switcher()
    local multi_domain_width = path_width()
    hollow.ui.select.close()
    env.host_api.get_pane_domain = function() return "UbuntuWSL" end
    hollow.ui.workspace.open_switcher()
    assert.is_true(path_width() > multi_domain_width)
    for _, row in ipairs(hollow.ui._overlay_state()[1].rows) do
      for _, segment in ipairs(row.segments or {}) do
        assert.is_nil((segment.text or ""):find("UbuntuWSL", 1, true))
        assert.is_nil(segment.radius)
      end
    end
  end)
end)

describe("Workspace switcher bell attention", function()
  local hollow
  local tree

  before_each(function()
    hollow = harness.boot().hollow
    tree = {
      {
        id = 41,
        index = 1,
        name = "main",
        domain = "main",
        is_active = true,
        tabs = { { panes = { { has_bell = false } } } },
      },
      {
        id = 42,
        index = 2,
        name = "alpha",
        domain = "main",
        is_active = false,
        tabs = { { panes = { { has_bell = false } } } },
      },
      {
        id = 43,
        index = 3,
        name = "zulu",
        domain = "main",
        is_active = false,
        tabs = {
          { panes = { { has_bell = false } } },
          { panes = { { has_bell = false }, { has_bell = true } } },
        },
      },
    }
    hollow.term.mux_tree = function()
      return tree
    end
    hollow.ui.workspace.configure({
      known_workspaces = function()
        return { "known" }
      end,
    })
  end)

  it("prioritizes attention from any pane in any tab", function()
    local items = hollow.ui.workspace.items()
    harness.assert_equal(items[1].name, "zulu", "bell workspace should sort before quiet workspaces")
    harness.assert_true(items[1].has_bell, "bell state should include inactive tabs and split panes")
    harness.assert_equal(items[2].name, "alpha", "quiet inactive workspace should retain its order")
    harness.assert_equal(items[3].name, "main", "quiet active workspace should retain its order")
    harness.assert_equal(
      items[4].name,
      "known",
      "known workspaces should remain after open workspaces"
    )
    harness.assert_equal(items[4].has_bell, false, "closed known workspaces should have no bell")
  end)

  it("prioritizes active workspace attention and refreshes cleared bells without cache invalidation", function()
    tree[1].tabs[1].panes[1].has_bell = true
    local items = hollow.ui.workspace.items()
    harness.assert_equal(items[1].name, "zulu", "inactive bell workspace should remain first")
    harness.assert_equal(
      items[2].name,
      "main",
      "active bell workspace should precede quiet workspaces"
    )
    harness.assert_equal(items[3].name, "alpha", "quiet workspace should follow bell workspaces")

    tree[1].tabs[1].panes[1].has_bell = false
    tree[3].tabs[2].panes[2].has_bell = false
    items = hollow.ui.workspace.items()
    harness.assert_equal(items[1].name, "alpha", "clearing bells should restore existing ordering")
    harness.assert_equal(items[2].name, "zulu", "cleared workspace should use normal ordering")
    harness.assert_equal(
      items[2].has_bell,
      false,
      "bell state should not be cached with discovered items"
    )
    harness.assert_equal(
      items[3].name,
      "main",
      "quiet active workspace should remain last among open workspaces"
    )
  end)

  it("renders a warning-colored bell icon on the first workspace row", function()
    hollow.ui.workspace.open_switcher()
    local overlay = hollow.ui._overlay_state()
    local warn = hollow.ui.resolve_theme("select").notify_levels.warn
    local saw_bell = false
    local row_text = ""
    for _, segment in ipairs(overlay[1].rows[5].segments) do
      row_text = row_text .. (segment.text or "")
      if (segment.text or ""):find("󰂚", 1, true) then
        saw_bell = true
        harness.assert_equal(segment.fg, warn, "bell icon should use notification warning color")
        harness.assert_true(segment.bold, "bell icon should be bold")
      end
    end
    harness.assert_true(saw_bell, "default workspace formatter should show bell icon")
    harness.assert_true(
      row_text:find("zulu", 1, true) ~= nil,
      "first selectable row should be bell workspace"
    )
    hollow.ui.overlay.clear()
  end)
end)
