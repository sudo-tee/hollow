local hwl = hollow

local wave = {
  foreground = "#dcd7ba",
  background = "#1f1f28",
  cursor_bg = "#c8c093",
  cursor_fg = "#1f1f28",
  selection_bg = "#2d4f67",
  selection_fg = "#c8c093",
  ansi = {
    "#16161d",
    "#c34043",
    "#76946a",
    "#c0a36e",
    "#7e9cd8",
    "#957fb8",
    "#6a9589",
    "#c8c093",
  },
  brights = {
    "#727169",
    "#e82424",
    "#98bb6c",
    "#e6c384",
    "#7fb4ca",
    "#938aa9",
    "#7aa89f",
    "#dcd7ba",
  },
}

local dragon = {
  foreground = "#c5c9c5",
  background = "#181616",
  cursor_bg = "#c8c093",
  cursor_fg = "#181616",
  selection_bg = "#2d4f67",
  selection_fg = "#c8c093",
  ansi = {
    "#0d0c0c",
    "#c4746e",
    "#8a9a7b",
    "#c4b28a",
    "#8ba4b0",
    "#a292a3",
    "#8ea4a2",
    "#c8c093",
  },
  brights = {
    "#a6a69c",
    "#e46876",
    "#87a987",
    "#e6c384",
    "#7fb4ca",
    "#938aa9",
    "#7aa89f",
    "#c5c9c5",
  },
}

local terminal_theme = dragon

local palette = {
  bg = terminal_theme.background,
  fg = terminal_theme.foreground,
  black = terminal_theme.ansi[1],
  red = terminal_theme.ansi[2],
  green = terminal_theme.ansi[3],
  yellow = terminal_theme.ansi[4],
  blue = terminal_theme.ansi[5],
  magenta = terminal_theme.ansi[6],
  cyan = terminal_theme.ansi[7],
  gray = terminal_theme.brights[1],
  bright_red = terminal_theme.brights[2],
  bright_green = terminal_theme.brights[3],
  bright_yellow = terminal_theme.brights[4],
  bright_blue = terminal_theme.brights[5],
  bright_magenta = terminal_theme.brights[6],
  bright_cyan = terminal_theme.brights[7],
  bright_white = terminal_theme.brights[8],
  orange = terminal_theme.brights[4],
  error = terminal_theme.brights[2],
}

local ui_theme = {
  widgets = {
    all = {
      panel_bg = hwl.utils.brighten_hex_color(palette.bg, 0.2, palette.gray),
      panel_border = palette.blue,
      title = palette.bright_blue,
      fg = palette.fg,
      input_bg = palette.black,
      input_fg = palette.fg,
      cursor_bg = palette.fg,
      cursor_fg = palette.bg,
      divider = palette.gray,
    },
    input = {
      backdrop = { color = palette.black, alpha = 168 },
    },
    select = {
      selected_bg = palette.black,
      selected_detail_bg = palette.bg,
      scrollbar_thumb = palette.bright_yellow,
      backdrop = { color = palette.black, alpha = 168 },
    },
    notify = {
      notify_levels = {
        info = palette.bright_blue,
        warn = palette.bright_yellow,
        error = palette.error,
        success = palette.bright_green,
      },
    },
  },
  tab_bar = {
    background = palette.black,
    active_tab = {
      bg = palette.bg,
      fg = palette.bright_yellow,
      bold = true,
    },
    inactive_tab = {
      bg = palette.black,
      fg = palette.fg,
    },
    hover_tab = {
      bg = palette.black,
      fg = palette.bright_white,
    },
    badge = {
      fg = palette.bright_yellow,
      bg = palette.black,
      bold = true,
    },
    hover_close_bg = palette.red,
  },
  scrollbar = {
    track = palette.black,
    thumb = palette.gray,
    thumb_hover = palette.blue,
    thumb_active = palette.bright_blue,
    border = palette.bg,
  },
  split = palette.magenta,
  accent = palette.blue,
  warm = palette.bright_yellow,
  status = {
    bg = palette.black,
    fg = palette.blue,
  },
  workspace = {
    active = {
      fg = palette.bg,
      bg = palette.blue,
    },
    inactive = {
      fg = palette.fg,
      bg = palette.black,
    },
  },
}

-- g.log("loading native rewrite config")

hwl.config.set({
  default_domain = "wsl",
  domains = {
    wsl = "C:\\Windows\\System32\\wsl.exe",
    pwsh = "pwsh.exe",
    powershell = "powershell.exe",
    cmd = "cmd.exe",
    ssh = "ssh",
    unix = hwl.platform.default_shell,
  },
  debug_overlay = false,
  backend = "sokol",
  vsync = false,
  max_fps = 120,
  padding = 0,
  terminal_theme = terminal_theme,
  ui_theme = ui_theme,
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
  top_bar_bg = ui_theme.tab_bar.background,
  top_bar_draw_tabs = true,
  top_bar_draw_status = true,
  scrollback = 64000000,
  scrollbar = {
    enabled = false,
    width = 14,
    min_thumb_size = 24,
    margin = 2,
    jump_to_click = true,
    track = ui_theme.scrollbar.track,
    thumb = ui_theme.scrollbar.thumb,
    thumb_hover = ui_theme.scrollbar.thumb_hover,
    thumb_active = ui_theme.scrollbar.thumb_active,
    border = ui_theme.scrollbar.border,
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

local _metrics_cache = nil
local _metrics_last_t = 0

local function leader_or_terminal()
  local leader_state = hwl.keymap.get_leader_state()
  if leader_state and leader_state.active then
    return hwl.ui.button({
      id = "leader-state",
      text = " " .. leader_state.display .. " ",
      style = {
        fg = ui_theme.workspace.active.fg,
        bg = ui_theme.warm,
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
    style = ui_theme.tab_bar.badge,
    on_click = function()
      hwl.term.new_tab()
    end,
  })
end

local function cwd_span(ctx)
  return hwl.ui.span(" " .. (ctx.term.pane and ctx.term.pane.cwd or "") .. " ", ui_theme.status)
end

local function workspace_widget()
  return hwl.ui.bar.workspace({
    format = function(workspace)
      return " " .. workspace.name .. " "
    end,
    style = function(workspace)
      return workspace.is_active and ui_theme.workspace.active or ui_theme.workspace.inactive
    end,
  })
end

local function tabs_widget()
  return hwl.ui.bar.tabs({
    fit = "content",
    format = function(tab)
      local pane = tab.pane
      local maximized = pane and pane.is_maximized and " [M]" or ""
      if pane then
        if pane.title and pane.title ~= "" then
          return " " .. pane.title .. maximized .. " "
        end
        if pane.cwd and pane.cwd ~= "" then
          return " " .. pane.cwd .. " " .. maximized .. " "
        end
      end

      return " " .. (tab.title ~= "" and tab.title or "shell") .. " " .. maximized
    end,
    style = function(tab)
      if tab.is_active then
        return ui_theme.tab_bar.active_tab
      end

      return tab.is_hovered and ui_theme.tab_bar.hover_tab or ui_theme.tab_bar.inactive_tab
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
--       hwl.ui.bar.time("%H:%M", { style = ui_theme.status }),
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
      hwl.ui.bar.key_legend({ style = ui_theme.status }),
      cwd_span(ctx),
      hwl.ui.bar.time("%H:%M:%S", { style = ui_theme.status }),
    }
  end,
}))

hwl.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hwl.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })
hwl.keymap.set("<leader>sd", "split_horizontal", { desc = "split horizontal" })
hwl.keymap.set("<leader>sf", function()
  hwl.term.split_pane({
    floating = true,
    command = "lazygit",
    close_on_exit = true,
  })
end, { desc = "split horizontal" })
hwl.keymap.set("<leader>c", "close_pane", { desc = "close pane" })
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
-- hollow.keymap.set("<C-S-m>", function()
--   hwl.ui.notify.info("Maximize pane toggled", { ttl = 1200 })
--   hwl.term.toggle_pane_maximized(hwl.term.current_pane().id)
-- end, { desc = "toggle maximize pane" })

-- g.keymap.set("<A-S-PageUp>", "scrollback_page_up", { desc = "scrollback page up" })
-- g.keymap.set("<A-S-PageDown>", "scrollback_page_down", { desc = "scrollback page down" })
-- g.keymap.set("<C-S-Home>", "scrollback_top", { desc = "scrollback top" })
-- g.keymap.set("<C-S-End>", "scrollback_bottom", { desc = "scrollback bottom" })
