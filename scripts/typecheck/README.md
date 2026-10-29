# UI authoring type fixtures

Run with the project's EmmyLua Rust analyzer:

```sh
emmylua_check scripts/typecheck --warnings-as-errors
```

This checks authoring examples against the public style declarations and private
workspace style-slot contracts. The fixture config loads source/type dependencies
as libraries; it does not suppress diagnostics in the application workspace or
claim that the entire repository is type-clean. Runtime tests remain separate:
`zig build test-lua`.

Covered contracts include conditional layers, fractional/array box shorthands,
false overrides, named style slots, button variants and `ui.text` return types.
These files are analyzer fixtures, not runtime modules.
