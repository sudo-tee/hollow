-- Demo content stays out of the surface engine.
local layout = _G.hollow.ui.layout
local M = {}

function M.open()
  local clicks = 0
  local function render()
    local rows = {}
    for i = 1, 40 do
      rows[i] = layout.column(
        { layout.text("Task " .. i), layout.progress(i / 40, { width = "grow", height = 10 }) },
        {
          width = "grow",
          padding = 8,
          gap = 6,
          style = { bg = "#242b38", radius = 4 },
        }
      )
    end
    layout.show(layout.column({
      layout.row({
        layout.text("Clay layout experiment", { bold = true }),
        layout.column({}, { width = "grow" }),
        layout.button({ id = "clay.close", text = "Close", size = "md", on_click = layout.hide }),
      }, { width = "grow", gap = 12 }),
      layout.row({
        layout.column({
          layout.text("Lua component"),
          layout.text(
            "Nested containers keep their hierarchy. Resize this window to test allocation."
          ),
          layout.button({
            id = "clay.count",
            text = "Clicked " .. clicks .. " times",
            variant = "primary",
            size = "md",
            on_click = function()
              clicks = clicks + 1
              render()
            end,
          }),
          layout.text("Custom-painted progress:"),
          layout.progress(0.65, { width = "grow", height = 28 }),
        }, {
          width = 260,
          height = "grow",
          padding = 16,
          gap = 16,
          style = { bg = "#202633" },
        }),
        layout.column(
          rows,
          { id = "clay.tasks", width = "grow", height = "grow", scroll = true, gap = 8 }
        ),
      }, { width = "grow", height = "grow", gap = 16 }),
    }, { width = "grow", height = "grow", padding = 24, gap = 16, style = { bg = "#141923" } }))
  end
  render()
end

return M
