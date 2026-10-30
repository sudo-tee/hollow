local M = {}
local shape = require("hollow.shape")

function M.setup(hollow, host_api)
  local registry = {}
  local overrides = {}
  local in_override = false
  local active_context

  local function copy(value, seen)
    if type(value) ~= "table" or shape.is_schema(value) then
      return value
    end
    seen = seen or {}
    if seen[value] then
      return seen[value]
    end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
      out[k] = copy(v, seen)
    end
    return out
  end

  local function prepare_arguments(name, ...)
    local args = { n = select("#", ...), ... }
    local schema = registry[name].arguments
    if schema then
      if args.n > 1 then
        error("typed actions accept one named argument table", 0)
      end
      local input = args[1]
      if input == nil then
        input = {}
      end
      if type(input) ~= "table" then
        error("action arguments must be a table", 0)
      end
      args = { n = 1, schema:parse(copy(input)) }
    end
    return args
  end

  local function make_context(name, ...)
    return {
      name = name,
      args = { n = select("#", ...), ... },
      pane = hollow.term.current_pane(),
      tab = hollow.term.current_tab(),
      workspace = hollow.term.current_workspace(),
    }
  end

  local function dispatch_body(name, ...)
    local handlers = overrides[name]
    if not in_override and handlers and #handlers > 0 then
      local ctx = make_context(name, ...)
      ctx.origin = active_context.origin
      ctx.caller = active_context.caller
      -- Snapshot the chain: additions take effect on the next invocation.
      local chain = {}
      for i, handler in ipairs(handlers) do
        chain[i] = handler
      end
      for _, handler in ipairs(chain) do
        if handler.active then
          in_override = true
          local ok, handled = pcall(handler.fn, ctx)
          in_override = false
          if not ok then
            pcall(
              hollow.ui.notify.error,
              "Action override " .. name .. " failed: " .. tostring(handled)
            )
          elseif handled then
            return
          end
        end
      end
    end
    return registry[name].run(...)
  end

  -- Preserve legacy callback signatures and multiple returns, even on nesting.
  local function dispatch_prepared(name, metadata, args)
    local ctx = make_context(name, unpack(args, 1, args.n))
    ctx.origin = metadata and metadata.origin or "lua"
    ctx.caller = metadata and copy(metadata.caller) or nil
    local previous = active_context
    active_context = ctx
    local function pack(...)
      return { n = select("#", ...), ... }
    end
    local result = pack(pcall(dispatch_body, name, unpack(args, 1, args.n)))
    active_context = previous
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2, result.n)
  end

  local function dispatch(name, metadata, ...)
    return dispatch_prepared(name, metadata, prepare_arguments(name, ...))
  end

  local function override(name, fn)
    if type(name) ~= "string" or not registry[name] then
      error("hollow.action.override: unknown action " .. tostring(name))
    end
    if type(fn) ~= "function" then
      error("hollow.action.override: handler must be a function")
    end
    local handler = { fn = fn, active = true }
    overrides[name] = overrides[name] or {}
    local handlers = overrides[name]
    handlers[#handlers + 1] = handler
    return function()
      if not handler.active then
        return
      end
      handler.active = false
      for i, item in ipairs(handlers) do
        if item == handler then
          table.remove(handlers, i)
          break
        end
      end
    end
  end

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
    if type(spec) ~= "table" then
      error("hollow.action.register: spec must be a table")
    end
    if type(name) ~= "string" or name == "" then
      error("hollow.action.register: name must be a non-empty string")
    end
    if
      name == "register"
      or name == "list"
      or name == "override"
      or name == "invoke"
      or name == "context"
    then
      error("reserved action name: " .. name)
    end
    if type(spec.run) ~= "function" then
      error("hollow.action.register: run must be a function")
    end
    if spec.arguments ~= nil and not shape.is_schema(spec.arguments) then
      error("hollow.action.register: arguments must be a hollow.shape schema")
    end
    if spec.available ~= nil and type(spec.available) ~= "function" then
      error("hollow.action.register: available must be a function")
    end
    if spec.keys ~= nil and type(spec.keys) ~= "table" then
      error("hollow.action.register: keys must be an array of chords")
    end
    for _, chord in ipairs(spec.keys or {}) do
      if type(chord) ~= "string" then
        error("hollow.action.register: keys must contain only chord strings")
      end
    end
    if spec.keys and #spec.keys > 0 and type(hollow.keymap.default) ~= "function" then
      error("hollow.action.register: keymap must be initialized before registering keys")
    end

    -- Schema objects keep their metatables and parser closures intact.
    registry[name] = copy(spec)
    hollow.action[name] = function(...)
      return dispatch(name, nil, ...)
    end

    if spec.keys then
      for _, chord in ipairs(spec.keys) do
        hollow.keymap.default(chord, name, { desc = spec.desc })
      end
    end
  end

  local function list()
    local entries = {}
    for name, spec in pairs(registry) do
      entries[#entries + 1] = {
        name = name,
        desc = spec.desc or "",
        category = spec.category or "general",
        run = hollow.action[name],
        available = spec.available,
        workspace_targetable = spec.workspace_targetable or false,
        arguments = copy(spec.arguments),
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
          debug = 9,
        }
        return (cat_order[a.category] or 99) < (cat_order[b.category] or 99)
      end
      return a.name < b.name
    end)
    return entries
  end

  local copy_mode = require("hollow.copy_mode")

  ---@type HollowActionNamespace
  hollow.action = hollow.action or {}
  hollow.action.register = function(name, spec)
    register(hollow, name, spec)
  end
  hollow.action.list = list
  hollow.action.override = override
  hollow.action.context = function()
    return copy(active_context)
  end
  hollow.action.invoke = function(name, args, ctx)
    if type(name) ~= "string" or not registry[name] then
      return { success = false, status = "unknown_action", error = "Unknown action" }
    end
    if
      ctx ~= nil
      and (
        type(ctx) ~= "table"
        or (ctx.origin ~= nil and type(ctx.origin) ~= "string")
        or (ctx.caller ~= nil and type(ctx.caller) ~= "table")
      )
    then
      return { success = false, status = "invalid_context", error = "Invalid action context" }
    end
    if args ~= nil and type(args) ~= "table" then
      return {
        success = false,
        status = "invalid_arguments",
        error = "Action arguments must be a table",
      }
    end
    local ok, prepared
    if args == nil then
      ok, prepared = pcall(prepare_arguments, name)
    else
      ok, prepared = pcall(prepare_arguments, name, args)
    end
    if not ok then
      return { success = false, status = "invalid_arguments", error = tostring(prepared) }
    end
    local ok, value = pcall(dispatch_prepared, name, ctx, prepared)
    if not ok then
      return { success = false, status = "action_failed", error = tostring(value) }
    end
    return { success = true, status = "ok", value = value }
  end

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
    run = function(opts)
      host_api.new_tab(opts or {})
    end,
    desc = "Create new tab",
    category = "tab",
    workspace_targetable = true,
  })

  register(hollow, "close_tab", {
    run = function(opts)
      if opts and opts.tab_id then
        hollow.term.close_tab(opts.tab_id)
      else
        host_api.close_tab()
      end
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

  register(hollow, "save_workspace", {
    run = function()
      local path = hollow.workspace.project_local_path()
      if path == nil then
        hollow.ui.notify.warn("Could not resolve project directory", { ttl = 1800 })
        return
      end
      hollow.workspace.export_to(path)
      hollow.ui.notify.info("Saved workspace layout to " .. path, { ttl = 1800 })
    end,
    desc = "Save current workspace layout to project directory",
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
    desc = "Open links or copy visible text by hint",
    category = "general",
  })

  register(hollow, "quick_select_copy", {
    run = function()
      host_api.quick_select_start("copy")
    end,
    desc = "Copy a visible quick-select match by hint",
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

  register(hollow, "mux_navigator", {
    run = function()
      hollow.ui.mux_navigator.open()
    end,
    desc = "Navigate workspaces, tabs, and panes",
    category = "pane",
  })

  register(hollow, "attention_navigator", {
    run = function()
      hollow.ui.mux_navigator.open({
        filter = "pane_bell",
        title = "Attention",
      })
    end,
    desc = "Jump to panes with pending attention (bells or status)",
    category = "pane",
  })

  register(hollow, "activity_center", {
    run = function()
      hollow.ui.activity.open()
    end,
    desc = "Open activity inbox and running programs",
    category = "general",
  })

  register(hollow, "notification_history", {
    run = function()
      hollow.ui.activity.open({ view = "history" })
    end,
    desc = "Open session notification and activity history",
    category = "general",
  })

  register(hollow, "lua_repl", {
    run = function()
      return hollow.ui.lua_repl.open()
    end,
    desc = "Open Lua REPL (live runtime)",
    category = "debug",
  })

  register(hollow, "toggle_layout_inspector", {
    run = function()
      hollow.ui.layout.debug(not hollow.ui._layout_debug)
    end,
    desc = "Toggle Clay inspector for the active layout surface",
    category = "debug",
  })

  register(hollow, "toggle_grid_inspector", {
    run = function()
      hollow.ui.layout.debug_grid(not hollow.ui._layout_debug_grid)
    end,
    desc = "Toggle Clay inspector for bars, sidebar and panes",
    category = "debug",
  })

  register(hollow, "inspector_wider", {
    run = function()
      hollow.ui.layout.debug_width(hollow.ui.layout.debug_width() + 100)
    end,
    desc = "Widen the Clay inspector panel by 100 px",
    category = "debug",
  })

  register(hollow, "inspector_narrower", {
    run = function()
      hollow.ui.layout.debug_width(hollow.ui.layout.debug_width() - 100)
    end,
    desc = "Narrow the Clay inspector panel by 100 px",
    category = "debug",
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
    run = function(opts)
      pick_domain_and_run(function(item)
        host_api.new_tab({ domain = item.domain_name, insert_at_end = opts and opts.insert_at_end })
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
