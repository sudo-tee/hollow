# Next steps

## Done

- ~There is still a [[?900l in the prompt on launch.~
- ~Fix startup crash (mux.zig structural corruption, LUA_GLOBALSINDEX wrong value)~
- ~Fix split segfault (double ResizePseudoConsole on bootstrap triggered SIGWINCH response crash)~
- ~Fix isAlive() data race on pty_windows reader_state.eof~
- ~Cursor not visible (wrong sokol pipeline active during cursor draw; also black fallback color when cursor_has_value=false)~
- ~Per-pane size reporting broken in sizeCallback (now tracks cols/rows on Pane)~
- ~Pane navigation keybinds: focus_pane_left/right/up/down (ctrl+h/l/k/j)~
- ~Split border invisible (sgl_begin_lines was clipped by last pane scissor + 1px on HiDPI; replaced with filled 2px rects, full-framebuffer scissor reset)~

## Annoyances / Polish

- ~Thin configurable border between splits~
- ~Pane navigation: ctrl+shift+arrow_left/right/up/down~
- ~split_pane optional ratio param: hollow.split_pane("vertical", 0.3)~
- ~resize_pane API: hollow.resize_pane("vertical", 0.05) + ctrl+alt+arrows~
- ~close_pane Lua API: hollow.close_pane() + ctrl+shift+w keybind~
- ~Dead pane auto-close: isAlive() now checks WaitForSingleObject as fallback when pipe EOF not yet reported~
- ~Navigating between panes is a bit buggy let's say a create an horizontal split and then a vertical split, the navigation gets a bit weird. Being on the bottom right pane and pressing sthift+ctrl+left will move the focus to the toppane instead of the bottom left one. This is because the navigation is currently based on the position of the panes and not on a graph of the panes. This can be fixed by implementing a graph of the panes and navigating based on that graph instead of the position. This will also allow for more complex layouts in the future.~
- Some keybords shortcuts don't work example in nvim all keymaps with alt+ don't work

## Fonts

- ~Add support for nerd fonts fallback as I see some missing glyphs~
- ~Fonts still need a little bit of work, they show a slight "chromatic aberration" effect. They are likely missing a bit of "smoothing" or "antialiasing" that is causing the jagged edges. This can be fixed by adding support for font smoothing, make it configurable by the user. While you are there move all font config in a subsection `fonts`~
- ~Add the possibility to use a custom font for the terminal~
- ~The font glyph fallback for nerd icons seems to not be working. I see some missing you should bundle a good nerd font with all the symbols. Provide a good fallback configuration for the fonts.~
- ~Add support for ligatures~

## Performance

- ~Add a debug overlay that shows the current FPS, frame time, and other relevant performance metrics.~
- App consumes around 5% cpu on idle
- ~Add a framerate cap to prevent the terminal from consuming too much resources when idle.~
- ~Scrolling performance is not great at least in nvim. Espacially when there are spit windows. Half of the screen is static in this case but most likely we are still rendering full rows~
- ~Add more performace tests and benchmarks to identify bottlenecks and optimize the rendering pipeline.~

## Core features

- Add support for workspaces -> tabs -> splits
  - ~Multi-tab support: Ctrl+T new tab, Ctrl+W close tab, Ctrl+Tab / Ctrl+Shift+Tab switch tabs~
  - ~close_pane / closeTab: last-tab fix, pending_quit flag, sapp_request_quit()~
  - ~newTab segfault fixed: pre-init render_state in bootstrap() before callback registration~
  - ~Tab bar UI (ano rendering exists yeta)~
  - ~Workspace switching UI + API~
- ~Add mouse support for:~
  - ~Click to focus pane~
  - ~Click to set cursor position~
  - ~Click and drag to resize panes~
  - ~scroll wheel support for scrolling through output~
- Add text selection support
- Add copy/paste support

## Windowing

- Add support for removing the title bar but keep the "RESIZE" handle. This is a common feature in terminal emulators that allows for a cleaner look while still maintaining the ability to resize the window.
- Add support for moving the terminal window by dragging anywhere on the terminal surface with a modifier key (e.g., Alt + Drag). This is a convenient feature that allows users to easily reposition the terminal without needing to click on the title bar.

## Lua API

- ~Add api to draw custom widgets like status bar, tab bar, etc. This would allow users to create their own custom interfaces and enhance the functionality of the terminal.~
- Add support for a Lua API that allows users to customize the terminal's behavior and appearance. This could include features such as custom keybindings, themes, and plugins.
- Add support for a Lua API that allows users to create custom commands, layouts, and to call split, tab, workspace management functions. This would provide users with a powerful way to automate and customize their terminal experience.
