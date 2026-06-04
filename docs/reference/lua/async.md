# `hollow.async`

Coroutines and promises for sequencing queued mux operations.
Use this when you want to script a series of `split_pane`, `new_tab`,
or `new_workspace` calls in order and act on the result of each.

## Functions

```lua
hollow.async.run(fn)                      -- start a coroutine; returns thread
hollow.async.await(register)              -- suspend until resolve/reject
hollow.async.promise(register)            -- returns a HollowPromise
hollow.async.next_tick()                  -- yield to the host
```

`register` is a function that takes `(resolve, reject)`. Call
`resolve(value)` or `reject(error)` exactly once.

## Example: sequential flow

```lua
hollow.async.run(function()
  local split = hollow.async.await(function(resolve)
    hollow.term.split_pane({
      direction = "vertical",
      on_complete = resolve,
    })
  end)

  if split.success then
    hollow.term.set_pane_tags({ "editor" }, split.pane_id)

    local tab = hollow.async.await(function(resolve)
      hollow.term.new_tab({ domain = "wsl", on_complete = resolve })
    end)

    if tab.success then
      hollow.term.focus_tab(tab.tab_id)
    end
  end
end)
```

## Example: promise chain

```lua
local p = hollow.async.promise(function(resolve)
  hollow.term.split_pane({ direction = "vertical", on_complete = resolve })
end)

p:next(function(result)
  if result.success then
    return hollow.term.set_pane_tags({ "editor" }, result.pane_id)
  end
end):catch(function(err)
  hollow.ui.notify.error("split failed: " .. tostring(err), { ttl = 2000 })
end)
```

## `HollowPromise`

```lua
HollowPromise<T> = {
  status = function(self) -> "pending" | "fulfilled" | "rejected",
  value  = function(self) -> T | nil,
  error  = function(self) -> any,
  next   = function(self, on_resolve?, on_reject?) -> HollowPromise<any>,
  catch  = function(self, on_reject) -> HollowPromise<any>,
  await  = function(self) -> T,
}
```

`await()` blocks the current coroutine until the promise resolves; it
returns the value or raises the error.

## See also

- [`hollow.term`](term.md) — `on_complete` callbacks
- [Panes, tabs, workspaces](../../panes-tabs-workspaces.md)
