# Quick select

Quick select puts keyboard hints over useful text in the active pane. Type a
hint to open a link or copy another match without reaching for the mouse.

Press `<leader>q` with the default keymap:

1. Hollow scans visible rows in the active pane.
2. Each detected match receives a one- or two-letter hint.
3. Type the hint to open a link or copy another match.
4. Press `Backspace` to remove the last typed hint character, or `Esc` to
   cancel.

Quick select stays active across terminal output and layout changes, refreshing
its visible hints when needed. Changing panes or clicking cancels it. When no
links match, Hollow shows a short notification instead of entering hint mode.

## Matches

Quick select recognizes:

- OSC 8 hyperlinks emitted by terminal applications
- URLs accepted by the [`hyperlinks`](reference/lua/config.md#hyperlinks) config
- `www.` addresses when `hyperlinks.match_www` is enabled
- IPv4 addresses, with optional ports
- Text inside single quotes, double quotes, or backticks
- Unix and Windows paths, dotfiles, and filenames with extensions

OSC 8 hyperlinks and URLs open with the configured opener. Other patterns copy
their matched text to the clipboard. Quotes themselves are not included in
copied quoted text.

Matching is limited to the active pane's visible viewport. Wrapped links split
across rows are not combined.

## Actions

Two built-in actions are available:

| Action | Result |
| --- | --- |
| `quick_select` | Open selected links; copy IPs, quoted text, and filenames |
| `quick_select_copy` | Copy selected target to clipboard |

Bind copy mode or choose different chords from your config:

```lua
hollow.keymap.set("<leader>q", "quick_select")
hollow.keymap.set("<leader>y", "quick_select_copy")
```

`quick_select` uses `hyperlinks.opener` when configured. Otherwise it uses the
platform default application.

## Configuration

Use `quick_select.actions` to change what built-in match types do. Actions may
be `"open"`, `"copy"`, a callback, or a command specification:

```lua
hollow.config.set({
  quick_select = {
    actions = {
      -- Command arguments bypass the shell. `{match}` is substituted safely.
      filename = {
        command = { "code", "{match}" },
      },

      -- To use Neovim instead, connect to an existing server:
      -- filename = {
      --   command = { "nvim", "--server", "/tmp/nvim.sock", "--remote", "{match}" },
      -- },

      ip = "copy",
      url = "open",
    },
  },
})
```

Callbacks receive `(text, context)`. `context.kind` is `"url"`, `"ip"`,
`"quote"`, `"filename"`, or `"custom"`. Command actions run asynchronously
on Hollow's host OS and pass arguments directly without a shell. Since Hollow
is Windows-native, command actions run Windows executables, not commands inside
WSL. Terminal applications need an existing server, GUI frontend, or callback
that deliberately opens a pane/tab; a detached command has no interactive
terminal. Function actions provide full control and may use APIs such as
`hollow.term.run_domain_process` when work must run in a configured domain.

Add custom matches with Lua string patterns. Custom patterns run after URL/OSC
8 detection but before built-in IP, quote, and filename detection, so they can
override generic matches:

```lua
hollow.config.set({
  quick_select = {
    patterns = {
      "%x%x%x%x%x%x%x+", -- hexadecimal strings of at least seven characters
      {
        pattern = "ISSUE%-%d+",
        action = { command = { "code", "--goto", "{match}" } },
      },
      {
        pattern = "TODO:%s+[%w_-]+",
        action = "copy",
        enabled = true,
      },
    },
  },
})
```

Patterns use Lua pattern syntax, not PCRE. String entries default to copying.
Table entries support `pattern`, `action`, and `enabled` fields.

## Action event

Hollow exits quick-select mode, then emits `quick_select:action_executed` after
an action succeeds or is successfully dispatched. Use it for notifications or
bookkeeping:

```lua
hollow.events.on("quick_select:action_executed", function(event)
  hollow.ui.notify.info(
    string.format("Quick select %s: %s", event.action, event.text),
    { ttl = 1800 }
  )
end)
```

The event payload contains:

| Field | Value |
| --- | --- |
| `text` | Matched text |
| `kind` | `url`, `ip`, `quote`, `filename`, or `custom` |
| `action` | `open`, `copy`, `callback`, or `command` |
| `pattern_index` | One-based custom pattern index, or `nil` for built-ins |

## Hint keys

Hints use lowercase letters, prioritizing home-row keys. Up to 26 matches use
one key; larger sets use two. Typing the first key filters displayed hints to
matching candidates.
