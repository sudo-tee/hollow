local M = {}

local function window_size_snapshot(host_api)
  return {
    rows = 0,
    cols = 0,
    width = host_api.get_window_width and host_api.get_window_width() or 0,
    height = host_api.get_window_height and host_api.get_window_height() or 0,
  }
end

local function is_span_node(value)
  return type(value) == "table"
    and (
      value._type == "span"
      or value._type == "spacer"
      or value._type == "icon"
      or value._type == "group"
    )
end

function M.setup(hollow, host_api, state, util)
  local function safe_call(fn, default)
    if type(fn) ~= "function" then
      return default
    end
    local ok, value = pcall(fn)
    if ok and value ~= nil then
      return value
    end
    return default
  end

  local mounted_topbar = function()
    return state.ui.mounted_topbar
  end

  local mounted_bottombar = function()
    return state.ui.mounted_bottombar
  end

  local mounted_sidebar = function()
    return state.ui.mounted_sidebar
  end

  local overlay_stack = state.ui.overlay_stack

  local function widget_ctx()
    local current_tab = safe_call(hollow.term.current_tab, nil)
    local current_pane = safe_call(hollow.term.current_pane, nil)
    return {
      term = {
        tab = current_tab,
        pane = current_pane,
        tabs = safe_call(hollow.term.tabs, {}),
        workspace = safe_call(hollow.term.current_workspace, nil),
        workspaces = safe_call(hollow.term.workspaces, {}),
      },
      size = window_size_snapshot(host_api),
      time = {
        epoch_ms = math.floor(os.time() * 1000),
        iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      },
    }
  end

  local function render_widget(widget)
    if widget == nil or type(widget.render) ~= "function" then
      return nil
    end
    local ok_ctx, ctx = pcall(widget_ctx)
    if not ok_ctx then
      return nil
    end
    local ok, rendered = pcall(widget.render, ctx)
    if not ok then
      return nil
    end
    return rendered
  end

  local function normalize_widget_rows(rendered)
    if type(rendered) ~= "table" then
      return { {} }
    end

    local first = rendered[1]
    if first == nil or is_span_node(first) then
      return { rendered }
    end

    local rows = {}
    for _, row in ipairs(rendered) do
      if type(row) == "table" then
        rows[#rows + 1] = row
      end
    end
    return rows
  end

  local function render_widget_rows(widget)
    local rendered = render_widget(widget)
    if rendered == nil then
      return { {} }
    end
    return normalize_widget_rows(rendered)
  end

  local function flatten_span_nodes(nodes, inherited_style, out)
    out = out or {}
    inherited_style = inherited_style or {}
    for _, node in ipairs(nodes or {}) do
      if type(node) == "table" then
        if node._type == "group" then
          local merged_style = util.clone_value(inherited_style)
          if type(node.style) == "table" then
            util.merge_tables(merged_style, node.style)
          end
          flatten_span_nodes(node.children or {}, merged_style, out)
        elseif node._type == "spacer" then
          out[#out + 1] = { text = " ", spacer = true, style = util.clone_value(inherited_style) }
        elseif node._type == "icon" then
          local style = util.clone_value(inherited_style)
          if type(node.style) == "table" then
            util.merge_tables(style, node.style)
          end
          out[#out + 1] = { text = node.name or "", style = style }
        elseif node._type == "span" then
          local style = util.clone_value(inherited_style)
          if type(node.style) == "table" then
            util.merge_tables(style, node.style)
          end
          out[#out + 1] = { text = node.text or "", style = style }
        end
      end
    end
    return out
  end

  local function style_to_segment(text, style)
    local segment = { text = text }
    if type(style) == "string" and style:match("^#%x%x%x%x%x%x$") then
      segment.fg = style
      return segment
    end
    if type(style) == "table" and type(style.style) == "table" then
      style = style.style
    end
    if type(style) == "table" then
      segment.bold = style.bold == true
      if type(style.id) == "string" and style.id ~= "" then
        segment.id = style.id
      end
      if type(style.fg) == "string" and style.fg:match("^#%x%x%x%x%x%x$") then
        segment.fg = style.fg
      end
      if type(style.bg) == "string" and style.bg:match("^#%x%x%x%x%x%x$") then
        segment.bg = style.bg
      end
    end
    return segment
  end

  local function merge_style_tables(base, overlay)
    local merged = {}
    if type(base) == "table" then
      util.merge_tables(merged, base)
    end
    if type(overlay) == "table" then
      util.merge_tables(merged, overlay)
    end
    return merged
  end

  local function normalize_bar_items(rendered)
    if type(rendered) ~= "table" then
      return {}
    end
    if rendered._type ~= nil then
      return { rendered }
    end
    return rendered
  end

  local function bar_value_to_segment(value, fallback_text, style)
    if type(value) == "string" then
      return style_to_segment(value, style)
    end

    if type(value) == "table" then
      if value._type == "span" then
        return style_to_segment(value.text or fallback_text, merge_style_tables(style, value.style))
      end

      if value.text ~= nil or value.fg ~= nil or value.bg ~= nil or value.bold ~= nil then
        local merged_style = merge_style_tables(style, {
          fg = value.fg,
          bg = value.bg,
          bold = value.bold,
        })
        return style_to_segment(
          type(value.text) == "string" and value.text or fallback_text,
          merged_style
        )
      end
    end

    return style_to_segment(fallback_text, style)
  end

  local function dispatch_widget_event(name, e)
    local widgets = {}
    if mounted_topbar() ~= nil then
      widgets[#widgets + 1] = mounted_topbar()
    end
    if mounted_bottombar() ~= nil then
      widgets[#widgets + 1] = mounted_bottombar()
    end
    if mounted_sidebar() ~= nil then
      widgets[#widgets + 1] = mounted_sidebar()
    end
    for _, widget in ipairs(overlay_stack) do
      widgets[#widgets + 1] = widget
    end
    for _, widget in ipairs(widgets) do
      if type(widget.on_event) == "function" then
        widget.on_event(name, e)
      end
    end
  end

  local function dispatch_overlay_key(key, mods)
    local canonical_mods = hollow.keymap._format_mods(mods)
    for i = #overlay_stack, 1, -1 do
      local widget = overlay_stack[i]
      if type(widget.on_key) == "function" then
        local ok, consumed = pcall(widget.on_key, key, canonical_mods)
        if ok and consumed then
          return true
        end
      end
    end
    return false
  end

  local function widget_fill_segments(row)
    local flattened = flatten_span_nodes(row or {})
    local segments = {}
    for _, node in ipairs(flattened) do
      if not node.spacer then
        segments[#segments + 1] = style_to_segment(node.text or "", node.style)
      end
    end
    return segments
  end

  local function trim_row_for_width(row, max_chars)
    local flattened = flatten_span_nodes(row or {})
    local segments = {}
    local remaining = math.max(0, math.floor(max_chars or 0))
    for _, node in ipairs(flattened) do
      if remaining <= 0 then
        break
      end
      if not node.spacer then
        local text = node.text or ""
        if #text > remaining then
          text = text:sub(1, remaining)
        end
        if #text > 0 then
          segments[#segments + 1] = style_to_segment(text, node.style)
          remaining = remaining - #text
        end
      end
    end
    return segments
  end

  local function validate_widget_opts(opts)
    if type(opts) ~= "table" then
      error("widget opts must be a table")
    end
    if type(opts.render) ~= "function" then
      error("widget opts.render must be a function")
    end
    return opts
  end

  local function make_widget(kind, opts)
    opts = validate_widget_opts(opts)
    return {
      _kind = kind,
      render = opts.render,
      on_event = opts.on_event,
      on_key = opts.on_key,
      on_mount = opts.on_mount,
      on_unmount = opts.on_unmount,
      height = opts.height,
      width = opts.width,
      side = opts.side,
      hidden = opts.hidden,
      reserve = opts.reserve,
    }
  end

  function hollow.ui.span(text, style)
    return { _type = "span", text = text, style = style }
  end

  function hollow.ui.spacer()
    return { _type = "spacer" }
  end

  function hollow.ui.icon(name, style)
    return { _type = "icon", name = tostring(name or ""), style = style }
  end

  function hollow.ui.group(children, style)
    return { _type = "group", children = children or {}, style = style }
  end

  function hollow.ui.button(opts)
    opts = opts or {}
    local style = util.clone_value(opts.style or {})
    style.id = opts.id
    style.on_click = opts.on_click
    style.on_mouse_enter = opts.on_mouse_enter
    style.on_mouse_leave = opts.on_mouse_leave
    return hollow.ui.span(opts.text or "", style)
  end

  hollow.ui.bar = hollow.ui.bar or {}

  -- Bar item constructors are shared across bar surfaces.
  function hollow.ui.bar.tabs(opts)
    opts = opts or {}
    opts._type = "bar_tabs"
    return opts
  end

  function hollow.ui.bar.workspace(opts)
    opts = opts or {}
    opts._type = "bar_workspace"
    return opts
  end

  function hollow.ui.bar.time(fmt, opts)
    opts = opts or {}
    opts._type = "bar_time"
    opts.format = fmt
    return opts
  end

  function hollow.ui.bar.key_legend(opts)
    opts = opts or {}
    opts._type = "bar_key_legend"
    return opts
  end

  function hollow.ui.bar.custom(opts)
    opts = opts or {}
    if type(opts.render) ~= "function" then
      error("hollow.ui.bar.custom(opts) expects opts.render")
    end
    return {
      _type = "bar_custom",
      id = opts.id,
      render = opts.render,
      on_click = opts.on_click,
      on_mouse_enter = opts.on_mouse_enter,
      on_mouse_leave = opts.on_mouse_leave,
    }
  end

  hollow.ui.topbar = hollow.ui.topbar or {}

  function hollow.ui.topbar.new(opts)
    return make_widget("topbar", opts)
  end

  function hollow.ui.topbar.mount(widget)
    if state.ui.mounted_topbar ~= nil and state.ui.mounted_topbar.on_unmount then
      state.ui.mounted_topbar.on_unmount()
    end
    state.ui.mounted_topbar = widget
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.topbar.unmount()
    local widget = state.ui.mounted_topbar
    if widget and widget.on_unmount then
      widget.on_unmount()
    end
    state.ui.mounted_topbar = nil
  end

  function hollow.ui.topbar.invalidate()
    return state.ui.mounted_topbar ~= nil
  end

  hollow.ui.bottombar = hollow.ui.bottombar or {}

  function hollow.ui.bottombar.new(opts)
    return make_widget("bottombar", opts)
  end

  function hollow.ui.bottombar.mount(widget)
    if state.ui.mounted_bottombar ~= nil and state.ui.mounted_bottombar.on_unmount then
      state.ui.mounted_bottombar.on_unmount()
    end
    state.ui.mounted_bottombar = widget
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.bottombar.unmount()
    local widget = state.ui.mounted_bottombar
    if widget and widget.on_unmount then
      widget.on_unmount()
    end
    state.ui.mounted_bottombar = nil
  end

  function hollow.ui.bottombar.invalidate()
    return state.ui.mounted_bottombar ~= nil
  end

  hollow.ui.sidebar = hollow.ui.sidebar or {}

  function hollow.ui.sidebar.new(opts)
    return make_widget("sidebar", opts)
  end

  function hollow.ui.sidebar.mount(widget)
    if state.ui.mounted_sidebar ~= nil and state.ui.mounted_sidebar.on_unmount then
      state.ui.mounted_sidebar.on_unmount()
    end
    state.ui.mounted_sidebar = widget
    state.ui.sidebar_visible = widget.hidden ~= true
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.sidebar.unmount()
    if state.ui.mounted_sidebar and state.ui.mounted_sidebar.on_unmount then
      state.ui.mounted_sidebar.on_unmount()
    end
    state.ui.mounted_sidebar = nil
    state.ui.sidebar_visible = false
  end

  function hollow.ui.sidebar.toggle()
    if state.ui.mounted_sidebar == nil then
      return false
    end
    state.ui.sidebar_visible = not state.ui.sidebar_visible
    return state.ui.sidebar_visible
  end

  function hollow.ui.sidebar.invalidate()
    return state.ui.mounted_sidebar ~= nil
  end

  hollow.ui.overlay = hollow.ui.overlay or {}

  function hollow.ui.overlay.new(opts)
    return make_widget("overlay", opts)
  end

  function hollow.ui.overlay.push(widget)
    table.insert(overlay_stack, widget)
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.overlay.pop()
    local widget = table.remove(overlay_stack)
    if widget and widget.on_unmount then
      widget.on_unmount()
    end
    return widget
  end

  function hollow.ui.overlay.clear()
    while #overlay_stack > 0 do
      hollow.ui.overlay.pop()
    end
  end

  function hollow.ui.overlay.depth()
    return #overlay_stack
  end

  local function mounted_bar_widget(surface)
    if surface == "topbar" then
      return state.ui.mounted_topbar
    end
    if surface == "bottombar" then
      return state.ui.mounted_bottombar
    end
    return nil
  end

  local function hovered_bar_id_key(surface)
    if surface == "topbar" then
      return "topbar_hovered_id"
    end
    if surface == "bottombar" then
      return "bottombar_hovered_id"
    end
    return nil
  end

  local function call_bar_node_handler(surface, node_id, field, payload)
    local widget = mounted_bar_widget(surface)
    if widget == nil or type(node_id) ~= "string" or node_id == "" then
      return false
    end

    local rendered = normalize_bar_items(render_widget(widget))

    local function visit(nodes)
      for _, node in ipairs(nodes) do
        if type(node) == "table" then
          if node._type == "group" then
            if visit(node.children or {}) then
              return true
            end
          elseif node._type == "bar_custom" and type(node.id) == "string" and node.id == node_id then
            if type(node[field]) == "function" then
              node[field](payload)
              return true
            end
          else
            local style = node.style
            if
              type(style) == "table"
              and style.id == node_id
              and type(style[field]) == "function"
            then
              style[field](payload)
              return true
            end
          end
        end
      end
      return false
    end

    return visit(rendered)
  end

  local function handle_bar_node_event(kind, payload)
    if type(payload) ~= "table" then
      return
    end
    local node_id = payload.id
    if type(node_id) ~= "string" or node_id == "" then
      return
    end

    local surface = kind:match("^(%a+bar):")
    if surface ~= "topbar" and surface ~= "bottombar" then
      return
    end
    local hovered_key = hovered_bar_id_key(surface)
    if hovered_key == nil then
      return
    end

    if kind == surface .. ":hover" then
      if state.ui[hovered_key] ~= node_id then
        if state.ui[hovered_key] ~= nil then
          call_bar_node_handler(surface, state.ui[hovered_key], "on_mouse_leave", { id = state.ui[hovered_key] })
        end
        state.ui[hovered_key] = node_id
        call_bar_node_handler(surface, node_id, "on_mouse_enter", payload)
      end
      return
    end

    if kind == surface .. ":leave" then
      if state.ui[hovered_key] ~= nil then
        call_bar_node_handler(surface, state.ui[hovered_key], "on_mouse_leave", { id = state.ui[hovered_key] })
        state.ui[hovered_key] = nil
      end
      return
    end

    if kind == surface .. ":click" then
      call_bar_node_handler(surface, node_id, "on_click", payload)
    end
  end

  local serialize_bar_item

  local function serialize_bar_widget(widget)
    if widget == nil then
      return nil
    end
    local ctx = widget_ctx()
    local items = normalize_bar_items(render_widget(widget))
    local out = {}
    for _, item in ipairs(items) do
      local ok, serialized = pcall(serialize_bar_item, item, ctx)
      if serialized ~= nil then
        out[#out + 1] = serialized
      end
    end
    return out
  end

  serialize_bar_item = function(node, ctx)
    if type(node) ~= "table" then
      return nil
    end

    if node._type == "bar_tabs" then
      local tabs = {}
      for _, tab in ipairs(ctx.term.tabs or {}) do
        local tab_state = {
          id = tab.id,
          title = tab.title ~= "" and tab.title or "shell",
          index = tab.index,
          is_active = tab.is_active == true,
          is_hovered = false,
          is_hover_close = false,
          pane = tab.pane,
          panes = tab.panes or {},
        }
        local style = node.style
        if type(style) == "function" then
          local ok, resolved = pcall(style, tab_state, ctx)
          style = ok and resolved or nil
        end
        local label = tab_state.title
        if type(node.format) == "function" then
          local ok, resolved = pcall(node.format, tab_state, ctx)
          if ok then
            label = resolved
          end
        end
        local seg = bar_value_to_segment(label, tab_state.title, style)
        tabs[#tabs + 1] = seg
      end
      return {
        kind = "tabs",
        fit = node.fit == "content" and "content" or "fill",
        tabs = tabs,
      }
    end

    if node._type == "bar_workspace" then
      local ws = ctx.term.workspace
      local workspace_state = {
        index = ws and ws.index or 1,
        name = ws and ws.name or "ws",
        is_active = true,
        active_index = ws and ws.index or 1,
        count = #ctx.term.workspaces,
      }
      local text = workspace_state.name
      if type(node.format) == "function" then
        local ok, resolved = pcall(node.format, workspace_state, ctx)
        if ok and type(resolved) == "string" then
          text = resolved
        end
      end
      local style = node.style
      if type(style) == "function" then
        local ok, resolved = pcall(style, workspace_state, ctx)
        style = ok and resolved or nil
      end
      local seg = bar_value_to_segment(text, workspace_state.name, style)
      seg.kind = "segment"
      return seg
    end

    if node._type == "bar_time" then
      local seg = style_to_segment(os.date(node.format or "%H:%M"), node.style)
      seg.kind = "segment"
      return seg
    end

    if node._type == "bar_key_legend" then
      local leader_state = hollow.keymap.get_leader_state()
      local text = ""
      if
        leader_state
        and leader_state.active
        and leader_state.next_display
        and #leader_state.next_display > 0
      then
        text = " " .. table.concat(leader_state.next_display, "  ") .. " "
      end
      local seg = style_to_segment(text, node.style)
      seg.kind = "segment"
      return seg
    end

    if node._type == "bar_custom" then
      local ok, rendered = pcall(node.render, ctx)
      if not ok then
        return nil
      end
      local seg = nil
      if type(rendered) == "string" then
        seg = { kind = "segment", text = rendered, id = node.id }
      elseif type(rendered) == "table" then
        seg = style_to_segment(rendered.text or "", rendered.style or rendered)
        seg.kind = "segment"
        seg.id = seg.id or node.id
      end
      return seg
    end

    if node._type == "spacer" then
      return { kind = "spacer" }
    end

    if is_span_node(node) then
      local seg = style_to_segment(node.text or node.name or "", node.style)
      seg.kind = "segment"
      return seg
    end

    return nil
  end

  function hollow.ui._topbar_state()
    return serialize_bar_widget(state.ui.mounted_topbar)
  end

  function hollow.ui._bottombar_state()
    return serialize_bar_widget(state.ui.mounted_bottombar)
  end

  function hollow.ui._bottombar_layout()
    if state.ui.mounted_bottombar == nil then
      return nil
    end
    local height = tonumber(state.ui.mounted_bottombar.height) or 0
    return {
      height = math.max(0, math.floor(height)),
    }
  end

  function hollow.ui._sidebar_state()
    if state.ui.mounted_sidebar == nil or not state.ui.sidebar_visible then
      return nil
    end
    local rows = render_widget_rows(state.ui.mounted_sidebar)
    local side = state.ui.mounted_sidebar.side == "right" and "right" or "left"
    local width = tonumber(state.ui.mounted_sidebar.width) or 24
    local segments = {}
    for i, row in ipairs(rows) do
      segments[i] = trim_row_for_width(row, width)
    end
    return {
      side = side,
      width = math.max(1, math.floor(width)),
      reserve = state.ui.mounted_sidebar.reserve == true,
      rows = segments,
    }
  end

  function hollow.ui._overlay_state()
    if #overlay_stack == 0 then
      return nil
    end
    local rows = {}
    for _, widget in ipairs(overlay_stack) do
      local widget_rows = render_widget_rows(widget)
      local seg_rows = {}
      for i, row in ipairs(widget_rows) do
        seg_rows[i] = widget_fill_segments(row)
      end
      rows[#rows + 1] = seg_rows
    end
    return rows
  end

  hollow.ui.notify = hollow.ui.notify or {}

  function hollow.ui.notify.show(message, opts)
    opts = opts or {}
    local title = opts.title and (opts.title .. ": ") or ""
    local ttl = opts.ttl
    local action = opts.action
    local widget = hollow.ui.overlay.new({
      render = function()
        local prefix = "[" .. string.upper(opts.level or "info") .. "] "
        local action_text = action and ("  [" .. action.label .. "]") or ""
        return {
          {
            hollow.ui.group({
              hollow.ui.span(prefix .. title .. message .. action_text, {
                fg = opts.level == "error" and "#ffb4a9" or "#d8dee9",
                bg = "#1f2430",
                bold = true,
              }),
            }, { bg = "#1f2430" }),
          },
        }
      end,
      on_key = function(key)
        if key == "escape" or key == "enter" then
          hollow.ui.overlay.pop()
          if action and key == "enter" and type(action.fn) == "function" then
            action.fn()
          end
          return true
        end
        return false
      end,
    })
    hollow.ui.overlay.push(widget)
    if type(ttl) == "number" and ttl > 0 then
      widget._expires_at = math.floor(os.clock() * 1000) + ttl
    end
    return widget
  end

  function hollow.ui.notify.clear()
    state.ui.notifications = {}
  end

  function hollow.ui.notify.info(message, opts)
    opts = opts or {}
    if opts.level == nil then
      opts.level = "info"
    end
    return hollow.ui.notify.show(message, opts)
  end

  function hollow.ui.notify.warn(message, opts)
    opts = opts or {}
    if opts.level == nil then
      opts.level = "warn"
    end
    return hollow.ui.notify.show(message, opts)
  end

  function hollow.ui.notify.error(message, opts)
    opts = opts or {}
    if opts.level == nil then
      opts.level = "error"
    end
    return hollow.ui.notify.show(message, opts)
  end

  hollow.ui.input = hollow.ui.input or {}

  function hollow.ui.input.open(opts)
    local state_local = {
      prompt = opts.prompt or "",
      value = opts.default or "",
    }
    local widget
    widget = hollow.ui.overlay.new({
      render = function()
        return {
          {
            hollow.ui.span(state_local.prompt .. state_local.value, {
              fg = "#d8dee9",
              bg = "#20242f",
            }),
          },
        }
      end,
      on_key = function(key)
        if key == "escape" then
          hollow.ui.overlay.pop()
          if type(opts.on_cancel) == "function" then
            opts.on_cancel()
          end
          return true
        end
        if key == "enter" then
          hollow.ui.overlay.pop()
          if type(opts.on_confirm) == "function" then
            opts.on_confirm(state_local.value)
          end
          return true
        end
        if key == "backspace" then
          state_local.value = state_local.value:sub(1, math.max(0, #state_local.value - 1))
          return true
        end
        if #key == 1 then
          state_local.value = state_local.value .. key
          return true
        end
        return false
      end,
    })
    hollow.ui.overlay.push(widget)
  end

  function hollow.ui.input.close()
    hollow.ui.overlay.pop()
  end

  hollow.ui.select = hollow.ui.select or {}

  function hollow.ui.select.open(opts)
    local state_local = { index = 1 }
    local items = opts.items or {}
    local label = opts.label or tostring
    local widget
    widget = hollow.ui.overlay.new({
      render = function()
        local rows = {}
        rows[#rows + 1] = {
          hollow.ui.span((opts.prompt or "Select") .. ":", { fg = "#88c0d0", bold = true }),
        }
        for i, item in ipairs(items) do
          local prefix = i == state_local.index and "> " or "  "
          rows[#rows + 1] = {
            hollow.ui.span(prefix .. label(item), {
              fg = i == state_local.index and "#eceff4" or "#d8dee9",
              bg = i == state_local.index and "#3b4252" or nil,
              bold = i == state_local.index,
            }),
          }
        end
        return rows
      end,
      on_key = function(key)
        if key == "escape" then
          hollow.ui.overlay.pop()
          if type(opts.on_cancel) == "function" then
            opts.on_cancel()
          end
          return true
        end
        if key == "arrow_down" then
          state_local.index = math.min(#items, state_local.index + 1)
          return true
        end
        if key == "arrow_up" then
          state_local.index = math.max(1, state_local.index - 1)
          return true
        end
        if key == "enter" then
          local action = opts.actions and opts.actions[1]
          local item = items[state_local.index]
          if action and item ~= nil then
            action.fn(item)
          end
          return true
        end
        return false
      end,
    })
    hollow.ui.overlay.push(widget)
  end

  function hollow.ui.select.close()
    hollow.ui.overlay.pop()
  end

  return {
    dispatch_widget_event = dispatch_widget_event,
    dispatch_overlay_key = dispatch_overlay_key,
    handle_bar_node_event = handle_bar_node_event,
  }
end

return M
