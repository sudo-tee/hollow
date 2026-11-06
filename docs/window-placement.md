# Window size and position

On Windows, Hollow remembers its window size, position, and maximized state when it closes normally.
The next launch restores that placement automatically, independently of terminal session restoration.
The `restore_window_placement` configuration option defaults to `true`.
Closing a minimized window does not save its tiny minimized dimensions or reopen it minimized.
Snapped windows reopen at their visible size and position, rather than their previous unsnapped bounds.
This restores the rectangle, not membership in a Windows Snap group.

To disable placement restoration, add this to your user configuration:

```lua
hollow.config.set({ restore_window_placement = false })
```

When disabled, Hollow neither reads nor writes saved placement, and uses `window_width` and `window_height` at startup.
An existing placement file is kept, so enabling the option again restores that saved placement.
Changing the option while Hollow is running controls saving on exit; restoration happens only when opening the window.

Placement is stored in `%APPDATA%\hollow\window-placement.json`.
Delete this file while Hollow is closed to return to the configured initial window size.
Missing, corrupt, or unsupported placement files are ignored, leaving the configured `window_width` and `window_height` defaults in effect.
Windows moves completely off-screen placements onto an available monitor if the monitor layout changes.

The last normally closed Hollow window supplies the placement for future launches.
Forced termination or a crash may leave the previous placement unchanged.
Native Linux and macOS windows do not yet restore placement.
