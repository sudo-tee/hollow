# hollow.shader

Compile-check a Ghostty-compatible Shadertoy file without applying it.

## validate(path)

```lua
local result = hollow.shader.validate("C:/Users/me/shaders/cursor_trail.glsl")
if not result.valid then
  hollow.ui.notify.error(result.message)
end
```

`path` is a path on the machine running Hollow, not inside a WSL or SSH pane.
Relative paths resolve against Hollow's working directory.
The path must be a non-empty string without NUL bytes, at most 32 KiB long.
Source files are limited to 256 KiB; source containing NUL bytes is rejected.
The file is read again on every call.

The returned table contains:

- `valid`: whether compilation succeeded.
- `code`: one of the values below.
- `message`: diagnostic text, at most 4096 bytes; empty on success.
- `target`: `"hlsl"` on Windows, `"glsl"` elsewhere.

| Code | Meaning |
| --- | --- |
| `ok` | Compilation succeeded |
| `invalid_argument` | Missing, non-string, empty, or NUL-containing path |
| `read_failed` | File could not be read; `message` names the native error |
| `resource_exhausted` | File or path exceeds its size limit |
| `shader_invalid` | Invalid GLSL, missing `mainImage`, or NUL source |
| `translation_failed` | Compiler initialization or backend translation failed |
| `out_of_memory` | Insufficient memory to read or compile the shader |

Ordinary input errors return a result table instead of throwing.
Compiler messages retain source line numbers.
Compiler messages are not stable strings to match programmatically.
Use `code` for programmatic error handling.

Validation is synchronous and uses the same compiler as shader loading.
It creates no GPU resources and does not change config or the active chain.
It does not check GPU pipeline creation, performance, or visual correctness.
Validate the selected file rather than rescanning a directory every redraw.

See [Custom shaders](../../custom-shaders.md) for applying validated files.
