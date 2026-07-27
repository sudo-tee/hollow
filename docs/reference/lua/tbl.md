# `hollow.tbl`

Fluent table wrapper for chaining list transformations.
All methods return `self` (chainable) except where noted (terminal).

```lua
local result = hollow.tbl({ 1, 2, 3 }):map(function(v) return v * 2 end):get()
-- { 2, 4, 6 }
```

## Constructor

```lua
hollow.tbl(t?)                -- wraps a table; callable shorthand
hollow.tbl.new(t?)            -- same
hollow.tbl.range(start, stop, step?)  -- integer range [start, stop]
```

## Chaining methods

| Method | Returns | What it does |
| --- | --- | --- |
| `:get()` | `table` (terminal) | Unwrap to plain table |
| `:each(fn)` | self | Side-effect only; `fn(v, i, t)` |
| `:map(fn)` | self | Transform elements; `fn(v, i, t) -> new_v` |
| `:filter(fn)` | self | Keep elements where `fn` returns truthy |
| `:filter_map(fn)` | self | Filter + transform in one pass (return nil to drop) |
| `:take(n)` | self | Keep first `n` elements |
| `:skip(n)` | self | Drop first `n` elements |
| `:flatten()` | self | Flatten one level of nesting |
| `:flat_map(fn)` | self | Map then flatten one level |
| `:sort(fn?)` | self | Sort in-place; `fn(a, b) -> bool` |
| `:reverse()` | self | Reverse element order |
| `:uniq(fn?)` | self | Remove consecutive duplicates; optional key extractor |
| `:concat(...)` | self | Append elements or tables |
| `:chunk(n)` | self | Split into groups of `n` |

## Terminal methods

| Method | Returns | What it does |
| --- | --- | --- |
| `:reduce(fn, initial?)` | any | Fold left |
| `:some(fn)` | bool | True if any element matches |
| `:every(fn)` | bool | True if all elements match |
| `:find(fn)` | value, index? | First match |
| `:first()` | any or nil | First element |
| `:last()` | any or nil | Last element |
| `:len()` | integer | Number of elements |
| `:count(fn?)` | integer | Count matches or total |
| `:nth(n)` | any or nil | Element at 1-based index |
| `:join(sep?)` | string | `table.concat` join |
| `:group_by(fn)` | table (terminal) | Hash `{ key = { elements } }` |
| `:entries()` | table (terminal) | Shallow copy of hash entries |
| `:map_entries(fn)` | table (terminal) | Map over key-value pairs; `fn(k, v) -> new_k, new_v` |
| `:pick(...)` | table (terminal) | Select specific keys from hash |
| `:omit(...)` | table (terminal) | Omit specific keys from hash |

## Examples

```lua
-- range
local r = hollow.tbl.range(1, 5):get()
-- { 1, 2, 3, 4, 5 }

-- chained transformation
local result = hollow.tbl({ 1, 2, 3, 4, 5 })
  :filter(function(v) return v > 2 end)
  :map(function(v) return v * 10 end)
  :get()
-- { 30, 40, 50 }

-- reduce
local sum = hollow.tbl({ 1, 2, 3 }):reduce(function(acc, v) return acc + v end)
-- 6

-- group_by
local by_type = hollow.tbl({ "a", "b", "aa" }):group_by(function(v) return #v end)
-- { [1] = { "a", "b" }, [2] = { "aa" } }

-- hash operations
local picked = hollow.tbl({ a = 1, b = 2, c = 3 }):pick("a", "c")
-- { a = 1, c = 3 }
```

## See also

- [Overview](overview.md) — general Lua API conventions
- [`types/hollow.lua`](../../../types/hollow.lua) — type definitions
