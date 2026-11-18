-- Set HOLLOW_CONFIG_PATH to this file. See docs/custom-shaders.md.
local hollow = require("hollow")
local path = assert(os.getenv("HOLLOW_CONFIG_PATH"))
local dir = assert(path:match("^(.*[/\\])"))
local original = { dir .. "mark.glsl", dir .. "swap.glsl" }

hollow.config.set({
  restore_window_placement = false,
  custom_shader = original,
  shader_animation = "off",
  background = {
    opacity = 0.65,
    shader = {
      path = dir .. "bands.glsl",
      render_scale = 0.5,
      animate = false,
    },
  },
})

hollow.keymap.set("<F7>", function()
  -- Reversing the valid pass as well as breaking the other one ensures a
  -- partial replacement is visually distinct from the original chain.
  hollow.config.set({ custom_shader = { dir .. "swap.glsl", dir .. "broken.glsl" } })
end)
hollow.keymap.set("<F8>", function()
  hollow.config.set({ custom_shader = false })
end)
hollow.keymap.set("<F9>", function()
  hollow.config.set({ custom_shader = original })
end)
