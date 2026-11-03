-- Passive discovery surface: keymap owns input and deadlines; this owns presentation.
local shape = require("hollow.shape")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")
local hollow = _G.hollow
local ui = hollow.ui
local host = require("hollow.state").get().host_api
local c = ui.components
local M = {}
ui.leader_preview = M

local schema = shape.strict_object({
  enabled = shape.boolean(),
  mode = shape.enum({ "overlay", "bottombar" }),
  delay_ms = shape.integer():min(0):max(60000),
  align = shape.enum({
    "top_left",
    "top",
    "top_center",
    "top_right",
    "left",
    "left_center",
    "center",
    "right",
    "right_center",
    "bottom_left",
    "bottom",
    "bottom_center",
    "bottom_right",
  }),
  width = shape.integer():min(20):max(240),
  max_height = shape.integer():min(6):max(100),
  theme = shape.table():optional(),
})
local options = {
  enabled = true,
  mode = "overlay",
  delay_ms = 200,
  align = "bottom_right",
  width = 48,
  max_height = 20,
}
local active, generation = nil, 0

local function redraw()
  if host.request_redraw then
    host.request_redraw()
  end
end

local function close()
  if active then
    ui.close_overlay_widget(active)
    active = nil
    redraw()
  end
end

function M._mode()
  return options.enabled and options.mode or "off"
end

local function render(ctx)
  local leader = hollow.keymap.get_leader_state()
  if not leader then
    return c.column({})
  end
  local theme = shared.widget_theme("leader_preview", options.theme)
  local cw, ch = ctx.cell_w or 8, ctx.cell_h or 19
  local key_width = 1
  for _, item in ipairs(leader.next) do
    key_width = math.max(key_width, util.display_width(item.key))
  end
  key_width = math.min(key_width, 14)
  return c.column({
    c.row({
      c.title({ leader.desc or "Leader", theme = theme }),
      c.spacer(),
      c.label({ leader.display, theme = theme, tone = "muted" }),
    }, { width = "grow", gap = cw }),
    c.column({
      -- Leave room for panel/header/footer under the shared 512-node surface budget.
      c.each(leader.next, function(item, index)
        return c.when(index <= 70, function()
          return c.row({
            c.column(
              { c.text(item.key, { fg = theme.title, bold = true }) },
              { width = key_width * cw }
            ),
            c.column({
              c.text(item.desc or (item.has_children and "More keys" or "Lua callback"), {
                fg = theme.fg,
              }, { wrap = "words" }),
            }, { width = "grow" }),
            c.text(item.has_children and "›" or "", { fg = theme.muted }),
          }, { width = "grow", gap = cw, min_height = ch, align_y = "center" })
        end)
      end),
      c.when(#leader.next > 70, function()
        return c.label({
          "More bindings — type a group key to narrow",
          theme = theme,
          tone = "muted",
        })
      end),
    }, {
      id = "leader:keys:" .. leader.display,
      width = "grow",
      max_height = math.max(
        ch,
        math.min((options.max_height - 4) * ch, (ctx.height or 600) - 6 * ch)
      ),
      scroll = true,
      gap = math.floor(ch * 0.2),
    }),
    c.label({
      #leader.sequence > 0 and "Esc cancel · Backspace back · › group"
        or "Esc cancel · › group",
      theme = theme,
      tone = "muted",
    }),
  }, { width = "grow", gap = math.floor(ch * 0.5) })
end

local function show()
  local theme = shared.widget_theme("leader_preview", options.theme)
  active = ui.overlay.new({
    width = options.width,
    max_height = options.max_height,
    align = options.align,
    backdrop = false,
    chrome = shared.theme_overlay_chrome(theme, nil, 1),
    render = render,
    on_unmount = function()
      active = nil
    end,
  })
  active._palette = theme
  -- No focusable nodes, on_key handler, or backdrop: never captures shortcuts.
  ui.overlay.push(active)
  redraw()
end

function M._changed()
  generation = generation + 1
  local ticket = generation
  local leader = hollow.keymap.get_leader_state()
  if not leader or leader.prefix ~= "<leader>" then
    close()
    return
  end

  -- Expiry still wakes a quiet window when the preview is disabled.
  host.defer(function()
    if generation ~= ticket then
      return
    end
    hollow.keymap.is_leader_active()
    redraw()
  end, math.max(1, leader.remaining_ms))

  if M._mode() ~= "overlay" then
    close()
    return
  end
  if active then
    active._layout_surface:invalidate()
    redraw()
    return
  end
  local delay = math.max(0, options.delay_ms - (util.host_now_ms(host) - leader.started_at_ms))
  local function reveal()
    if generation ~= ticket then
      return
    end
    local current = hollow.keymap.get_leader_state()
    if current and current.prefix == "<leader>" and M._mode() == "overlay" then
      show()
    end
  end
  if delay == 0 then
    reveal()
  else
    host.defer(reveal, delay)
  end
end

function M.configure(opts)
  if opts == false then
    opts = { enabled = false }
  end
  assert(type(opts) == "table", "leader preview options must be a table or false")
  local candidate = util.clone_value(options)
  for key, value in pairs(opts) do
    candidate[key] = util.clone_value(value)
  end
  candidate = schema:parse(candidate, "invalid leader preview options")
  -- Validate theme before replacing the current settings or mounted surface.
  shared.widget_theme("leader_preview", candidate.theme)
  options = candidate
  close()
  M._changed()
  ui.bottombar.invalidate()
  redraw()
end

return M
