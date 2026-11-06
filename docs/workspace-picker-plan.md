# Domain-grouped workspace picker

## Goal

Keep open workspaces above domain-grouped sessions and projects in one globally searchable picker.
SSH session listing and configured project discovery must be explicit, with stable empty/error states and no indefinite loading.
Share reusable collapsible categories with the command palette, with a trailing creation button and domain-scoped create key.

## Implementation

- Shared select grouping inserts section rows after global filtering and ranks matches within each group.
- The workspace picker assigns **OPENED** first and domain keys afterward, retaining domain pills only on open rows.
- Fixed row-column budgets reserve badge/pill space before truncating names and paths.
- Session loads track request generations and a 15-second default picker deadline.
- SSH descriptors are deferred before discovery-host preparation can connect them.
- A separate SSH project scanner borrows descriptor hosts only on explicit load, pages 256 entries at a time, and runs at most four stats concurrently.
- Project discovery bounds each load to 4096 entries and tracks at most 64 domain states.
- Timeout or source reconfiguration cancels owned work, releases borrowed connections, and fences late results.
- Category creation captures the selected domain; it never changes that domain's persistence policy.
- Category activation toggles collapse without network work; search reveals matches without changing saved collapse choices.
- Domain category colors reuse pill colors, and compact rows put work indicators beside current/attention markers in the leading column.

## Validation

Lua regressions cover grouped search/navigation, independent header-button activation, domain-scoped creation, lazy SSH sources, empty states, timeouts, retry generations, source reconfiguration, and bounded stats.
The workspace snapshot changes intentionally to include section rows and fixed column widths.
Run the complete Lua suite, bundled LuaJIT syntax checks, and Windows GUI cross-build.
Collapse/layout refinement validation passes: 977 Lua tests, bundled LuaJIT syntax checks, and the ReleaseFast Windows GUI cross-build.
Manual GUI verification should cover narrow windows, long domain names, header creation, unreachable SSH, and empty SSH results.
