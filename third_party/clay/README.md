# Clay

Vendored `clay.h` from https://github.com/nicbarker/clay at
`e6cc36941ab2af5d81107617039d6f527a1c660b`.

License: zlib, included at the end of `clay.h`.

Local patch: `Clay_UpdateScrollContainers` revisits the slot after each
swapback removal (`--i`, marked "Hollow patch"). Upstream advances past the
swapped-in record, so stale scroll records could exhaust the fixed scroll array
when every scroll container is replaced between frames.

Hollow's experimental adapter lives in `src/ui/clay_bridge.{h,c}`. Keep Clay's
declaration macros and internal declaration API confined to that C file.
