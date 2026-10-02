# OSC 99 notifications

Hollow handles Kitty OSC 99, iTerm2 OSC 9, and rxvt OSC 777 notifications as in-app toasts.
The notification packets are consumed by Hollow and are not written into terminal output.
Hollow intercepts them because the embedded VT API does not expose a desktop-notification callback.

## Supported fields

```text
ESC ] 99 ; metadata ; payload ESC \
```

- `p=title` and `p=body` select notification title and body.
  Payload defaults to `title` when `p` is omitted.
- `i=identifier` lets later packets update or close same notification.
- `d=0` keeps payload open for more chunks; `d=1` completes packet.
- `u=0`, `u=1`, and `u=2` map to Hollow `info`, `warn`, and `error` levels.
- `w=milliseconds` sets toast lifetime; `w=0` keeps toast until dismissed.
- `e=1` accepts Base64-encoded UTF-8 payload.
- `p=close` dismisses notification matching `i`.

Legacy OSC 9 sends `ESC ] 9 ; message` and has no separate title.
Legacy OSC 777 uses `ESC ] 777 ; notify ; title ; body`.
Numeric OSC 9 ConEmu commands are not treated as notifications.

Notifications without `w` use same 3000 ms default as `hollow.ui.notify.show`.
Notifications with an identifier replace previous toast with same identifier in same pane.
An unfocused pane also receives bell attention, with visual flash colored by urgency when visual bell is enabled.

Hollow maps OSC 99 to in-app toasts, not native operating-system notifications.
Click reports, icons, buttons, sounds, and protocol queries are not implemented.

## Examples

```sh
# One-line notification
printf '\033]99;;Build finished\033\\'

# Legacy one-line notification
printf '\033]9;Build finished\033\\'

# Legacy title/body notification
printf '\033]777;notify;Build;Tests passed\033\\'

# Title and body with high urgency and a 5-second lifetime
printf '\033]99;i=build:d=0:p=title;Build finished\033\\'
printf '\033]99;i=build:p=body:u=2:w=5000;All tests passed\033\\'

# Dismiss a notification
printf '\033]99;i=build:p=close;\033\\'
```

Lua handlers can observe `term:notification` through [`hollow.events`](lua/events.md).
