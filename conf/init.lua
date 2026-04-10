local hwl = hollow
local theme = {
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
  foreground = "#dcd7ba",
  background = "#1F1F28",

  cursor_bg = "#c8c093",
  cursor_fg = "#0d0c0c",
  cursor_border = "#c8c093",

  selection_fg = "#c8c093",
  selection_bg = "#0d0c0c",

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
    enabled = true,
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

hwl.keymap.set_leader("ctrl+space", { timeout_ms = 1200 })
hwl.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
hwl.keymap.set("<leader>sd", "split_horizontal", { desc = "split horizontal" })
hwl.keymap.set("<leader>c", "close_pane", { desc = "close pane" })
hwl.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
hwl.keymap.set("<leader>e", function()
  hwl.ui.select.open({
    title = "Choose an option",
    items = {
      "Option 1",
      "Option 2",
      "Option 3",
    },
    fuzzy = true,
    actions = {
      {
        name = "select",
        keys = { "enter" },
        fn = function(value)
          hwl.ui.notify.info("You selected: " .. value, { ttl = 1200 })
        end,
      },
    },
  })
end, { desc = "test Custom" })
-- Example of user overriding or adding keys:
hwl.keymap.set("ctrl+t", "new_tab")
hwl.keymap.set("ctrl+w", "close_tab")
hwl.keymap.set("ctrl+tab", "next_tab")
hwl.keymap.set("ctrl+shift+tab", "prev_tab")
hwl.keymap.del("ctrl+shift+arrow_left")
-- g.keymap.set("alt+shift+page_up", "scrollback_page_up", { desc = "scrollback page up" })
-- g.keymap.set("alt+shift+page_down", "scrollback_page_down", { desc = "scrollback page down" })
-- g.keymap.set("ctrl+shift+home", "scrollback_top", { desc = "scrollback top" })
-- g.keymap.set("ctrl+shift+end", "scrollback_bottom", { desc = "scrollback bottom" })
