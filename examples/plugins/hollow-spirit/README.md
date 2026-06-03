# hollow-spirit

A demo plugin for Hollow that adds a playful companion spirit to your terminal.

## Features

- Reacts to terminal events (bell, tab switches, foreground process changes)
- Displays mood-based notifications
- Configurable name via `setup()`

## Usage

```lua
-- conf/init.lua
require("hollow.plugins").setup({
  plugins = {
    "~/hollow-spirit",
  },
})
```

## Structure

```
hollow-spirit/
  lua/hollow-spirit/init.lua    -- module with M.setup(opts)
  hollow_plugin/hollow-spirit.lua -- autoloaded events, keymaps, commands
```
