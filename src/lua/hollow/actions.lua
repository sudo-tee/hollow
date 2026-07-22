local M = {}

local registry = {}

local function copy_mode_state()
  local state = require("hollow.state").get()
  state.copy_mode = state.copy_mode
    or {
      active = false,
      query = "",
      hud = nil,
      selecting = false,
      pending_g = false,
      match_count = 0,
      match_index = nil,
      block = false,
    }
  return state.copy_mode
end

local function copy_mode_move(direction)
  return function()
    local cs = copy_mode_state()
    _G.host_api.copy_mode_move(direction, cs.selecting == true)
  end
end

---@param hollow Hollow
---@param name string
---@param spec HollowActionSpec
local function register(hollow, name, spec)
  registry[name] = spec
  hollow.action[name] = spec.run
end

local function list()
  local entries = {}
  for name, spec in pairs(registry) do
    entries[#entries + 1] = {
      name = name,
      desc = spec.desc or "",
      category = spec.category or "general",
      run = spec.run,
      workspace_targetable = spec.workspace_targetable or false,
    }
  end
  table.sort(entries, function(a, b)
    if a.category ~= b.category then
      local cat_order = {
        tab = 1,
        pane = 2,
        workspace = 3,
        window = 4,
        scroll = 5,
        copy_mode = 6,
        general = 7,
        user = 8,
      }
      return (cat_order[a.category] or 99) < (cat_order[b.category] or 99)
    end
    return a.name < b.name
  end)
  return entries
end

function M.setup(hollow, host_api)
  local copy_mode = require("hollow.copy_mode")

  ---@type HollowActionNamespace
  hollow.action = hollow.action or {}
  hollow.action.register = function(name, spec)
    register(hollow, name, spec)
  end
  hollow.action.list = list

  -- ── Pane Actions ─────────────────────────────────

  register(hollow, "split_vertical", {
    run = function()
      host_api.split_pane({ direction = "vertical" })
    end,
    desc = "Split pane vertically",
    category = "pane",
    workspace_targetable = true,
  })

  register(hollow, "split_horizontal", {
    run = function()
      host_api.split_pane({ direction = "horizontal" })
    end,
    desc = "Split pane horizontally",
    category = "pane",
    workspace_targetable = true,
  })

  register(hollow, "create_floating_pane", {
    run = function()
      host_api.split_pane({ floating = true })
    end,
    desc = "Create floating pane",
    category = "pane",
    workspace_targetable = true,
  })

  register(hollow, "maximize_pane", {
    run = function()
      host_api.toggle_pane_maximized(nil, false)
    end,
    desc = "Toggle pane maximize",
    category = "pane",
  })

  register(hollow, "float_pane", {
    run = function()
      host_api.set_pane_floating(nil, true)
    end,
    desc = "Float pane",
    category = "pane",
  })

  register(hollow, "tile_pane", {
    run = function()
      host_api.set_pane_floating(nil, false)
    end,
    desc = "Tile pane (unfloat)",
    category = "pane",
  })

  register(hollow, "close_pane", {
    run = function()
      host_api.close_pane()
    end,
    desc = "Close current pane",
    category = "pane",
  })

  register(hollow, "focus_pane_left", {
    run = function()
      host_api.focus_pane("left")
    end,
    desc = "Focus pane to the left",
    category = "pane",
  })

  register(hollow, "focus_pane_right", {
    run = function()
      host_api.focus_pane("right")
    end,
    desc = "Focus pane to the right",
    category = "pane",
  })

  register(hollow, "focus_pane_up", {
    run = function()
      host_api.focus_pane("up")
    end,
    desc = "Focus pane above",
    category = "pane",
  })

  register(hollow, "focus_pane_down", {
    run = function()
      host_api.focus_pane("down")
    end,
    desc = "Focus pane below",
    category = "pane",
  })

  register(hollow, "move_pane_left", {
    run = function()
      host_api.move_pane(nil, "left", 0.08)
    end,
    desc = "Move pane left",
    category = "pane",
  })

  register(hollow, "move_pane_right", {
    run = function()
      host_api.move_pane(nil, "right", 0.08)
    end,
    desc = "Move pane right",
    category = "pane",
  })

  register(hollow, "move_pane_up", {
    run = function()
      host_api.move_pane(nil, "up", 0.08)
    end,
    desc = "Move pane up",
    category = "pane",
  })

  register(hollow, "move_pane_down", {
    run = function()
      host_api.move_pane(nil, "down", 0.08)
    end,
    desc = "Move pane down",
    category = "pane",
  })

  register(hollow, "resize_pane_left", {
    run = function()
      host_api.resize_pane("vertical", -0.05)
    end,
    desc = "Resize pane left",
    category = "pane",
  })

  register(hollow, "resize_pane_right", {
    run = function()
      host_api.resize_pane("vertical", 0.05)
    end,
    desc = "Resize pane right",
    category = "pane",
  })

  register(hollow, "resize_pane_up", {
    run = function()
      host_api.resize_pane("horizontal", -0.05)
    end,
    desc = "Resize pane up",
    category = "pane",
  })

  register(hollow, "resize_pane_down", {
    run = function()
      host_api.resize_pane("horizontal", 0.05)
    end,
    desc = "Resize pane down",
    category = "pane",
  })

  -- ── Tab Actions ──────────────────────────────────

  register(hollow, "new_tab", {
    run = function()
      host_api.new_tab({})
    end,
    desc = "Create new tab",
    category = "tab",
    workspace_targetable = true,
  })

  register(hollow, "close_tab", {
    run = function()
      host_api.close_tab()
    end,
    desc = "Close current tab",
    category = "tab",
  })

  register(hollow, "next_tab", {
    run = function()
      host_api.next_tab()
    end,
    desc = "Switch to next tab",
    category = "tab",
  })

  register(hollow, "prev_tab", {
    run = function()
      host_api.prev_tab()
    end,
    desc = "Switch to previous tab",
    category = "tab",
  })

  register(hollow, "rename_tab", {
    run = function()
      local tab = hollow.term.current_tab()
      if not tab then
        return
      end
      hollow.ui.input.open({
        prompt = "Rename tab",
        default = tab.title,
        on_confirm = function(new_title)
          hollow.term.set_title(new_title, tab.id)
        end,
      })
    end,
    desc = "Rename current tab",
    category = "tab",
  })

  -- ── Workspace Actions ────────────────────────────

  register(hollow, "new_workspace", {
    run = function()
      host_api.new_workspace()
    end,
    desc = "Create new workspace",
    category = "workspace",
  })

  register(hollow, "workspace_switcher", {
    run = function()
      hollow.ui.workspace.open_switcher()
    end,
    desc = "Open workspace switcher",
    category = "workspace",
  })

  register(hollow, "create_workspace", {
    run = function()
      hollow.ui.workspace.create()
    end,
    desc = "Create workspace from prompt",
    category = "workspace",
  })

  register(hollow, "rename_workspace", {
    run = function()
      hollow.ui.workspace.rename()
    end,
    desc = "Rename current workspace",
    category = "workspace",
  })

  register(hollow, "close_workspace", {
    run = function()
      hollow.ui.workspace.close()
    end,
    desc = "Close current workspace",
    category = "workspace",
  })

  register(hollow, "next_workspace", {
    run = function()
      host_api.next_workspace()
    end,
    desc = "Switch to next workspace",
    category = "workspace",
  })

  register(hollow, "prev_workspace", {
    run = function()
      host_api.prev_workspace()
    end,
    desc = "Switch to previous workspace",
    category = "workspace",
  })

  -- ── Scroll Actions ───────────────────────────────

  register(hollow, "scrollback_line_up", {
    run = function()
      host_api.scroll_active(-1)
    end,
    desc = "Scroll up one line",
    category = "scroll",
  })

  register(hollow, "scrollback_line_down", {
    run = function()
      host_api.scroll_active(1)
    end,
    desc = "Scroll down one line",
    category = "scroll",
  })

  register(hollow, "scrollback_page_up", {
    run = function()
      host_api.scroll_active_page(-1)
    end,
    desc = "Scroll up one page",
    category = "scroll",
  })

  register(hollow, "scrollback_page_down", {
    run = function()
      host_api.scroll_active_page(1)
    end,
    desc = "Scroll down one page",
    category = "scroll",
  })

  register(hollow, "scrollback_top", {
    run = function()
      host_api.scroll_active_top()
    end,
    desc = "Scroll to top",
    category = "scroll",
  })

  register(hollow, "scrollback_bottom", {
    run = function()
      host_api.scroll_active_bottom()
    end,
    desc = "Scroll to bottom",
    category = "scroll",
  })

  register(hollow, "prompt_jump_prev", {
    run = function()
      host_api.prompt_jump("prev")
    end,
    desc = "Jump to previous prompt",
    category = "scroll",
  })

  register(hollow, "prompt_jump_next", {
    run = function()
      host_api.prompt_jump("next")
    end,
    desc = "Jump to next prompt",
    category = "scroll",
  })

  -- ── Copy Mode Actions ────────────────────────────

  register(hollow, "copy_mode", {
    run = function()
      copy_mode.enter()
    end,
    desc = "Enter copy mode",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_search", {
    run = function()
      if copy_mode.is_active() then
        host_api.copy_mode_open_search()
      else
        copy_mode.enter()
        host_api.copy_mode_open_search()
      end
    end,
    desc = "Search in copy mode",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_exit", {
    run = function()
      host_api.copy_mode_exit()
    end,
    desc = "Exit copy mode",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_move_left", {
    run = copy_mode_move("left"),
    desc = "Move cursor left",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_move_down", {
    run = copy_mode_move("down"),
    desc = "Move cursor down",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_move_up", {
    run = copy_mode_move("up"),
    desc = "Move cursor up",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_move_right", {
    run = copy_mode_move("right"),
    desc = "Move cursor right",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_page_up", {
    run = copy_mode_move("page_up"),
    desc = "Page up in copy mode",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_page_down", {
    run = copy_mode_move("page_down"),
    desc = "Page down in copy mode",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_line_start", {
    run = copy_mode_move("line_start"),
    desc = "Go to line start",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_line_end", {
    run = copy_mode_move("line_end"),
    desc = "Go to line end",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_top", {
    run = copy_mode_move("top"),
    desc = "Go to top of buffer",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_bottom", {
    run = copy_mode_move("bottom"),
    desc = "Go to bottom of buffer",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_begin_selection", {
    run = function()
      host_api.copy_mode_begin_selection(false)
    end,
    desc = "Begin selection",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_begin_block_selection", {
    run = function()
      host_api.copy_mode_begin_selection(true)
    end,
    desc = "Begin block selection",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_clear_selection", {
    run = function()
      host_api.copy_mode_clear_selection()
    end,
    desc = "Clear selection",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_copy_selection", {
    run = function()
      host_api.copy_mode_copy()
      host_api.copy_mode_exit()
    end,
    desc = "Copy selection and exit copy mode",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_search_next", {
    run = function()
      host_api.copy_mode_search_next()
    end,
    desc = "Search next match",
    category = "copy_mode",
  })

  register(hollow, "copy_mode_search_prev", {
    run = function()
      host_api.copy_mode_search_prev()
    end,
    desc = "Search previous match",
    category = "copy_mode",
  })

  -- ── General Actions ──────────────────────────────

  register(hollow, "copy_selection", {
    run = function()
      host_api.copy_selection()
    end,
    desc = "Copy selection to clipboard",
    category = "general",
  })

  register(hollow, "paste_clipboard", {
    run = function()
      host_api.paste_clipboard()
    end,
    desc = "Paste from clipboard",
    category = "general",
  })

  register(hollow, "quick_select", {
    run = function()
      host_api.quick_select_start("open")
    end,
    desc = "Open a visible URL by hint",
    category = "general",
  })

  register(hollow, "quick_select_copy", {
    run = function()
      host_api.quick_select_start("copy")
    end,
    desc = "Copy a visible URL by hint",
    category = "general",
  })

  register(hollow, "reload_config", {
    run = function()
      hollow.config.reload()
      hollow.ui.notify.info("Config reloaded", { ttl = 1200 })
    end,
    desc = "Reload configuration",
    category = "general",
  })

  local initial_font_size = (hollow.config.get("fonts") or {}).size or 14

  local function set_font_size(size)
    hollow.config.set({
      fonts = {
        size = size,
      },
    })
    hollow.ui.notify.info("Font size: " .. tostring(size), { ttl = 1200 })
  end

  local function adjust_font_size(delta)
    local fonts = hollow.config.get("fonts") or {}
    local size = tonumber(fonts.size) or initial_font_size
    set_font_size(math.max(6, size + delta))
  end

  register(hollow, "font_size_increase", {
    run = function()
      adjust_font_size(0.5)
    end,
    desc = "Increase font size",
    category = "general",
  })

  register(hollow, "font_size_decrease", {
    run = function()
      adjust_font_size(-0.5)
    end,
    desc = "Decrease font size",
    category = "general",
  })

  register(hollow, "font_size_reset", {
    run = function()
      set_font_size(initial_font_size)
    end,
    desc = "Reset font size to default",
    category = "general",
  })

  register(hollow, "command_palette", {
    run = function()
      hollow.ui.command_palette.open()
    end,
    desc = "Open command palette",
    category = "general",
  })

  local palette = hollow.ui.command_palette

  local function pick_workspace_and_run(fn)
    local entries = palette.build_workspace_entries()
    if #entries == 0 then
      fn(nil)
      return
    end
    if #entries == 1 then
      fn(entries[1])
      return
    end
    palette.open({
      prompt = "Target workspace",
      entries = entries,
      on_confirm = function(item)
        if item and item.workspace_index then
          host_api.switch_workspace(item.workspace_index - 1)
          fn(item)
        end
      end,
    })
  end

  local function pick_domain_and_run(fn)
    local entries = palette.build_domain_entries()
    if #entries == 0 then
      fn(nil)
      return
    end
    if #entries == 1 then
      fn(entries[1])
      return
    end
    palette.open({
      prompt = "Target domain",
      entries = entries,
      on_confirm = function(item)
        if item and item.domain_name then
          fn(item)
        end
      end,
    })
  end

  register(hollow, "split_vertical_in_domain", {
    run = function()
      pick_domain_and_run(function(item)
        hollow.term.split_pane("vertical", { domain = item.domain_name })
      end)
    end,
    desc = "Split pane vertically with a domain",
    category = "pane",
  })

  register(hollow, "split_horizontal_in_domain", {
    run = function()
      pick_domain_and_run(function(item)
        hollow.term.split_pane("horizontal", { domain = item.domain_name })
      end)
    end,
    desc = "Split pane horizontally with a domain",
    category = "pane",
  })

  register(hollow, "new_tab_in_domain", {
    run = function()
      pick_domain_and_run(function(item)
        host_api.new_tab({ domain = item.domain_name })
      end)
    end,
    desc = "Create new tab with a domain",
    category = "tab",
  })

  register(hollow, "move_tab_to_workspace", {
    run = function()
      local tab = hollow.term.current_tab()
      if not tab then
        return
      end
      pick_workspace_and_run(function(item)
        if item and item.workspace_index then
          host_api.move_tab_to_workspace(tab.id, item.workspace_index - 1)
        end
      end)
    end,
    desc = "Move current tab to workspace",
    category = "tab",
  })

  register(hollow, "move_pane_to_workspace", {
    run = function()
      local pane = hollow.term.current_pane()
      if not pane then
        return
      end
      pick_workspace_and_run(function(item)
        if item and item.workspace_index then
          host_api.move_pane_to_workspace(pane.id, item.workspace_index - 1)
        end
      end)
    end,
    desc = "Move current pane to workspace",
    category = "pane",
  })
end

return M
