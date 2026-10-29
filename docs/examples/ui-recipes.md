# UI recipes

Drop-in widgets, top bar replacements, and picker patterns.
Each snippet is a complete, paste-able Lua block.

For the widget model see [Custom UI](../custom-ui.md).
For the API see [`hollow.ui`](../reference/lua/ui.md) and
[`hollow.ui.workspace`](../reference/lua/workspace.md).

## Theme-aware buttons, tabs, lists and panels

[`examples/ui-styling.lua`](../../examples/ui-styling.lua) is a runnable,
public-API-only example. From your config:

```lua
dofile("/path/to/hollow/examples/ui-styling.lua")()
```

It opens a modal with theme-owned panel chrome, tabs, selectable rows and a
primary action. Tab and choice clicks update model state; Done or Escape closes
the modal. Runtime theme changes refresh the open panel and controls. No bars
are replaced. The path above must point to your checkout.

The authoring pattern: select a widget palette with `ui.modal({ theme = "select",
... })`, pass its render callback's palette to button/tab primitives, and leave
row selection paint to `variant = "selectable"`. Use `ui.style` for local
overrides; do not import private recipe helpers. For disabled actions, set
`disabled = true` on `ui.button` or `ui.action_button` rather than only dimming
their colors.

## Replace the top bar entirely

A minimal top bar with a workspace button, a spacer, and a clock.

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  height = 24,
  render = function(ctx)
    return {
      hollow.ui.workspace.topbar_button({ text = " workspaces " }),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

## Top bar that shows cwd and foreground process

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  height = 24,
  render = function(ctx)
    local pane = ctx.term.pane
    local cwd = pane and pane.cwd or ""
    local fg  = pane and pane.foreground_process or ""
    return {
      hollow.ui.span("  " .. cwd, { fg = "#7e9cd8" }),
      hollow.ui.spacer(),
      hollow.ui.span(fg, { fg = "#9cabca", italic = true }),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

## Mount a bottom bar

```lua
hollow.ui.bottombar.mount(hollow.ui.bottombar.new({
  height = 22,
  render = function(ctx)
    return {
      hollow.ui.bar.time("%H:%M"),
      hollow.ui.spacer(),
      hollow.ui.span("hollow", { fg = "#727169" }),
    }
  end,
}))
```

## Sidebar with a list of panes in the current tab

```lua
hollow.ui.sidebar.mount(hollow.ui.sidebar.new({
  side = "right",
  width = 32,
  render = function(ctx)
    local tab = ctx.term.tab
    if not tab then return hollow.ui.column({}) end

    local rows = {
      hollow.ui.row({
        hollow.ui.text("panes in " .. (tab.title or "<tab>"),
          { bold = true, fg = "#7e9cd8" }),
      }, { fill_bg = "#1f1f28" }),
    }

    for i, p in ipairs(tab.panes) do
      local label = p.title
        or p.foreground_process
        or hollow.util.basename(p.cwd or "")
        or string.format("pane %d", i)
      rows[#rows + 1] = hollow.ui.row({
        hollow.ui.text(p.is_focused and "* " or "  "),
        hollow.ui.text(label, { bold = p.is_focused }),
      })
    end

    return hollow.ui.column(rows)
  end,
}))
```

## Clickable button with a toast

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  height = 24,
  render = function()
    return {
      hollow.ui.button({
        id = "hello",
        text = " hello ",
        style = { fg = "#dcd7ba", bg = "#2d4f67", radius = 4,
                  padding = { left = 6, right = 6 } },
        on_click = function()
          hollow.ui.notify.info("hello from a clickable node",
            { ttl = 1500 })
        end,
      }),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

## Open a domain picker

```lua
hollow.keymap.set("<leader>d", function()
  hollow.ui.select.open({
    prompt = "Domain",
    items = {
      { name = "pwsh",  desc = "PowerShell" },
      { name = "wsl",   desc = "WSL" },
      { name = "cmd",   desc = "Command Prompt" },
    },
    label = function(item) return item.name end,
    detail = function(item) return item.desc end,
    actions = {
      {
        name = "open",
        desc = "new tab",
        fn = function(item)
          hollow.ui.select.close()
          hollow.term.new_tab({ domain = item.name })
        end,
      },
    },
  })
end, { desc = "open domain" })
```

## Confirm dialog

A reusable confirm overlay built on `hollow.ui.input`.

```lua
local function confirm(prompt, on_confirm)
  hollow.ui.input.open({
    prompt = prompt .. " (type 'yes' to confirm)",
    default = "",
    on_confirm = function(value)
      if value == "yes" then on_confirm() end
    end,
  })
end
```

## Workspace switcher with WSL discovery

```lua
hollow.ui.workspace.configure({
  prompt = "Workspaces",
  sources = {
    {
      name = "Ubuntu",
      host = { type = "wsl", distro = "Ubuntu" },
      domain = "UbuntuWSL",
      roots = {
        "/home/me/Projects",
      },
    },
  },
  format_item = function(ws)
    return {
      hollow.ui.span(ws.is_active and "* " or "  "),
      hollow.ui.span(ws.name, { bold = ws.is_active }),
      hollow.ui.span(ws.cwd and ("  " .. ws.cwd) or "",
        { fg = "#727169" }),
    }
  end,
})

hollow.keymap.set("<leader>ws", function()
  hollow.ui.workspace.open_switcher()
end, { desc = "open workspace switcher" })
```

## Workspace switcher with Podman inside WSL

Discover projects inside an existing, running Linux container and open terminal
panes there too. Replace the distro, WSL user, container name and roots below.
The selected WSL user must have access to that container (important for rootless
Podman). This example uses `/bin/sh`, which must exist inside the container;
use `/bin/bash -l` instead if Bash is installed and you want a login shell.

```lua
local container_host = {
  type = "podman",
  container = "dev",
  via = {
    type = "wsl",
    distro = "Ubuntu-26.04",
    user = "me",
  },
}

hollow.config.set({
  domains = {
    ContainerDev = {
      shell = "/bin/sh",
      host = container_host,
    },
  },
})

hollow.ui.workspace.configure({
  prompt = "Container projects",
  sources = {
    {
      name = "Podman dev",
      host = container_host,
      domain = "ContainerDev",
      roots = { "/work" },
    },
  },
})

hollow.keymap.set("<leader>ws", function()
  hollow.ui.workspace.open_switcher()
end, { desc = "open workspace switcher" })
```

- `host.via` selects where the container CLI runs: Windows → WSL → container.
  It belongs inside the host descriptor, not directly on the workspace source.
- `sources[].host` controls filesystem discovery; `roots` are paths **inside the
  container**, not Windows or WSL-host paths.
- `sources[].domain` selects the terminal domain. That domain's `host` routes
  panes into the same container. A discovery host alone does not route panes;
  omitting `domain` inherits the current pane's domain instead.
- New tabs inherit the active pane's domain unless another domain is explicitly
  requested. Splits also inherit the active pane's domain.
- `via.user` selects the WSL user running Podman, not the container user. Hollow
  preserves the container's configured user and deploys its bundled agent there.

For Docker, change `type = "podman"` to `type = "docker"`; optionally add
`context = "my-context"` to the host descriptor. Both CLIs must be available
inside the selected distro. See [host connector options](../reference/lua/host.md)
and [workspace sources](../reference/lua/workspace.md#sources).

## Workspace button in the top bar

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  height = 24,
  render = function()
    return {
      hollow.ui.workspace.topbar_button({ text = " workspaces " }),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

## Progress-style toasts

`hollow.ui.notify.show` returns a handle that you can clear or
replace. Compose with a long-lived emitter:

```lua
local current = nil
local function progress(label, value)
  if current then hollow.ui.notify.clear() end
  current = hollow.ui.notify.show(
    string.format("%s [%s]", label, string.rep("#", value)),
    { ttl = 60000 }
  )
end
```

(Notification handles are not directly exposed today; clearing is
done by calling `hollow.ui.notify.clear()`.)

## See also

- [Custom UI](../custom-ui.md) — widget model
- [Plugins](../plugins.md) — turn these into a plugin
- [`hollow.ui`](../reference/lua/ui.md) — full API
