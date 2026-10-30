# Lua REPL

Open with `<leader>:` (default leader: `Ctrl+Space`), choose **Open Lua REPL
(live runtime)** in the command palette, or call `hollow.ui.lua_repl.open()`.
The bottom-aligned console uses Clay layout and sizes itself to its content,
with a bounded transcript instead of an empty fixed-height panel.

**This is not a sandbox. Code runs synchronously in Hollow's live Lua runtime
with config/plugin privileges. Execute only trusted code; infinite loops block
the UI. Changes are immediate, not automatically saved to your config.**

```lua
hollow.term.current_pane().id
print(hollow.term.current_workspace().name)
hollow.config.get("fonts")
```

Expressions (optionally prefixed with `=`) show their return values. Statements
and multiline chunks work too. `print(...)` inside console chunks appears in
the transcript; normal application logging is unchanged. Returned and printed
tables are pretty-printed recursively, with cycle/shared-reference markers.
`inspect(value)` returns the same formatted text, without changing global
`hollow.inspect`. Inspection uses raw table contents, not metamethods.

```lua
hollow.term.current_pane() -- inspect the whole snapshot
print({ colors = hollow.config.get("fonts"), enabled = true })
inspect({ nested = { answer = 42 } })
```

Inspection limits: four table levels, 50 entries per table, 200 visited items,
512 bytes per string and 8 KiB per formatted value. Truncation is marked.

## Completion and signatures

Type `hollow.` or `hollow.term.cur` and press **Tab**. Completion uses live
table fields, including plugin tables and table-valued `__index` prototypes.
The menu expands above the input. Tab opens it; repeated Tab/Shift+Tab or
Down/Up moves the highlighted selection without changing your input.
**Enter accepts a candidate without running it** when the menu is visible;
press Enter again to execute. A single match inserts immediately; with several,
Tab first extends input to their shared prefix. Esc dismisses the menu before
closing the console. Elsewhere, Tab inserts two spaces. One help line shows
shortcuts for the active context.

Each candidate shows its value type (`fn`, `table`, `string`, …) and highlights
the typed prefix. Private `_names` sort after public fields unless the query
starts with `_`.

Parameter/return-type hints appear for known Hollow functions and while typing
their arguments. Hints come from `types/hollow.lua`, bundled with the app;
LuaLS is not required. Function aliases share hints; untyped plugin functions
show `(...)`.

Completion never executes expressions or calls `__index` functions. It does
not infer local variables or fields after function calls/index expressions.
Assign a snapshot to a global to complete its live fields:

```lua
pane = hollow.term.current_pane()
-- Next submission: type pane. then Tab
```

Completion is suppressed inside strings/comments. Up to 128 candidates are
shown, from at most 4096 inspected keys and eight prototype levels.

When updating API typings, regenerate hints with
`python3 scripts/generate-repl-signatures.py`; `--check` checks for stale hints.

| Key | Behavior |
| --- | --- |
| Enter | Accept completion, otherwise run; incomplete Lua blocks continue on a new line |
| Shift+Enter | Insert newline |
| Ctrl+Enter | Force submission, including incomplete-code errors |
| Ctrl+V / Ctrl+Shift+V / Shift+Insert / Cmd+V | Paste without executing |
| Up/Down | Navigate completion when open, otherwise previous/next command |
| Ctrl+P/Ctrl+N | Previous/next command; restore draft after history |
| Left/Right, Home/End, Backspace/Delete | Edit input |
| Tab / Shift+Tab | Complete/cycle forward or backward; two spaces when no match |
| Ctrl+U | Clear input |
| Ctrl+L | Clear transcript |
| PageUp/PageDown or mouse wheel | Scroll transcript (wheel over the menu cycles candidates; click accepts one) |
| Shift+Up/Down | Scroll transcript one line |
| Ctrl+Home / Ctrl+End | Jump to oldest / latest output; dragging the scrollbar also works |
| Esc | Dismiss completion, otherwise close, preserving draft/history/transcript |

History holds up to 100 chunks; transcript holds up to 300 lines. Both last
until config/runtime reload. Global assignments update live runtime globals;
`local` variables belong to one submitted chunk, as in ordinary Lua. Console
keystrokes and pasted text never go to the terminal PTY.

```lua
hollow.ui.lua_repl.open({ width = 100, height = 26 }) -- dimensions in cells
hollow.ui.lua_repl.close()
hollow.keymap.set("<C-S-l>", "lua_repl")
```

Default width is 80 cells. Omit `height` for automatic sizing; set it to keep
a fixed-height panel.

Opening is refused while another modal has unfinished input.
