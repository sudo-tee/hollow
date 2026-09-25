# Screenshot export

Capture visible rendered content to PNG from command automation:

```sh
hollow-cli pane screenshot /tmp/pane.png
hollow-cli pane screenshot /tmp/pane.png --id 12345
hollow-cli tab screenshot /tmp/tab.png
hollow-cli tab screenshot /tmp/tab.png --index 1
```

Commands return JSON with `path`, `width`, and `height` after file is written.
`pane_screenshot` and `tab_screenshot` are also available as command socket request kinds with `path` and optional `id` fields.
Pane images crop framebuffer to pane bounds; tab images include tab bar and other visible overlays.
Only currently visible tab and panes can be captured; hidden targets return `not_visible`.
Path is interpreted by Hollow process, so use destination path accessible from host running GUI (Windows paths for Windows GUI).
Screenshots require command socket transport.
