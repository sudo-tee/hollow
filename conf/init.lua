local hollow = require("hollow")

local is_windows = hollow.platform.is_windows == true

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

local terminal_theme = wave

local palette = {
  bg = terminal_theme.background,
  fg = terminal_theme.foreground,
  black = terminal_theme.ansi[1],
  blue = terminal_theme.ansi[5],
  magenta = terminal_theme.ansi[6],
  gray = terminal_theme.brights[1],
  bright_green = terminal_theme.brights[3],
  bright_yellow = terminal_theme.brights[4],
  bright_blue = terminal_theme.brights[5],
  bright_white = terminal_theme.brights[8],
  error = terminal_theme.brights[2],
}

local ui_theme = {
  widgets = {
    all = {
      panel_bg = hollow.util.brighten_hex_color(palette.bg, 0.2, palette.gray),
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
}

local default_domain = is_windows and "pwsh" or "unix"
local domains = {
  unix = { shell = hollow.platform.default_shell },
}

if is_windows then
  domains.wsl = { shell = "C:\\Windows\\System32\\wsl.exe" }
  domains.pwsh = { shell = "pwsh.exe" }
  domains.powershell = { shell = "powershell.exe" }
  domains.cmd = { shell = "cmd.exe" }
end

hollow.config.set({
  backend = "sokol",
  default_domain = default_domain,
  domains = domains,
  terminal_theme = terminal_theme,
  ui_theme = ui_theme,
  fonts = {
    size = 14.5,
    line_height = 0.95,
    smoothing = "grayscale",
    hinting = "light",
    ligatures = true,
    family = "JetBrains Mono",
  },
  cols = 120,
  rows = 34,
  scrollback = 64000000,
  padding = 0,
  window_title = "hollow",
  window_width = 1440,
  window_height = 900,
  top_bar_mode = "always",
  top_bar_height = 0,
  top_bar_bg = ui_theme.tab_bar.background,
  window_titlebar_show = false,
  scrollbar = {
    enabled = true,
    width = 12,
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

hollow.ui.topbar.mount(hollow.ui.topbar.new({
  height = 30,
  style = {
    bg = ui_theme.tab_bar.background,
  },
  layout = {
    padding = { left = 0, right = 0, top = 1, bottom = 1 },
  },
  render = function(_ctx)
    local pill = {
      bg = ui_theme.tab_bar.background,
      radius = 8,
      padding = { left = 3, right = 3, top = 1, bottom = 1 },
      margin = { right = 1, left = 0, top = 0, bottom = 0 },
    }

    local group_bg = hollow.util.brighten_hex_color(palette.black, 0.08, palette.bg)
    local sep_fg = hollow.util.brighten_hex_color(palette.black, 0.08, palette.black)
    return {
      hollow.ui.bar.workspace({
        style = pill,
        format = function(workspace)
          return {
            hollow.ui.span(workspace.name, { fg = palette.bright_blue, bold = true }),
          }
        end,
      }),
      hollow.ui.span("|", { fg = sep_fg, margin = { left = 3, right = 3 } }),
      hollow.ui.bar.tabs({
        fit = "content",
        style = function(tab)
          local tab_bg = tab.is_active and group_bg or ui_theme.tab_bar.background
          local tab_fg = tab.is_active and palette.bright_white
            or hollow.util.brighten_hex_color(palette.bg, -0.4, palette.bg)
          return {
            bg = tab_bg,
            fg = tab_fg,
            radius = 4,
            padding = { left = 6, right = 3, top = 2, bottom = 2 },
            margin = { right = 1 },
            bold = tab.is_active,
          }
        end,
        format = function(tab)
          local is_maximized = tab.pane and tab.pane.is_maximized and "󰊓 " or ""
          local tab_bg = tab.is_active
              and hollow.util.brighten_hex_color(group_bg, 0.16, palette.bg)
            or palette.bg
          local tab_fg = tab.is_active and palette.bright_white
            or hollow.util.brighten_hex_color(palette.fg, 0.4, palette.bg)
          local tab_text_id = "tab-text:" .. tostring(tab.id)
          local close_id = "tab-close:" .. tostring(tab.id)
          local close_style = {
            id = close_id,
            fg = palette.gray,
            bg = tab_bg,
            hover = {
              fg = tab_fg,
            },
            on_click = function()
              hollow.term.close_tab(tab.id)
            end,
          }
          return {
            hollow.ui.span(is_maximized, { fg = palette.magenta }),
            hollow.ui.span(tab.title, {
              id = tab_text_id,
              on_click = function()
                hollow.term.focus_tab(tab.id)
              end,
              hover = { fg = palette.bright_white },
            }),
            hollow.ui.span(" ×", close_style),
          }
        end,
      }),
    } --[[@as HollowWidgetRenderResult]]
  end,
}))

hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 1200 })
end)

hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hollow.keymap.set("<C-S-c>", "copy_selection")
hollow.keymap.set("<C-S-v>", "paste_clipboard")
hollow.keymap.set("<S-Insert>", "paste_clipboard")
hollow.keymap.set("<C-\\>", "split_vertical")
hollow.keymap.set("<C-S-\\>", "split_horizontal")
hollow.keymap.set("<C-S-t>", "new_tab")
hollow.keymap.set("<C-S-x>", "close_tab")
hollow.keymap.set("<C-S-w>", "close_pane")
hollow.keymap.set("<C-Tab>", "next_tab")
hollow.keymap.set("<C-S-Tab>", "prev_tab")
hollow.keymap.set("<C-A-Right>", "next_tab")
hollow.keymap.set("<C-A-Left>", "prev_tab")
hollow.keymap.set("<C-S-n>", "new_workspace")
hollow.keymap.set("<C-S-p>", "workspace_switcher")
hollow.keymap.set("<C-S-r>", "rename_workspace")
hollow.keymap.set("<C-S-w>", "close_workspace")
hollow.keymap.set("<C-S-PageUp>", "next_workspace")
hollow.keymap.set("<C-S-PageDown>", "prev_workspace")
hollow.keymap.set("<C-S-Left>", "focus_pane_left")
hollow.keymap.set("<C-S-Right>", "focus_pane_right")
hollow.keymap.set("<C-S-Up>", "focus_pane_up")
hollow.keymap.set("<C-S-Down>", "focus_pane_down")
hollow.keymap.set("<C-S-m>", "maximize_pane")
hollow.keymap.set("<C-S-f>", "float_pane")
hollow.keymap.set("<C-A-S-f>", "tile_pane")
hollow.keymap.set("<C-A-h>", "move_pane_left")
hollow.keymap.set("<C-A-l>", "move_pane_right")
hollow.keymap.set("<C-A-k>", "move_pane_up")
hollow.keymap.set("<C-A-j>", "move_pane_down")
hollow.keymap.set("<C-A-S-Left>", "resize_pane_left")
hollow.keymap.set("<C-A-S-Right>", "resize_pane_right")
hollow.keymap.set("<C-A-Up>", "resize_pane_up")
hollow.keymap.set("<C-A-Down>", "resize_pane_down")
hollow.keymap.set("<A-S-PageUp>", "scrollback_page_up")
hollow.keymap.set("<A-S-PageDown>", "scrollback_page_down")
hollow.keymap.set("<C-S-Home>", "scrollback_top")
hollow.keymap.set("<C-S-End>", "scrollback_bottom")

hollow.keymap.set("<leader>r", function()
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
end, { desc = "rename tab" })

hollow.keymap.set("<leader>uu", function()
  hollow.config.reload()
end, { desc = "reload config" })

-- User config files are loaded after this bundled config, so you can override
-- any of the values above from `%APPDATA%\\hollow\\init.lua` on Windows or
-- `$XDG_CONFIG_HOME/hollow/init.lua` / `$HOME/.config/hollow/init.lua` elsewhere.
--
-- Example user overrides:
--
-- hollow.config.set({
--   default_domain = "pwsh",
--   top_bar_mode = "always",
--   window_titlebar_show = false,
--   fonts = { size = 16, family = "Consolas" },
-- })
--
-- hollow.config.set({
--   domains = {
--     devbox = {
--       ssh = {
--         alias = "devbox",
--         backend = "wsl",
--         reuse = "auto",
--       },
--     },
--   },
-- })
--
-- hollow.ui.workspace.configure({
--   sources = {
--     {
--       domain = "wsl",
--       cwd_resolver = "wsl_unc",
--       roots = {
--         "\\\\wsl$\\Ubuntu\\home\\me\\Projects",
--       },
--     },
--   },
-- })
