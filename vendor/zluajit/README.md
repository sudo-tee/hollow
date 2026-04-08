# `zluajit` - Zig bindings to LuaJIT C API

[Documentation](https://www.negrel.dev/projects/zluajit/docs/0.2.0)

`zluajit` provides high quality, ergonomic, well documented and type-safe
bindings to LuaJIT 5.1/5.2 C API. Supporting other Lua versions is a non goal.

## Getting started

See [`examples`](./examples/README.md) to get started embedding LuaJIT in Zig
program or build Zig modules that can be imported from Lua.

It is strongly recommended to build programs depending on `zluajit` using the
LLVM backend and the LLD linker (at least for now) or you will encounter
unwinding errors.

## Building `luajit`

You can build `luajit` executable using `zig build luajit`.

## Contributing

If you want to contribute to `zluajit` to add a feature or improve the code contact
me at [alexandre@negrel.dev](mailto:alexandre@negrel.dev), open an
[issue](https://github.com/negrel/zluajit/issues) or make a
[pull request](https://github.com/negrel/zluajit/pulls).

## :stars: Show your support

Please give a :star: if this project helped you!

[![buy me a coffee](https://github.com/negrel/.github/blob/master/.github/images/bmc-button.png?raw=true)](https://www.buymeacoffee.com/negrel)

## :scroll: License

MIT © [Alexandre Negrel](https://www.negrel.dev/)
