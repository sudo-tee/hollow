# Context menu implementation plan

Status: implemented; basic interactive checks pass on Windows.

## Scope

Add a reusable, themed Lua UI menu with two callers: terminal-pane right-click and Shift+click on the top-bar `+`.
Support one level of submenus, used by Dock to select a workspace edge.
Other context-menu surfaces and search inside menus are out of scope.

## 1. Build the reusable menu

- Render with Hollow’s existing Lua UI components and Clay overlay path.
- Accept either a pointer position or a UI element’s bounds as the anchor.
- Convert anchors to overlay-local coordinates, account for bars and sidebars, and flip or clamp the menu to fit the visible content area.
- Support enabled and disabled rows, separators, mouse hover and selection, scrolling, and Up/Down, Enter, and Escape.
- Keep the keyboard-highlighted row visible, skip disabled rows and separators, and render only the visible portion of long lists.
- Give the menu temporary UI input ownership without changing the active terminal pane.
- Close before invoking an item callback and distinguish Escape and outside-click from selection and lifecycle invalidation.
- Do not displace an unfinished exclusive modal.
- Add menu-specific pointer capture to the overlay input path without changing click-through behavior for other overlays.
- Consume the full outside-click gesture, including its release after the menu is gone.
- Invalidate the menu on window focus loss, config reload, tab or workspace change, or loss of its target or anchor.

## 2. Route terminal right-clicks

Use the terminal pane actually hit by the pointer, not the active pane as a fallback.
Preserve existing input guards and higher-priority UI hit handling.

| Terminal menu | Mouse reporting in hit pane | Gesture | Result |
| --- | --- | --- | --- |
| Enabled | On | Right-click | Forward to the terminal app, even if Hollow has a selection |
| Enabled | Off | Right-click | Open Hollow’s menu |
| Enabled | Either | Shift+right-click | Open Hollow’s menu |
| Disabled | Either | Either | Preserve legacy behavior, including right-click-to-copy |

- Decide ownership on press and retain it for the gesture, including across pointer movement, modifier changes, and menu dismissal.
- Keep app-owned input on the existing terminal mouse encoder path; do not detect application names or synthesize mouse reports.
- Suppress the opening release and held-right motion for menu-owned gestures so they neither activate a row nor leak to the terminal.
- Handle lost capture and focus loss without stealing the next independent gesture.

## 3. Wire terminal actions and configuration

The default groups are **Copy / Paste**, **Split Right / Split Down**, **Float or Unfloat / Hide / Zoom or Unzoom / Dock or Undock**, and **Close Pane**.
Show state-dependent labels and keep unavailable actions visible but disabled.

- Resolve a stable clicked-pane identity when opening, then revalidate the pane and the selected action immediately before dispatch.
- Reuse existing pane-operation rules and add explicit targeting where current actions assume the active pane.
- Never temporarily focus the target to make an action work; allow only the focus change that belongs to the chosen operation.
- Use the clipboard paste path so pane-specific behavior such as bracketed paste is preserved.
- Enable Copy only for a selection owned by the target pane and use the existing copy-and-clear behavior.
- On Escape or outside-click, copy and clear only if the same target-owned selection present at opening still exists.
- Track selection identity rather than text equality, so a cleared or replaced selection cannot be copied by a stale menu.
- Never auto-copy on item activation, invalidation, or dismissal of the `+` menu.
- Expose Lua configuration for replacing and reordering the flat list by built-in ID, inserting separators, and adding labeled callbacks that receive the clicked pane.
- Keep the terminal menu enabled by default and make opt-out independent of the reusable component.

## 4. Use the same menu for top-bar domains

- Leave plain click on `+` unchanged.
- Anchor the Shift+click menu to the `+` button’s rendered bounds.
- With zero available domains, do nothing; with one, select it directly; with multiple, show the scrollable menu.
- Reuse the existing open-tab path, including `insert_at_end` and incompatible-domain confirmations.
- Keep other domain actions on their existing searchable picker.

## 5. Document and verify

- Add Lua API types in `types/hollow.lua` and a user guide linked from `docs/README.md` with both gestures, the copy-on-dismiss behavior, and examples of customization and opt-out.
- Add native input regressions for the routing matrix, selection precedence, release and motion ownership, lost capture, and preserving unrelated gestures.
- Add Lua tests for menu navigation and scroll bounds, disabled rows, anchor placement, close-before-callback ordering, stale targets and selections, and the zero-, one-, and multiple-domain paths.
- Verify that actions target an inactive pane without focusing it on open, and that stateful labels and action availability match existing pane behavior.
- Run `zig build test-all --summary failures`, `stylua --check` on touched Lua, and `./launch.sh --build-only` for the Windows build.
- Manually verify a shell, Neovim with mouse enabled, and tmux with mouse enabled on Windows, including an inactive split, a long domain list, and anchors near window edges.
