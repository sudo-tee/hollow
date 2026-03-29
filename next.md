# Next steps

## Done

- ~There is still a [[?900l in the prompt on launch.~
- ~Fix startup crash (mux.zig structural corruption, LUA_GLOBALSINDEX wrong value)~

## Annoyances / Polish

- Cursor is not visible / cursor style not respected
- Thin configurable border between splits
- Per-pane size reporting is broken in sizeCallback (always reports global config.rows/cols)

## Core features

- Add support for workspaces -> tabs -> splits
  - Tab bar UI (no rendering exists yet)
  - Workspace switching UI + API
  - Pane navigation keybinds: focus_pane_left / right / up / down
- Add cursor support
- Add text selection support
- Add copy/paste support

## Fonts

- Fonts still need a little bit of work, they show a slight "chromatic aberration" effect. They are likely missing a bit of "smoothing" or "antialiasing" that is causing the jagged edges. This can be fixed by adding support for font smoothing, make it configurable by the user. While you are there move all font config in a subsection `fonts`
- Add the possibility to use a custom font for the terminal
- The font glyph fallback for nerd icons seems to not be working. I see some missing you should bundle a good nerd font with all the symbols. Provide a good fallback configuration for the fonts.
- Add support for ligatures

## Windowing

- Add support for removing the title bar but keep the "RESIZE" handle. This is a common feature in terminal emulators that allows for a cleaner look while still maintaining the ability to resize the window.
- Add support for moving the terminal window by dragging anywhere on the terminal surface with a modifier key (e.g., Alt + Drag). This is a convenient feature that allows users to easily reposition the terminal without needing to click on the title bar.

## Lua API

- Add api to draw custom widgets like status bar, tab bar, etc. This would allow users to create their own custom interfaces and enhance the functionality of the terminal.
- Add support for a Lua API that allows users to customize the terminal's behavior and appearance. This could include features such as custom keybindings, themes, and plugins.
- Add support for a Lua API that allows users to create custom commands, layouts, and to call split, tab, workspace management functions. This would provide users with a powerful way to automate and customize their terminal experience.
