# Command line

Open with `<leader>c` (default leader: Ctrl+Space, then unmodified `c`), the `command_line` action,
or `hollow.ui.command_line.open()`. The compact bottom prompt has two explicit modes:

```text
split_vertical                         Action (default)
my_action {"count":2,"text":"hello"}    Action with JSON arguments
=hollow.term.current_pane().id          Lua expression
=hollow.config.reload()                Lua call
```

Actions use the existing registry and `hollow.action.invoke`, including overrides
and schema validation, with `origin = "command_line"`. Arguments must be one JSON
object; use Lua mode for positional arguments or arbitrary Lua values.

**Lua runs synchronously in Hollow's live runtime, with config/plugin privileges.
It is not sandboxed. Run only trusted code; infinite loops block the UI.**

## Interaction

- **Enter:** accept an open completion selection; otherwise execute once.
  Successful actions and Lua without output close the prompt and restore focus.
- **Results:** returned Lua values and `print()` output appear in a bounded,
  dismissible result notification. No terminal input is sent. Results expire
  after six seconds; use the REPL for sustained inspection.
- **Errors:** retain the editable draft and show a short error. Execution is never
  automatically retried. Incomplete Lua is an error, not a multiline continuation.
- **Tab / Shift+Tab:** complete/cycle. Action mode offers registered action names
  and top-level fields of object argument schemas. Lua shares REPL completion and
  signature hints. Discovery never runs schema parsers or Lua expressions.
- **Up/Down:** navigate the open, input-filtered completion menu, otherwise browse
  history matching the typed prefix. **Ctrl+P/Ctrl+N** browse all history.
- **Esc:** dismiss completion first, otherwise close and preserve the draft.
- **Ctrl+R:** move a Lua draft into the full REPL, without executing it.
- **Ctrl+U:** clear input. Clipboard shortcuts paste without executing.

Draft and history are separate from the REPL. Command-line history holds the last
100 successful submissions and survives restarts and config reloads, saved as
`command_line_history` in Hollow's user data directory. Lua globals are shared.

```lua
hollow.ui.command_line.open({ text = "=hollow.config.get('fonts')", width = 80 })
hollow.ui.command_line.close()
hollow.keymap.set("<C-S-p>", "command_line")
```

Opening returns the existing handle if already open, or `nil` while another
exclusive modal has unfinished input. `theme` accepts input-theme overrides.
