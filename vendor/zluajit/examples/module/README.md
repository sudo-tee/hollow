# Zig module example

This directory contains a minimal working example of Zig module that can be
imported from Lua.

```sh
$ zig build
$ LUA_CPATH="./zig-out/lib/lib?.so" luajit <<< "require('module').greet('fellow readers')"
Hello fellow readers from Zig module!
```

