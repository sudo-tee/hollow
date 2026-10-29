local hollow = require("hollow")
hollow.config.set({
  default_domain = "demo",
  domains = {
    demo = {
      shell = hollow.platform.is_windows and "powershell.exe" or hollow.platform.default_shell,
    },
  },
  window_title = "Hollow - Clay selectable list",
  window_width = 1100,
  window_height = 720,
})

local tasks = {}
for i = 1, 100 do
  tasks[i] = {
    name = string.format("Task %03d", i),
    detail = i % 2 == 0 and ("Details for task " .. i) or nil,
  }
end
tasks[3].name =
  "A deliberately long task label to exercise horizontal clipping without expanding the panel or wrapping list rows"

hollow.ui.select.open({
  layout = "clay",
  prompt = "Select task",
  items = tasks,
  width = 65,
  max_height = 18,
  label = function(item)
    return { hollow.ui.text(item.name, { fg = "#88c0d0" }) }
  end,
  detail = function(item)
    return item.detail
  end,
  actions = {
    {
      name = "Open",
      fn = function(item)
        if item then
          hollow.log("Selected: " .. item.name)
          hollow.ui.select.close()
        end
      end,
    },
    {
      name = "Inspect",
      key = "<C-r>",
      fn = function(item)
        if item then
          hollow.log("Inspect: " .. item.name)
        end
      end,
    },
  },
  on_cancel = function()
    hollow.log("Clay select cancelled")
  end,
})
