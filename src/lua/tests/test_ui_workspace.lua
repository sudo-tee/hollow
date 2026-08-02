package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("UI workspace test suite", function()
  local env
  local hollow
  local on_key

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    on_key = env.get_key_handler()
  end)

  describe("workspace switcher", function()
    it("configures switcher sources", function()
      hollow.ui.workspace.configure({
        cache_ttl_ms = 0,
        sources = {
          {
            name = "Ubuntu",
            domain = "main",
            cwd_resolver = "wsl_unc",
            roots = {
              "\\\\wsl$\\Ubuntu\\home\\francis\\Projects",
            },
          },
        },
        filter_item = function(item)
          local basename = hollow.util.basename(item.cwd)
          return basename and basename:sub(1, 1) ~= "_"
        end,
      })
    end)

    it("includes open workspaces and UNC-scanned roots", function()
      local workspace_items = hollow.ui.workspace.items(true)
      harness.assert_equal(
        #workspace_items,
        2,
        "workspace switcher should include open workspaces and UNC-scanned roots"
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
        "workspace switcher should keep UNC root entries without per-item path stats"
      )
      harness.assert_equal(
        workspace_items[2].cwd,
        "/home/francis/Projects/alpha",
        "workspace switcher should still resolve UNC cwd for launch"
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
