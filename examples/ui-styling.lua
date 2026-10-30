-- Load with dofile("/path/to/hollow/examples/ui-styling.lua")().
-- Public APIs only; no private recipe or computed-style helpers.
return function()
  local ui = hollow.ui
  local active = "Projects"
  local selected = "Hollow"
  local groups = { Projects = { "Hollow", "Plugin" }, Recent = { "Notes", "Scratch" } }
  local modal

  modal = ui.modal({
    theme = "select",
    width = 44,
    render = function(theme)
      local layout = ui.layout
      return layout.column({
        layout.text("Choose workspace", { fg = theme.title, bold = true }),
        layout.row(
          ui.each({ "Projects", "Recent" }, function(name)
            return layout.button({
              id = "styling:tab:" .. name,
              text = name,
              theme = theme,
              style = { bg = active == name and theme.selection_bg or nil },
              on_click = function()
                active, selected = name, groups[name][1]
              end,
            })
          end),
          { gap = 8 }
        ),
        ui.each(groups[active], function(name)
          return layout.button({
            id = "styling:choice:" .. name,
            text = name,
            theme = theme,
            width = "grow",
            style = { bg = selected == name and theme.selection_bg or nil },
            on_click = function()
              selected = name
            end,
          })
        end),
        layout.row({
          layout.button({
            id = "styling:done",
            text = "Done",
            variant = "primary",
            size = "sm",
            theme = theme,
            on_click = function()
              modal.close()
            end,
          }),
        }),
      }, { width = "grow", gap = 8 })
    end,
    keys = function(key)
      if key == "escape" or key == "<Esc>" then
        modal.close()
        return true
      end
      return false
    end,
  })
  return modal
end
