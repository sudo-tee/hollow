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
      return ui.column({
        ui.row({ ui.text("Choose workspace", ui.style(ui.styles.title)) }),
        ui.row({
          ui.tab_bar({
            theme = theme,
            tabs = ui.each({ "Projects", "Recent" }, function(name)
              return {
                id = "styling:tab:" .. name,
                label = name,
                active = active == name,
                on_click = function()
                  active, selected = name, groups[name][1]
                end,
              }
            end),
          }),
        }),
        ui.each(groups[active], function(name)
          return ui.row({
            ui.button({
              id = "styling:choice:" .. name,
              text = name,
              on_click = function()
                selected = name
              end,
            }),
          }, { variant = "selectable", selected = selected == name })
        end),
        ui.row({
          ui.action_button({
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
      })
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
