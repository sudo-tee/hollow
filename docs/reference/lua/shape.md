# `hollow.shape`

Composable runtime schemas, adapted from `opencode.nvim`'s `opencode.shape`.
Available as `hollow.shape` or `require("hollow.shape")`; no Neovim dependency.

```lua
local z = hollow.shape
local schema = z.strict_object({
  name = z.string(),
  tags = z.string():array():optional(),
  count = z.integer():min(1):default(1),
})

local result = schema:safe_parse({ name = "build" })
-- { success = true, data = { name = "build", count = 1 } }

local invalid = schema:safe_parse({ name = 42 })
-- { success = false, error = "$.name: expected string, got number" }
```

## Schemas

| Constructor | Accepts |
| --- | --- |
| `string()`, `number()`, `boolean()` | Matching Lua types |
| `integer()` | Numbers with no fractional part; rejects NaN and infinity |
| `table()`, `thread()`, `userdata()`, `["function"]()` | Matching Lua types |
| `any()` / `unknown()` | Any value, including nil |
| `object(fields, opts?)` | Table with matching fields; preserves unknown fields |
| `strict_object(fields)` | Object rejecting unknown fields |
| `array(rule?)` | Dense 1-indexed array; defaults to any item type |
| `enum(values)` / `one_of(values)` | One of the listed values |
| `literal(value)` | Exactly that value |
| `union(rule, ...)` / `union({ rules... })` | First matching rule |
| `optional(rule)` / `nullable(rule)` | Nil or a matching value |
| `custom(predicate, description?)` | Value accepted by predicate |

`number()` matches Lua numbers, including NaN and infinity, as in the original
implementation. Add a constraint when finite values are required:

```lua
local finite = z.number():constraint(function(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end, "finite number")
```

Rules can also be type strings (`"string"`), predicates, object specification
tables, or nonempty arrays of literal enum values. An empty table rule means an
object, not an empty enum. `object(fields, { strict = true })` is equivalent to
`strict_object(fields)`.

## Parsing and composition

- `schema:parse(value, message?)` returns parsed value or raises an error.
- `schema:safe_parse(value)` returns `{ success = true, data = ... }` or
  `{ success = false, error = "..." }`.
- `schema:check(value)` / `schema:is(value)` returns a boolean.
- `schema:optional()` / `:nullable()` allows nil.
- `schema:array()` builds an array of that schema.
- `schema:constraint(predicate, description?)` validates parsed values.
- `schema:min(n)` / `:max(n)` applies inclusive numeric bounds.
- `schema:transform(fn)` maps parsed values; exceptions become validation errors.
- `schema:convert(fn)` is a transform that also rejects a nil result.
- `schema:or_(rule)` builds a union.
- `schema:default(value)` substitutes only for nil, not false or zero. Defaults
  are validated at construction and parsed on use. Table defaults are copied at
  construction and for each use. This method is a Hollow extension.

Module-level `constraint(rule, fn, description?)`, `transform(rule, fn)`, and
`convert(rule, fn)` accept shorthand rules too. `validate(value, rule, message?)`
(`parse` alias), `safe_parse(value, rule, message?)`, and `check(value, rule)`
(`is` alias) parse arbitrary rules. Calling `z(value, rule, message?)` is shorthand
for `validate`. `expect(condition, message)` (`assert` alias) raises when false.
`is_schema(value)` checks schema identity, not whether a table has a `parse` field.

Unchanged values retain their identity; parsing copies only changed object/array
containers. User-provided transforms can mutate their input. The
[action registry](../actions.md#typed-arguments-and-invocation-results) separately
copies invocation arguments before parsing to isolate caller-owned data.
Schemas capture their rules in closures; treat schemas and specification tables
as immutable once in use. They are runtime Lua values, not JSON schemas.
