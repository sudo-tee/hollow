# Quick select

Quick select puts keyboard hints over links in the active pane. Type a hint to
open or copy its target without reaching for the mouse.

Press `<leader>q` with the default keymap:

1. Hollow scans visible rows in the active pane.
2. Each detected link receives a one- or two-letter hint.
3. Type the hint to open the link.
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

Matching is limited to the active pane's visible viewport. Wrapped links split
across rows are not combined.

## Actions

Two built-in actions are available:

| Action | Result |
| --- | --- |
| `quick_select` | Open selected target with configured hyperlink opener |
| `quick_select_copy` | Copy selected target to clipboard |

Bind copy mode or choose different chords from your config:

```lua
hollow.keymap.set("<leader>q", "quick_select")
hollow.keymap.set("<leader>y", "quick_select_copy")
```

`quick_select` uses `hyperlinks.opener` when configured. Otherwise it uses the
platform default application.

## Hint keys

Hints use lowercase letters, prioritizing home-row keys. Up to 26 matches use
one key; larger sets use two. Typing the first key filters displayed hints to
matching candidates.
