-- Component gallery: every component, variant, size and state on one
-- scrollable surface. Used for screenshots and as a theme-check fixture.
local c = require("hollow.ui.components")
local shared = require("hollow.ui.shared")
local hollow = _G.hollow
local ui = hollow.ui
local M = {}

local VARIANTS = { "default", "primary", "destructive" }
local STATES = {
  { label = "rest" },
  { label = "hovered", hovered = true },
  { label = "selected", selected = true },
  { label = "disabled", disabled = true },
}

local function section(title, ...)
  return c.column(
    { c.title(title), ... },
    { id = "gallery:section:" .. title, width = "grow", gap = "0.5lh" }
  )
end

local function line(...)
  return c.row({ ... }, { gap = "1ch", align_y = "center" })
end

local function buttons(appearance, state, changed)
  local rows = {}
  for _, variant in ipairs(VARIANTS) do
    local items = { c.label({ text = string.format("%-12s", variant), tone = "muted" }) }
    for _, mode in ipairs(STATES) do
      items[#items + 1] = c.button({
        id = "gallery:button:" .. appearance .. ":" .. variant .. ":" .. mode.label,
        text = mode.label,
        appearance = appearance,
        variant = variant,
        hovered = mode.hovered,
        selected = mode.selected,
        disabled = mode.disabled,
        on_click = function()
          state.clicks = state.clicks + 1
          changed()
        end,
      })
    end
    rows[#rows + 1] = line(items)
  end
  local sizes = { c.label({ text = string.format("%-12s", "sizes"), tone = "muted" }) }
  for _, size in ipairs({ "sm", "md" }) do
    sizes[#sizes + 1] = c.button({ text = size, appearance = appearance, size = size })
  end
  rows[#rows + 1] = line(sizes)
  return c.column(rows, { gap = "0.5lh" })
end

local function list_items(state, changed)
  local items = {
    { label = "Default item" },
    { label = "Hovered item", hovered = true },
    { label = "Selected item", selected = true },
    { label = "Section header", variant = "section" },
    { label = "Selected section", variant = "section", selected = true },
    { label = "With detail", detail = "Secondary detail line" },
    { label = "Explicit accent", accent = true },
    { label = "Disabled item", disabled = true },
  }
  local rows = {}
  for index, item in ipairs(items) do
    rows[index] = c.list_item({
      id = "gallery:item:" .. index,
      variant = item.variant,
      hovered = item.hovered,
      selected = item.selected or state.item == index,
      detail = item.detail,
      accent = item.accent,
      disabled = item.disabled,
      on_activate = function()
        state.item = index
        changed()
      end,
      c.label(item.label),
    })
  end
  return c.column(rows, { width = "grow" })
end

local function picker(state)
  local entries = { "alpha", "beta", "gamma", "delta", "epsilon" }
  return c.picker({
    id = "gallery:picker",
    title = "Picker",
    counter = state.picker .. "/" .. #entries,
    prompt = true,
    filter = state.filter,
    height = "fit",
    hints = { { "Enter", "open" }, { "Esc", "close" } },
    list = {
      height = "fit",
      items = entries,
      selected = state.picker,
      render_item = function(entry, index, view)
        return c.list_item({
          id = "gallery:picker:item:" .. entry,
          selected = index == state.picker,
          c.rich({ plain = view.plain, ui.text(entry) }),
        })
      end,
    },
  })
end

---@param state? table
---@param changed? fun()
---@param close? fun()
---@return HollowUiLayoutNode
function M.render(state, changed, close)
  state = state or {}
  state.clicks = state.clicks or 0
  state.item = state.item or 1
  state.picker = state.picker or 1
  state.tab = state.tab or "gallery:tab:one"
  state.filter = state.filter or ui.text_input({ initial = "query" })
  changed = changed or function() end
  local numbers = {}
  for index = 1, 12 do
    numbers[index] = "Row " .. index
  end
  local tones = {}
  for _, tone in ipairs({ "default", "muted", "title", "empty", "counter" }) do
    tones[#tones + 1] = c.label({ text = tone, tone = tone })
  end
  local toasts = {}
  for _, level in ipairs({ "info", "success", "warn", "error" }) do
    toasts[#toasts + 1] = c.toast({ level = level, text = level .. " notification" })
  end
  local sections = {
    c.column({
      c.header({
        title = "Component gallery",
        width = "grow",
        meta = line(
          c.label({ text = "clicks: " .. state.clicks, tone = "counter" }),
          close and c.button({ id = "gallery:close", text = "Close", on_click = close })
        ),
      }),
    }, { id = "gallery:section:top", width = "grow" }),
    section(
      "Text",
      line(tones),
      line(c.title("title"), c.empty("empty"), c.icon("bell"), c.text("plain text"))
    ),
    section(
      "Painted atoms",
      line(
        c.badge({ text = "3" }),
        c.badge({ text = "warn", color = "notify_levels.warn" }),
        c.pill({ text = "workspace" }),
        c.kbd({ key = "<C-k>" }),
        c.kbd({ key = "Enter" })
      ),
      c.progress(0.65, { width = "grow", height = "0.5lh" })
    ),
    section("Solid buttons", buttons("solid", state, changed)),
    section("Quiet buttons", buttons("quiet", state, changed)),
    section(
      "Tabs",
      c.tabs({
        active = state.tab,
        on_select = function(id)
          state.tab = id
          changed()
        end,
        tabs = {
          { id = "gallery:tab:one", label = "One" },
          { id = "gallery:tab:two", label = "Two", badge = "2" },
          { id = "gallery:tab:three", label = "Three", disabled = true },
        },
      })
    ),
    section(
      "Hints",
      c.hints({ { "Enter", "open" }, { "Tab", "next" }, { "Esc", "close" } }),
      c.hints({ plain = true, { "Enter", "open" }, { "Esc", "close" } })
    ),
    section(
      "Input",
      c.input({ id = "gallery:input", behavior = state.filter }),
      c.input({ id = "gallery:input:bare", behavior = state.filter, boxed = false })
    ),
    section(
      "Rich",
      c.rich({
        width = "grow",
        ui.text("bold ", { bold = true }),
        ui.text("muted ", { fg = "muted" }),
        ui.text("painted", { bg = "selection_bg", padding = { x = 4 } }),
        ui.spacer(),
        ui.text("right aligned", { fg = "title" }),
      })
    ),
    section("List items", list_items(state, changed)),
    section(
      "List",
      c.list({
        id = "gallery:list",
        height = "5lh",
        items = numbers,
        selected = state.picker,
        window = #numbers,
        viewport = {
          start_idx = 1,
          end_idx = 5,
          show_scrollbar = true,
          scrollbar_id = "gallery:list:scrollbar",
          thumb_ratio = 0,
          thumb_size = 5 / #numbers,
        },
        render_item = function(entry, index, view)
          return c.list_item({
            id = "gallery:list:item:" .. index,
            selected = index == state.picker,
            c.rich({ plain = view.plain, ui.text(entry) }),
          })
        end,
      }),
      c.list({
        id = "gallery:list:empty",
        height = "fit",
        items = {},
        render_item = function() end,
        empty = "Empty list",
      })
    ),
    section("Picker", picker(state)),
    section(
      "Dialog",
      c.panel({
        c.dialog({
          id = "gallery:dialog",
          title = "Discard changes?",
          body = "Unsaved edits will be lost.",
          selected = 1,
          actions = {
            { text = "Cancel" },
            { text = "Save", kind = "primary" },
            { text = "Discard", kind = "destructive" },
            { text = "Later", disabled = true },
          },
        }),
      })
    ),
    section("Toasts", c.column(toasts, { gap = "0.5lh" })),
    section(
      "Panel and stack",
      c.panel({
        inset = "modal",
        c.stack({
          divided = true,
          gap = "1lh",
          width = "grow",
          c.label("first"),
          c.label("second"),
          c.empty("third"),
        }),
      })
    ),
    section(
      "Spacer and gap",
      c.row({
        c.label("left"),
        c.gap("2ch"),
        c.label({ text = "gap(2ch)", tone = "muted" }),
        c.spacer(),
        c.label("right"),
      }, { width = "grow" }),
      c.row(
        c.join(
          { c.label("each"), c.label("join"), c.label("when") },
          c.label({ text = " · ", tone = "muted" })
        )
      ),
      c.when(state.clicks > 0, function()
        return c.label({ text = "shown after a button click", tone = "muted" })
      end)
    ),
  }
  M.SECTION_COUNT = #sections - 1
  state.section = math.max(0, math.min(state.section or 0, M.SECTION_COUNT))
  local target = sections[state.section + 1]
  return c.scroll({
    id = "gallery",
    axis = "y",
    width = "grow",
    height = "grow",
    reveal = target.id,
    reveal_start = true,
    c.column(sections, { width = "grow", padding = "1ch", gap = "1lh" }),
  })
end

-- Opens as a non-modal overlay so it stacks above other overlays, such as the
-- REPL. Esc or q closes it.
---@return HollowUiWidget
function M.open()
  local host_api = require("hollow.state").get().host_api
  local state, widget = {}, nil
  local function changed()
    if widget and widget._layout_surface then
      widget._layout_surface:invalidate()
    end
    if type(host_api.request_redraw) == "function" then
      host_api.request_redraw()
    end
  end
  local function close()
    ui.close_overlay_widget(widget)
  end
  local function step(delta)
    return function()
      local section = (state.section or 0) + delta
      state.section = math.max(0, math.min(section, M.SECTION_COUNT or section))
      changed()
      return true
    end
  end
  local theme = shared.widget_theme("default")
  widget = ui.overlay.new({
    width = 120,
    -- Clamped to the window; the gallery scrolls inside.
    height = 1000,
    backdrop = true,
    chrome = shared.theme_overlay_chrome(theme),
    render = function()
      return c.column({ M.render(state, changed, close) }, { width = "grow", height = "grow" })
    end,
    on_event = function(name, payload)
      local delta = name == "overlay:scroll" and payload and payload.delta or 0
      if delta ~= 0 then
        return step(delta < 0 and 1 or -1)()
      end
    end,
    on_key = require("hollow.ui.keys").keys({
      escape = close,
      q = close,
      arrow_down = step(1),
      j = step(1),
      arrow_up = step(-1),
      k = step(-1),
      page_down = step(3),
      page_up = step(-3),
      home = step(-math.huge),
      ["end"] = step(math.huge),
    }),
  })
  widget._palette = theme
  widget._theme_backdrop = true
  ui.overlay.push(widget)
  return widget
end

return M
