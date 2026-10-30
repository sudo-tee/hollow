-- Interactive sidebar for testing clicks, hover and the sidebar:* events.
-- Load from your config with dofile("/path/to/hollow/examples/sidebar-demo.lua")().
-- Ctrl+Shift+B toggles it.
return function(opts)
  opts = opts or {}
  local ui = hollow.ui

  local C = {
    fg = "#c8d3f5",
    muted = "#7a88b8",
    dim = "#444a73",
    accent = "#82aaff",
    pink = "#ff79c6",
    green = "#c3e88d",
    yellow = "#ffc777",
    chip = "#2f334d",
    hover = "#3b4261",
  }

  local clicks = 0
  local last_event = "hover something"
  local theme_index = 1
  local themes = {
    { name = "night", accent = "#82aaff" },
    { name = "rose", accent = "#ff79c6" },
    { name = "moss", accent = "#c3e88d" },
    { name = "amber", accent = "#ffc777" },
  }

  local function log(text)
    last_event = text
  end

  -- A clickable chip: hover paint plus enter/leave logging.
  local function chip(id, text, style, on_click)
    return ui.button({
      id = "sidebar-demo:" .. id,
      text = text,
      style = ui.style({
        fg = C.fg,
        bg = C.chip,
        radius = 4,
        padding = { x = 6 },
        hover = { bg = C.hover, fg = themes[theme_index].accent, bold = true },
      }, style),
      on_click = function(event)
        log("click " .. id .. (event.shifted and " +shift" or ""))
        on_click(event)
      end,
      on_mouse_enter = function()
        log("enter " .. id)
      end,
      on_mouse_leave = function()
        log("leave " .. id)
      end,
    })
  end

  local function heading(text)
    return ui.row({ ui.text(text, { fg = C.muted, bold = true }) })
  end

  local function blank()
    return ui.row({ ui.text(" ") })
  end

  local widget
  widget = ui.sidebar.new({
    side = opts.side or "left",
    width = opts.width or 30,
    reserve = opts.reserve == true,
    style = { bg = "#1b1d2b", border = themes[theme_index].accent, alpha = 240 },
    render = function(ctx)
      local accent = themes[theme_index].accent
      local rows = {
        ui.row({
          ui.text("◆ ", { fg = accent }),
          ui.text("HOLLOW", { fg = C.fg, bold = true }),
          ui.spacer(),
          ui.text(os.date("%H:%M:%S"), { fg = C.muted }),
          ui.text(" "),
          chip("close", "✕", { fg = C.muted }, function()
            ui.sidebar.toggle()
          end),
        }),
        ui.divider(C.dim),
        heading("WORKSPACES"),
      }

      for _, ws in ipairs(ctx.term.workspaces or {}) do
        local active = ws.is_active
        rows[#rows + 1] = ui.row({
          ui.text(active and "▌" or " ", { fg = accent }),
          chip("ws:" .. ws.index, tostring(ws.index) .. " " .. tostring(ws.name), {
            fg = active and accent or C.fg,
            bg = active and C.hover or C.chip,
            bold = active,
          }, function()
            hollow.term.switch_workspace(ws.index)
          end),
        })
      end

      rows[#rows + 1] = blank()
      rows[#rows + 1] = heading("TABS")
      for _, tab in ipairs(ctx.term.tabs or {}) do
        local title = tab.title ~= "" and tab.title or ("tab " .. tab.index)
        rows[#rows + 1] = ui.row({
          ui.text(tab.is_active and "▸ " or "  ", { fg = C.pink }),
          chip("tab:" .. tab.id, title, {
            fg = tab.is_active and C.fg or C.muted,
            bg = "#1b1d2b",
            bold = tab.is_active,
          }, function()
            hollow.term.focus_tab(tab.id)
          end),
        })
      end

      rows[#rows + 1] = blank()
      rows[#rows + 1] = heading("ACTIONS")
      rows[#rows + 1] = ui.row({
        chip("new-tab", "+ tab", { fg = C.green }, function()
          hollow.term.new_tab()
        end),
        ui.text(" "),
        chip("new-ws", "+ workspace", { fg = C.green }, function()
          hollow.term.new_workspace()
        end),
      })
      rows[#rows + 1] = ui.row({
        chip("count", "clicked " .. clicks, { fg = C.yellow }, function()
          clicks = clicks + 1
        end),
        ui.text(" "),
        chip("theme", "theme: " .. themes[theme_index].name, { fg = accent }, function()
          theme_index = theme_index % #themes + 1
          widget.style.border = themes[theme_index].accent
        end),
      })
      rows[#rows + 1] = ui.row({
        chip("notify", "toast", { fg = C.pink }, function(event)
          ui.notify.show("Hello from the sidebar" .. (event.shifted and " (shift)" or ""), {
            title = "sidebar-demo",
          })
        end),
        ui.text(" "),
        -- No id: gets a sidebar:auto:N id from its handler.
        ui.text("auto id", {
          fg = C.muted,
          hover = { fg = C.fg, bg = C.hover },
          on_click = function(event)
            log("click " .. tostring(event.id))
          end,
        }),
      })

      rows[#rows + 1] = blank()
      rows[#rows + 1] = ui.divider(C.dim)
      rows[#rows + 1] = heading("LAST EVENT")
      rows[#rows + 1] = ui.row({ ui.text("› " .. last_event, { fg = accent }) })
      return ui.column(rows)
    end,
  })

  ui.sidebar.mount(widget)
  hollow.keymap.set("<C-S-b>", function()
    ui.sidebar.toggle()
  end, { desc = "Toggle demo sidebar" })
  return widget
end
