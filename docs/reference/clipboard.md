# Terminal clipboard access

Copying selected text and pasting with Hollow's shortcuts are separate from
terminal applications reading the clipboard through OSC 52 or Kitty OSC 5522.

## Manual test

Rebuild/restart Hollow, then run inside a WSL/Linux/macOS terminal pane:

```sh
python3 scripts/test_clipboard.py
```

The interactive walkthrough asks before overwriting your clipboard with
`clipboard-test`, checks initial denial, guides you through the automatic confirmation,
and checks that the following read is denied again. Terminal settings are
restored on completion, timeout, or Ctrl+C. Clipboard contents are never printed.

Individual probes (the write command replaces your clipboard):

```sh
python3 scripts/test_clipboard.py write
python3 scripts/test_clipboard.py read --expect denied
# Select Allow once in the automatic prompt, in the same pane, before retrying:
python3 scripts/test_clipboard.py read --expect test-text
```

An empty OSC 52 response cannot distinguish denied access from an approved
empty clipboard; the fixed, nonempty test text makes the walkthrough useful.

## Reads: ask before allowing access

Terminal clipboard reads are denied immediately unless explicitly approved.
Hollow answers unapproved OSC 52 reads with an empty clipboard and Kitty reads
with `EPERM`, then automatically asks **Allow next clipboard read?** for the
focused terminal pane. **Deny** is selected by default. Clipboard contents are
not read until you explicitly choose **Allow once**. The original request has
already been denied; it is not retained or replayed.

Requests are coalesced while a clipboard prompt is open, and automatic prompts
are throttled to at most one per five seconds. Background panes and unsupported
clipboard formats do not open prompts. An unfinished exclusive dialog is never
replaced, and skipped prompts are not queued to appear later.

To approve:

1. Focus the requesting terminal pane.
2. Use the automatic confirmation. If another dialog prevented it, close that
   dialog and choose **Allow next clipboard read** (`allow_clipboard_read`) from
   the command palette.
3. Select **Allow once**. The default button is **Deny**.
4. Retry the request in the terminal application within 30 seconds.

Approval captures the current plain-text clipboard (maximum 48 KiB) and
allows one supported read from that pane. It does not expose later clipboard
changes. Programs sharing that pane, including remote programs, are not
distinguished: any of them could consume the approval.

Approval expires after 30 seconds or is revoked by pane/window focus loss,
terminal reset, pane teardown, configuration reload, or the
`revoke_clipboard_read` action. No persistent allow policy or Kitty password
grant is created. Only the ordinary `text/plain` clipboard is supported;
primary-selection and binary/image reads are unsupported. MIME-target listing
reports a static `text/plain` capability and exposes no clipboard contents.

## Writes and paste

Existing text-only terminal clipboard writes remain supported. Reads do not
inherit write permission. Hollow's own paste shortcuts retain the existing
inline/bracketed-paste encoding and unsafe-paste checks; installing clipboard
read support does not opt these shortcuts into Kitty's deferred paste events.

The Ghostty C read callback is synchronous: its request and reply function are
valid only until the callback returns. Hollow therefore uses upfront one-shot
approval and application retry instead of blocking the GUI for a prompt or
keeping invalid request pointers.
