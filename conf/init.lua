local hwl = hollow
local theme = {
  widgets = {
    all = {
      panel_bg = "#1b1f2a",
      panel_border = "#7e9cd8",
      title = "#7fb4ca",
      fg = "#dcd7ba",
      input_bg = "#222733",
      input_fg = "#dcd7ba",
      cursor_bg = "#dcd7ba",
      cursor_fg = "#1f1f28",
      divider = "#2d3445",
      backdrop = { color = "#000000", alpha = 40 },
    },
    select = {
      selected_bg = "#2a3142",
      selected_detail_bg = "#232938",
      scrollbar_thumb = "#e0af68",
    },
    notify = {
      notify_levels = {
        info = "#7fb4ca",
        warn = "#e0af68",
        error = "#ff5d62",
        success = "#98bb6c",
      },
    },
  },
  tab_bar = {
    background = "#2A2A37",
    active_tab = {
      bg = "#1F1F28",
      fg = "#e0af68",
      bold = true,
    },
    inactive_tab = {
      bg = "#2A2A37",
      fg = "#dcd7ba",
    },
    hover_tab = {
      bg = "#2A2A37",
      fg = "#dcd7ba",
    },
    badge = {
      fg = "#e0af68",
      bg = "#2A2A37",
      bold = true,
    },
    hover_close_bg = "#5a2d35",
  },
  scrollbar = {
    track = "#1b1d25",
    thumb = "#5f667a",
    thumb_hover = "#7a839b",
    thumb_active = "#9fb8e8",
    border = "#2d3140",
  },
  split = "#766b90",
  accent = "#7e9cd8",
  warm = "#e0af68",
  status = {
    bg = "#2A2A37",
    fg = "#7e9cd8",
  },
  workspace = {
    active = {
      fg = "#1F1F28",
      bg = "#7e9cd8",
    },
    inactive = {
      fg = "#dcd7ba",
      bg = "#2A2A37",
    },
  },

  foreground = "#dcd7ba",
  background = "#1F1F28",
  cursor_bg = "#c8c093",
  cursor_fg = "#0d0c0c",
  cursor_border = "#c8c093",
  selection_fg = "#c8c093",
  selection_bg = "#0d0c0c",
  ansi = {
    "#090618", -- Black
    "#c34043", -- Maroon
    "#76946a", -- Green
    "#c0a36e", -- Olive
    "#7e9cd8", -- Navy
    "#957fb8", -- Purple
    "#6a9589", -- Teal
    "#c8c093", -- Silver
  },
  brights = {
    "#727169", -- Grey
    "#e82424", -- Red
    "#98bb6c", -- Lime
    "#e6c384", -- Yellow
    "#7fb4ca", -- Blue
    "#938aa9", -- Fuchsia
    "#7aa89f", -- Aqua
    "#dcd7ba", -- White
  },
  indexed = { [16] = "#ffa066", [17] = "#ff5d62" },
}

-- g.log("loading native rewrite config")

hwl.config.set({
  debug_overlay = true,
  backend = "sokol",
  vsync = false,
  max_fps = 120,
  padding = 0,
  theme = theme,
  fonts = {
    size = 14.5,
    line_height = 0.9,
    padding_x = 0,
    padding_y = 0,
    smoothing = "grayscale",
    hinting = "light",
    ligatures = true,
    -- coverage_boost = 1.0,
    -- coverage_add = 0,
    embolden = 0.33,
    regular = "fonts/RecMonoDuotone-Regular-1.085.ttf",
    bold = "fonts/RecMonoLinear-Bold-1.085.ttf",
    italic = "fonts/RecMonoDuotone-Italic-1.085.ttf",
    bold_italic = "fonts/RecMonoDuotone-BoldItalic-1.085.ttf",
    fallbacks = {
      -- Extra user fallbacks can be added here; native also bundles
      -- Symbols Nerd Font Mono and Noto Sans Symbols 2 by default.
    },
  },
  cols = 120,
  rows = 34,
  -- Scrollback is measured in bytes, not lines.
  -- 64 MB retains far more history for wide terminals.
  window_title = "hollow",
  window_width = 1440,
  window_height = 900,
  window_titlebar_show = false,
  top_bar_show = true,
  top_bar_show_when_single_tab = true,
  top_bar_height = 20,
  top_bar_bg = theme.tab_bar.background,
  top_bar_draw_tabs = true,
  top_bar_draw_status = true,
  scrollback = 64000000,
  scrollbar = {
    enabled = false,
    width = 14,
    min_thumb_size = 24,
    margin = 2,
    jump_to_click = true,
    track = "#1b1d25",
    thumb = "#5f667a",
    thumb_hover = "#7a839b",
    thumb_active = "#9fb8e8",
    border = "#2d3140",
  },
  hyperlinks = {
    enabled = true,
    shift_click_only = true,
    match_www = true,
    prefixes = "https:// http:// file:// ftp:// mailto:",
    delimiters = " \t\r\n\"'<>[]{}|\\^`",
    trim_leading = "([<{'\"",
    trim_trailing = ".,;:!?)]}",
  },
})

hwl.term.set_workspace_name("default")

if hwl.platform.is_windows then
  hwl.config.set({
    shell = "wsl.exe",
  })
else
  hwl.config.set({
    shell = hwl.platform.default_shell,
  })
end

local _metrics_cache = nil
local _metrics_last_t = 0

local function leader_or_terminal()
  local leader_state = hwl.keymap.get_leader_state()
  if leader_state and leader_state.active then
    return hwl.ui.button({
      id = "leader-state",
      text = " " .. leader_state.display .. " ",
      style = {
        fg = theme.background,
        bg = theme.warm,
        bold = true,
      },
      on_click = function()
        hwl.ui.notify.info("Leader active: " .. leader_state.display, { ttl = 1200 })
      end,
    })
  end
  return hwl.ui.button({
    id = "terminal-badge",
    text = "  ",
    style = theme.tab_bar.badge,
    on_click = function()
      hwl.term.new_tab()
    end,
  })
end

local function cwd_span(ctx)
  return hwl.ui.span(" " .. (ctx.term.pane and ctx.term.pane.cwd or "") .. " ", theme.status)
end

local function workspace_widget()
  return hwl.ui.bar.workspace({
    format = function(workspace)
      return " " .. workspace.name .. " "
    end,
    style = function(workspace)
      return workspace.is_active and theme.workspace.active or theme.workspace.inactive
    end,
  })
end

local function tabs_widget()
  return hwl.ui.bar.tabs({
    fit = "content",
    format = function(tab)
      local pane = tab.pane
      if pane then
        local title = pane.title
        if title and title ~= "" then
          return " " .. title .. " "
        end
        if pane.cwd then
          return " " .. pane.cwd .. " "
        end
      end

      return " " .. (tab.title ~= "" and tab.title or "shell") .. " "
    end,
    style = function(tab)
      if tab.is_active then
        return theme.tab_bar.active_tab
      end

      return tab.is_hovered and theme.tab_bar.hover_tab or theme.tab_bar.inactive_tab
    end,
  })
end
-- hollow.ui.bottombar.mount(hollow.ui.bottombar.new({
--   height = 20,
--   render = function(ctx)
--     return {
--       hollow.ui.bar.workspace(),
--       hollow.ui.bar.tabs({ fit = "content" }),
--       hollow.ui.spacer(),
--       hollow.ui.bar.key_legend(),
--       hwl.ui.bar.time("%H:%M", { style = theme.status }),
--     }
--   end,
-- }))

hwl.ui.topbar.mount(hwl.ui.topbar.new({
  render = function(ctx)
    return {
      leader_or_terminal(),
      workspace_widget(),
      tabs_widget(),
      hwl.ui.spacer(),
      hwl.ui.bar.key_legend({ style = theme.status }),
      hwl.ui.bar.time("%H:%M:%S", { style = theme.status }),
    }
  end,
}))

hwl.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hwl.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
hwl.keymap.set("<leader>sd", "split_horizontal", { desc = "split horizontal" })
hwl.keymap.set("<leader>c", "close_pane", { desc = "close pane" })
hwl.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
hwl.keymap.set("<leader>uu", function()
  hwl.config.reload()
end, { desc = "reload config" })

hwl.keymap.set("<leader>r", function()
  local tab = hwl.term.current_tab()
  if tab then
    hwl.ui.input.open({
      prompt = "New tab name",
      default = tab.title,
      on_confirm = function(new_title)
        hwl.term.set_title(new_title, tab.id)
      end,
    })
  end
end, { desc = "rename tab" })
hwl.keymap.set("<leader>e", function()
  hwl.ui.select.open({
    prompt = "Choose an option",
    width = 65,
    -- max_height = 50,
    items = {
      { name = "Option 1", kind = "ok" },
      { name = "Option 2", kind = "warn" },
      { name = "Option 3", kind = "err" },
      { name = "Option 4", kind = "err" },
      { name = "Option 5", kind = "err" },
      { name = "Option 6", kind = "err" },
      { name = "Option 7", kind = "err" },
      { name = "Option 8", kind = "err" },
      { name = "Option 9", kind = "err" },
      { name = "Option 10", kind = "err" },
      { name = "Option 11", kind = "err" },
      { name = "Option 12", kind = "err" },
      { name = "Option 13", kind = "err" },
      { name = "Option 14", kind = "err" },
      { name = "Option 15", kind = "err" },
      { name = "Option 16", kind = "err" },
      { name = "Option 17", kind = "err" },
      { name = "Option 18", kind = "err" },
      { name = "Option 19", kind = "err" },
      { name = "Option 20", kind = "err" },
      { name = "Option 21", kind = "err" },
      { name = "Option 22", kind = "err" },
      { name = "Option 23", kind = "err" },
      { name = "Option 24", kind = "err" },
      { name = "Option 25", kind = "err" },
      { name = "Option 26", kind = "err" },
      { name = "Option 27", kind = "err" },
      { name = "Option 28", kind = "err" },
    },
    label = function(item)
      local color = ({
        ok = "#c8d9f5",
        warn = "#e0af68",
        err = "#ff5d62",
      })[item.kind] or "#dcd7ba"

      return {
        hwl.ui.span(item.name, { fg = color, bold = true }),
        hwl.ui.span("  [" .. item.kind .. "]", { fg = "#7e9cd8" }),
      }
    end,
    actions = {
      {
        name = "select",
        fn = function(item)
          hwl.ui.notify.info("You selected: " .. item.name, { ttl = 1200, align = "top_right" })
        end,
      },
    },
  })
end, { desc = "test Custom" })
-- Example of user overriding or adding keys:
hwl.keymap.set("<C-t>", "new_tab")
hwl.keymap.set("<C-w>", "close_tab")
hwl.keymap.set("<C-Tab>", "next_tab")
hwl.keymap.set("<C-S-Tab>", "prev_tab")
hwl.keymap.del("<C-S-Left>")
-- g.keymap.set("<A-S-PageUp>", "scrollback_page_up", { desc = "scrollback page up" })
-- g.keymap.set("<A-S-PageDown>", "scrollback_page_down", { desc = "scrollback page down" })
-- g.keymap.set("<C-S-Home>", "scrollback_top", { desc = "scrollback top" })
-- g.keymap.set("<C-S-End>", "scrollback_bottom", { desc = "scrollback bottom" })
