local M = {}

local config = {
  resize_amount = 0.05,
  keys = {
    ["<C-h>"] = { type = "focus", vim_key = "h", direction = "left" },
    ["<C-j>"] = { type = "focus", vim_key = "j", direction = "down" },
    ["<C-k>"] = { type = "focus", vim_key = "k", direction = "up" },
    ["<C-l>"] = { type = "focus", vim_key = "l", direction = "right" },
    ["<C-A-h>"] = { type = "resize", vim_key = "h", direction = "left" },
    ["<C-A-j>"] = { type = "resize", vim_key = "j", direction = "down" },
    ["<C-A-k>"] = { type = "resize", vim_key = "k", direction = "up" },
    ["<C-A-l>"] = { type = "resize", vim_key = "l", direction = "right" },
    ["<C-Left>"] = { type = "focus", vim_key = "Left", direction = "left" },
    ["<C-Down>"] = { type = "focus", vim_key = "Down", direction = "down" },
    ["<C-Up>"] = { type = "focus", vim_key = "Up", direction = "up" },
    ["<C-Right>"] = { type = "focus", vim_key = "Right", direction = "right" },
    ["<C-A-Left>"] = { type = "resize", vim_key = "Left", direction = "left" },
    ["<C-A-Down>"] = { type = "resize", vim_key = "Down", direction = "down" },
    ["<C-A-Up>"] = { type = "resize", vim_key = "Up", direction = "up" },
    ["<C-A-Right>"] = { type = "resize", vim_key = "Right", direction = "right" },
  },
}

function M.setup(opts)
  if opts then
    if opts.resize_amount then config.resize_amount = opts.resize_amount end
    if opts.keys then config.keys = opts.keys end
  end
end

function M.get_config()
  return config
end

return M
