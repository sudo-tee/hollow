package.path = "src/lua/?.lua;src/lua/?/init.lua;src/lua/?.lua;" .. package.path
local harness = require("tests.harness")

describe("HTP test suite", function()
  local env
  local hollow
  local recorded

  setup(function()
    env = harness.boot()
    hollow = env.hollow
    recorded = env.recorded
  end)

  describe("HTP queries", function()
    it("handles the pane query", function()
      local ok_query, pane_query = hollow.htp._handle_query("pane", nil, 101)
      harness.assert_true(ok_query, "built-in HTP pane query should succeed")
      harness.assert_equal(pane_query.id, 101, "HTP pane query should expose pane snapshots")
    end)

    it("handles the current_domain query", function()
      local ok_domain_query, domain_query = hollow.htp._handle_query("current_domain", nil, 101)
      harness.assert_true(ok_domain_query, "built-in HTP current_domain query should succeed")
      harness.assert_equal(
        domain_query.name,
        "main",
        "HTP current_domain query should expose domain snapshots"
      )
    end)

    it("handles the panes query", function()
      local ok_panes_query, panes_query = hollow.htp._handle_query("panes", nil, 101)
      harness.assert_true(ok_panes_query, "built-in HTP panes query should succeed")
      harness.assert_equal(panes_query[1].id, 101, "HTP panes query should expose pane snapshots")
    end)

    it("filters the panes query by tag", function()
      hollow.term.add_pane_tag("test-runner", 101)
      local ok_tagged_panes_query, tagged_panes_query =
        hollow.htp._handle_query("panes", { tag = "test-runner" }, 101)
      harness.assert_true(ok_tagged_panes_query, "HTP tagged panes query should succeed")
      harness.assert_equal(
        tagged_panes_query[1].id,
        101,
        "HTP tagged panes query should filter by tag"
      )
    end)

    it("supports targeted tab lookups", function()
      local ok_tab_query, tab_query = hollow.htp._handle_query("tab", { id = 201 }, 101)
      harness.assert_true(ok_tab_query, "built-in HTP tab query should succeed")
      harness.assert_equal(tab_query.id, 201, "HTP tab query should support targeted lookups")
    end)

    it("supports targeted workspace lookups", function()
      local ok_workspace_query, workspace_query =
        hollow.htp._handle_query("workspace", { id = 41 }, 101)
      harness.assert_true(ok_workspace_query, "built-in HTP workspace query should succeed")
      harness.assert_equal(
        workspace_query.id,
        41,
        "HTP workspace query should support targeted lookups"
      )
    end)

    it("returns pane text", function()
      local ok_pane_text, pane_text = hollow.htp._handle_query("pane_text", { id = 101 }, 101)
      harness.assert_true(ok_pane_text, "HTP pane_text should succeed")
      harness.assert_equal(pane_text, "line one\nline two", "HTP pane_text should return pane text")
    end)
  end)

  describe("HTP emits", function()
    it("dispatches move_pane", function()
      local ok_emit =
        hollow.htp._handle_emit("move_pane", { direction = "left", amount = 0.2 }, 101)
      harness.assert_true(ok_emit, "built-in HTP emit handler should succeed")
      harness.assert_equal(
        recorded.move_pane.direction,
        "left",
        "HTP emit should dispatch term actions"
      )
      harness.assert_equal(
        recorded.move_pane.amount,
        0.2,
        "HTP emit should preserve payload values"
      )
    end)

    it("dispatches close_pane", function()
      local ok_close_pane = hollow.htp._handle_emit("close_pane", { id = 101 }, 101)
      harness.assert_true(ok_close_pane, "HTP close_pane should succeed")
      harness.assert_equal(recorded.close_pane, 101, "HTP close_pane should target pane ids")
    end)

    it("dispatches focus_pane", function()
      local ok_focus_pane = hollow.htp._handle_emit("focus_pane", { direction = "right" }, 101)
      harness.assert_true(ok_focus_pane, "HTP focus_pane should succeed")
      harness.assert_equal(recorded.focus_pane, "right", "HTP focus_pane should forward direction")
    end)

    it("dispatches resize_pane", function()
      local ok_resize_pane =
        hollow.htp._handle_emit("resize_pane", { axis = "horizontal", delta = 5 }, 101)
      harness.assert_true(ok_resize_pane, "HTP resize_pane should succeed")
      harness.assert_equal(
        recorded.resize_pane.axis,
        "horizontal",
        "HTP resize_pane should forward axis"
      )
      harness.assert_equal(recorded.resize_pane.amount, 5, "HTP resize_pane should forward delta")
    end)

    it("dispatches send_text", function()
      local ok_send_text = hollow.htp._handle_emit("send_text", { text = "ls\n", id = 101 }, 101)
      harness.assert_true(ok_send_text, "HTP send_text should succeed")
      harness.assert_equal(
        recorded.send_text[#recorded.send_text],
        "ls\n",
        "HTP send_text should forward text to the pane"
      )
    end)

    it("dispatches bell", function()
      local ok_bell = hollow.htp._handle_emit("bell", { id = 101 }, 101)
      harness.assert_true(ok_bell, "HTP bell should succeed")
      harness.assert_equal(recorded.bell, 101, "HTP bell should target pane ids")
    end)
  end)

  describe("HTP pane tag emits", function()
    it("dispatches add_pane_tag", function()
      local ok_add_pane_tag = hollow.htp._handle_emit("add_pane_tag", { id = 101, tag = "ci" }, 101)
      harness.assert_true(ok_add_pane_tag, "HTP add_pane_tag should succeed")
      harness.assert_equal(
        hollow.term.get_pane_tags(101)[1],
        "ci",
        "HTP add_pane_tag should add a pane tag"
      )
    end)

    it("dispatches set_pane_tags", function()
      local ok_set_pane_tags =
        hollow.htp._handle_emit("set_pane_tags", { id = 101, tags = { "runner", "slow" } }, 101)
      harness.assert_true(ok_set_pane_tags, "HTP set_pane_tags should succeed")
      harness.assert_equal(
        hollow.term.get_pane_tags(101)[1],
        "runner",
        "HTP set_pane_tags should replace pane tags"
      )
      harness.assert_equal(
        hollow.term.get_pane_tags(101)[2],
        "slow",
        "HTP set_pane_tags should keep all tags"
      )
    end)

    it("dispatches remove_pane_tag", function()
      local ok_remove_pane_tag =
        hollow.htp._handle_emit("remove_pane_tag", { id = 101, tag = "runner" }, 101)
      harness.assert_true(ok_remove_pane_tag, "HTP remove_pane_tag should succeed")
      harness.assert_equal(
        hollow.term.get_pane_tags(101)[1],
        "slow",
        "HTP remove_pane_tag should remove only the requested tag"
      )
    end)
  end)

  describe("HTP tab emits", function()
    it("dispatches close_tab", function()
      local ok_close_tab = hollow.htp._handle_emit("close_tab", { id = 201 }, 101)
      harness.assert_true(ok_close_tab, "HTP close_tab should succeed")
      harness.assert_equal(recorded.close_tab_by_id, 201, "HTP close_tab should target tab ids")
    end)

    it("dispatches focus_tab", function()
      local ok_focus_tab = hollow.htp._handle_emit("focus_tab", { id = 201 }, 101)
      harness.assert_true(ok_focus_tab, "HTP focus_tab should succeed")
      harness.assert_equal(recorded.switch_tab_by_id, 201, "HTP focus_tab should target tab ids")
    end)

    it("dispatches set_tab_title", function()
      local ok_set_tab_title =
        hollow.htp._handle_emit("set_tab_title", { id = 201, title = "editor" }, 101)
      harness.assert_true(ok_set_tab_title, "HTP set_tab_title should succeed")
      harness.assert_equal(
        recorded.set_tab_title_by_id.title,
        "editor",
        "HTP set_tab_title should forward title"
      )
    end)

    it("dispatches new_tab", function()
      local ok_new_tab =
        hollow.htp._handle_emit("new_tab", { domain = "dev", command = "npm run dev" }, 101)
      harness.assert_true(ok_new_tab, "HTP new_tab should succeed")
      harness.assert_equal(recorded.new_tab.domain, "dev", "HTP new_tab should forward domain")
      harness.assert_equal(
        recorded.new_tab.command,
        "npm run dev",
        "HTP new_tab should forward command"
      )
    end)
  end)

  describe("HTP workspace emits", function()
    it("dispatches new_workspace", function()
      local ok_new_workspace =
        hollow.htp._handle_emit("new_workspace", { cwd = "/tmp/project", name = "proj" }, 101)
      harness.assert_true(ok_new_workspace, "HTP new_workspace should succeed")
      harness.assert_equal(
        recorded.new_workspace.name,
        "proj",
        "HTP new_workspace should forward payload"
      )
    end)

    it("dispatches set_workspace_name", function()
      local ok_set_workspace_name =
        hollow.htp._handle_emit("set_workspace_name", { id = 41, name = "renamed" }, 101)
      harness.assert_true(ok_set_workspace_name, "HTP set_workspace_name should succeed")
      harness.assert_equal(
        hollow.term.current_workspace().name,
        "renamed",
        "HTP set_workspace_name should update the active workspace"
      )
    end)
  end)

  describe("HTP config emits", function()
    it("dispatches reload_config", function()
      local ok_reload_config = hollow.htp._handle_emit("reload_config", {}, 101)
      harness.assert_true(ok_reload_config, "HTP reload_config should succeed")
      harness.assert_equal(
        recorded.reload_config,
        1,
        "HTP reload_config should call the host bridge"
      )
    end)

    it("dispatches set_theme", function()
      local ok_set_theme = hollow.htp._handle_emit("set_theme", { name = "tokyonight" }, 101)
      harness.assert_true(ok_set_theme, "HTP set_theme should succeed")
      harness.assert_equal(
        hollow.config.get("theme"),
        "tokyonight",
        "HTP set_theme should update config state"
      )
    end)

    it("dispatches scroll", function()
      local ok_scroll = hollow.htp._handle_emit("scroll", { to = "page-down" }, 101)
      harness.assert_true(ok_scroll, "HTP scroll should succeed")
      harness.assert_equal(recorded.scroll.kind, "page", "HTP scroll should map to scroll actions")
      harness.assert_equal(recorded.scroll.amount, 1, "HTP scroll page-down should scroll one page")
    end)
  end)
end)
