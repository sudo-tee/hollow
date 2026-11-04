# Find in terminal

Press `<leader>f` or `<leader>/` (by default `<C-Space>` then `f` or `/`), or
run the **find** action from the command palette, to search the current
terminal pane without entering copy mode.

The compact one-line bar at the top right searches while you type. Queries are
literal: punctuation is not interpreted as a pattern, ASCII letters ignore case,
and other bytes match exactly. Matches include scrollback and soft-wrapped text.
The `index/count` beside the input updates incrementally; a trailing `…` means
the scan is not caught up yet. Matching cells are highlighted, with a distinct
selected match.

| Key | Effect |
| --- | --- |
| Enter | Select the next older match, wrapping at the oldest |
| Shift+Enter | Select the next newer match, wrapping at the newest |
| Tab | Close Find and continue in copy mode with `\V<query>` |
| Escape / × | Close Find and clear highlights |

The first available match is selected automatically, starting with the newest
results available to the incremental scan. Navigation scrolls to the match;
closing Find leaves the viewport there. Reopening remembers the last query.
Emptying the field clears matches. Queries are limited to 8192 UTF-8 bytes.

Find is bound to its original pane: changing panes, closing the pane, entering
copy mode, or reloading configuration cancels it. An unfinished exclusive
dialog prevents it from opening. Find itself is stackable, like the Lua REPL,
so another dialog can open above it without replacing that dialog's input.
Lua-rendered panes are not searchable.

## Lua

```lua
hollow.ui.find.open({ query = "error.log" })
hollow.ui.find.close()
hollow.keymap.set("<leader>f", "find")
```

`open()` accepts `query`, `width` (cells, default 60), and `theme`; it returns
a modal handle, or `nil` if unavailable. Repeated opens return the existing
handle without replacing its query. It reuses the shared incremental search
backend but does not capture copy-mode history.

To select or yank a match, press Tab: copy mode opens with the same literal
query as `\V<query>`. For case-sensitive pattern queries, press `/` inside
[copy mode](copy-mode.md#search) and enter a query without the `\V` prefix.

`<leader>/` also opens Find by default. To restore the old copy-mode search
prompt on that chord:

```lua
hollow.keymap.set("<leader>/", "copy_mode_search")
```
