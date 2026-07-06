local hollow = require("hollow")

local is_windows = hollow.platform.is_windows == true

local default_font_size = 14
local default_domain = is_windows and "pwsh" or "unix"
---@type table<string, HollowDomainConfig>
local domains = {}

if is_windows then
  domains.pwsh = { shell = "pwsh.exe" }
  domains.powershell = { shell = "powershell.exe" }
  domains.cmd = { shell = "cmd.exe" }
else
  domains.unix = { shell = hollow.platform.default_shell }
end

hollow.config.set({
  max_fps = 120,
  idle_max_fps = 15,
  command_timing = false,
  debug_overlay = false,
  renderer_single_pane_direct = false,
  vsync = false,
  backend = "sokol",
  default_domain = default_domain,
  domains = domains,
  fonts = {
    size = default_font_size,
    line_height = 0.93,
    smoothing = "grayscale",
    hinting = "light",
    ligatures = true,
    embolden = 0.33,
    italic_embolden = 0.5,
    family = "JetBrains Mono",
  },
  cols = 120,
  rows = 34,
  scrollback = 64000000,
  padding = 5,
  alternate_screen_padding = 0, --TUI like nvim
  window_title = "hollow",
  window_width = 1440,
  window_height = 900,
  top_bar_mode = "always",
  split_width = 1,
  unfocused_pane = {
    cursor = "block_hollow",
    dim = 0.2,
  },
  window_titlebar_show = true,
  scrollbar = {
    enabled = false,
    width = 12,
    min_thumb_size = 24,
    margin = 2,
    jump_to_click = true,
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

if is_windows then
  hollow.config.populate_wsl_domains()
end

hollow.ui.topbar.configure({
  height = 28,
  layout = {
    padding = { left = 4, right = 0, top = 1, bottom = 1 },
  },
  cwd = false,
  key_legend = false,
  time = false,
  workspace = {
    style = function()
      return {
        radius = 4,
        padding = { left = 6, right = 6, top = 0, bottom = 2 },
        margin = { right = 1, left = 0, top = 0, bottom = 0 },
      }
    end,
    format = function()
      return hollow.ui.workspace.topbar_button({
        colorize = true,
      })
    end,
  },
  separator = {
    text = "|",
    style = { margin = { left = 4, right = 4 } },
  },
  tabs = {
    fit = "content",
    max_width = 20,
    style = function(tab)
      local ui = hollow.theme.current().ui
      local tab_colors = tab.is_active and ui.tab_bar.active_tab
        or (tab.is_hovered and ui.tab_bar.hover_tab or ui.tab_bar.inactive_tab)
      return {
        bg = tab_colors.bg,
        fg = tab_colors.fg,
        radius = 4,
        padding = { left = 6, right = 3, top = 1, bottom = 2 },
        margin = { right = 1 },
        bold = tab.is_active,
      }
    end,
    format = function(tab)
      local ui = hollow.theme.current().ui
      local pane = tab.pane

      local function nonempty(s)
        return s and s ~= "" and s or nil
      end

      local function tab_label()
        return nonempty(tab.title)
          or nonempty(pane and pane.foreground_process)
          or (pane and pane.cwd and hollow.util.basename(pane.cwd))
          or nonempty(pane and pane.title)
          or ""
      end

      local function tab_bell()
        return pane and pane.has_bell
          or hollow.tbl(tab.panes or {}):some(function(p)
            return p.has_bell
          end)
      end

      local prefix = (pane and pane.is_maximized) and "󰊓 " or ""

      local spans = {
        hollow.ui.span(prefix),
        hollow.ui.span(tab_label(), {
          on_click = function()
            hollow.term.focus_tab(tab.id)
          end,
          hover = { fg = ui.tab_bar.hover_tab.fg },
        }),
        hollow.ui.span(" ×", {
          fg = ui.widgets.all.divider,
          on_click = function()
            hollow.term.close_tab(tab.id)
          end,
          hover = { fg = ui.tab_bar.hover_tab.fg },
        }),
      }

      if tab_bell() then
        table.insert(spans, 2, hollow.ui.span("● ", { fg = "#ffcc66", bold = true }))
      end

      return spans
    end,
  },
})

hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 1200 })
end)

hollow.events.on("workspace:closed", function(ev)
  local label = ev.name ~= "" and ("'" .. ev.name .. "'") or "workspace"
  hollow.ui.notify.info(label .. " closed", { ttl = 2400 })
end)

hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
-- hollow.keymap.set("<C-S-c>", "copy_selection")
-- hollow.keymap.set("<C-S-v>", "paste_clipboard")
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
hollow.keymap.set("<C-S-X>", "copy_mode")
hollow.keymap.set("<A-S-Up>", "prompt_jump_prev")
hollow.keymap.set("<A-S-Down>", "prompt_jump_next")
hollow.keymap.set("<leader>/", "copy_mode_search", { desc = "search" })

hollow.keymap.set("h", "copy_mode_move_left", { mode = "copy_mode" })
hollow.keymap.set("j", "copy_mode_move_down", { mode = "copy_mode" })
hollow.keymap.set("k", "copy_mode_move_up", { mode = "copy_mode" })
hollow.keymap.set("<A-S-Up>", "prompt_jump_prev", { mode = "copy_mode" })
hollow.keymap.set("<A-S-Down>", "prompt_jump_next", { mode = "copy_mode" })
hollow.keymap.set("l", "copy_mode_move_right", { mode = "copy_mode" })
hollow.keymap.set("<Left>", "copy_mode_move_left", { mode = "copy_mode" })
hollow.keymap.set("<Down>", "copy_mode_move_down", { mode = "copy_mode" })
hollow.keymap.set("<Up>", "copy_mode_move_up", { mode = "copy_mode" })
hollow.keymap.set("<Right>", "copy_mode_move_right", { mode = "copy_mode" })
hollow.keymap.set("<PageUp>", "copy_mode_page_up", { mode = "copy_mode" })
hollow.keymap.set("<PageDown>", "copy_mode_page_down", { mode = "copy_mode" })
hollow.keymap.set("<Home>", "copy_mode_top", { mode = "copy_mode" })
hollow.keymap.set("<End>", "copy_mode_bottom", { mode = "copy_mode" })
hollow.keymap.set("gg", "copy_mode_top", { mode = "copy_mode" })
hollow.keymap.set("G", "copy_mode_bottom", { mode = "copy_mode" })
hollow.keymap.set("0", "copy_mode_line_start", { mode = "copy_mode" })
hollow.keymap.set("$", "copy_mode_line_end", { mode = "copy_mode" })
hollow.keymap.set("v", "copy_mode_begin_selection", { mode = "copy_mode" })
hollow.keymap.set("<C-v>", "copy_mode_begin_block_selection", { mode = "copy_mode" })
hollow.keymap.set("<Space>", "copy_mode_clear_selection", { mode = "copy_mode" })
hollow.keymap.set("/", "copy_mode_search", { mode = "copy_mode" })
hollow.keymap.set("n", "copy_mode_search_next", { mode = "copy_mode" })
hollow.keymap.set("N", "copy_mode_search_prev", { mode = "copy_mode" })
hollow.keymap.set("y", "copy_mode_copy_selection", { mode = "copy_mode" })
hollow.keymap.set("<Enter>", "copy_mode_copy_selection", { mode = "copy_mode" })
hollow.keymap.set("q", "copy_mode_exit", { mode = "copy_mode" })
hollow.keymap.set("<Esc>", "copy_mode_exit", { mode = "copy_mode" })
hollow.keymap.set("<C-S-minus>", "font_size_decrease")
hollow.keymap.set("<C-S-equal>", "font_size_increase")
hollow.keymap.set("<C-0>", "font_size_reset")
hollow.keymap.set("<leader>r", "rename_tab")
hollow.keymap.set("<leader>uu", "reload_config")
hollow.keymap.set("<leader>p", "command_palette", { desc = "command palette" })

-- Load local plugin for demo purposes
-- hollow.plugins.setup({
--   plugins = {
--     "~/hollow-spirit",
--   },
-- })

-- LuaLS autocompletion and editor setup is documented in
-- docs/development.md → "Editor support (LuaLS)".
--
-- Example user overrides:
--
-- hollow.config.set({
--   default_domain = "pwsh",
--   top_bar_mode = "always",
--   window_titlebar_show = false,
--   fonts = { size = 16, family = "Consolas" },
--   watch_dirs = {
--     "./local",
--     os.getenv("HOME") .. "/Projects/my-hollow-plugins",
--   },
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
--     wsl = {
--       shell = "wsl.exe",
--       env = {
--         HOLLOW_THEME = "kanagawa-wave",
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
