# Clay

Vendored `clay.h` from https://github.com/nicbarker/clay at
`e6cc36941ab2af5d81107617039d6f527a1c660b`.

License: zlib, included at the end of `clay.h`.

Local patches, each marked "Hollow patch" in `clay.h`:

- `Clay_UpdateScrollContainers` revisits the slot after each swapback removal
  (`--i`). Upstream advances past the swapped-in record, so stale scroll
  records could exhaust the fixed scroll array when every scroll container is
  replaced between frames.
- The scroll container array is sized to `maxElementCount` instead of a fixed
  100. Retired scroll records survive one layout, so a context can briefly hold
  two full trees of clip containers when its IDs change. This raises Clay's
  minimum arena (about 1.50 MB to 1.67 MB at 2,048 elements).

When updating Clay, re-apply both and diff against upstream at the new commit.

Hollow's experimental adapter lives in `src/ui/clay_bridge.{h,c}`. Keep Clay's
declaration macros and internal declaration API confined to that C file.
