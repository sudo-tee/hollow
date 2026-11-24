# Dock UX plan

Docked panes look like ordinary splits.
A dock belongs to the window (or workspace), not to the tab, so it should read as part of the window frame.
This plan makes docks visually distinct and lets pane drags target dock positions.

## Visual cues

1. The seam between a dock and the tab region uses the theme's `dock_active` / `dock_inactive` colors instead of the split colors.
2. Each dock gets a faint tint (`ui.dock_tint`, alpha 0–255, 0 disables) so it reads as a panel.
3. Each dock gets a one-row title strip (`dock_header`, on by default) that pushes the pane content down.
   It uses a faint wash of the dock color, stronger when focused, and doubles as the drag handle.
   Items are configurable per slot (`left`, `center`, `right`) from `hide`, `undock`, `title`, `scope`, and `edge`; left docks mirror `left` and `right`.
   Clicking the scope switches it.
4. With the strip disabled, hovering the top of a dock reveals the drag handle and a chip naming the dock, such as `Right dock · Workspace`.
   Narrow docks fall back to a scope-only chip, beside or below the handle.

## Drag targets

- Every pane drag shows window-edge bands along the content area.
  Hovering a band previews the bounds the dock would actually take, computed by simulating the dock carve.
- Dock previews use the dock color and a `Dock Right · Workspace` label, distinct from split previews.
- Tiled panes default to a workspace dock; a moved dock keeps its scope.
  Hold Shift to flip the scope (workspace ↔ global).
- An occupied edge shows a red outline and refuses the drop.
- Docked panes are draggable from their title strip, or their handle when the strip is off:
  - onto another edge to move the dock, keeping its ratio;
  - onto a tiled pane's split zone to undock it there (swap is not offered);
  - Escape or an invalid drop cancels.

## Implementation

- `src/mux/dock_drop.zig`: edge hit-test, drop status, and preview simulation.
- `src/mux/pane_drop.zig`: accepts a null source tab for panes that come from a dock.
- `src/render/sokol_runtime.zig`: dock seams, tint, title strip, hover chip, dock drop and blocked previews.
- `src/mux/dock.zig`: `reserveHeader` insets dock leaves in `App.layoutContentForTab`; `LayoutLeaf.header` carries the strip height.
  The dock carve and drop previews still use the full dock region.
- Theme keys `dock_active`, `dock_inactive` (workspace docks), `dock_global_active`, `dock_global_inactive` (global docks), `dock_tint`; config key `dock_header`.

## Out of scope

- Thicker reserved dock dividers (needs layout reservation changes).
- Swapping a dock with a tiled pane, and dropping docks on tab labels.
- A hidden-dock edge tab for restoring hidden docks.
