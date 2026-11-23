# Drag panes and tabs

Move the pointer near the top of a tiled pane to reveal its handle, then grab it at the top center.
Drag over another pane's left or right edge to split beside it, or over the top or bottom edge to split above or below it.
Drag to the center to swap the panes.
The highlight covers the chosen half of the target pane for a split, or an inset rectangle for a swap.

To move a pane to another tab in the same workspace, drop it on that tab's label for a side-by-side split.
Alternatively, pause over the tab to see a layout map, then drop on another pane in that map to choose exactly where the dragged pane goes.
The preview does not activate the destination tab or resize its terminals.
The running pane and its scrollback move with it.

To reorder tabs without moving panes between them, drag a tab label to the left or right of another label.
An insertion line shows where the tab will go.
Tab dragging only reorders tabs in the current workspace.

Press Escape or release outside a valid target to cancel.
A small square follows the pointer while dragging a pane or tab, even when there is no valid drop target.
The cursor shows a not-allowed icon when you can't drop at the current location.
Floating panes keep their existing edge gestures; pane drops require tiled panes in unzoomed tabs.
The context menu's Move commands are unchanged.
