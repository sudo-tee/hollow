# Rex ideas that fit Hollow

Reference review: October 22, 2026. Compared Rex's public documentation with
Hollow's checked-in source and documentation, not runtime benchmarks.

## Conclusion

Borrow automation coherence, not a wholesale server-first architecture. Hollow
already has workspaces, tabs, tiled/floating panes, Lua configuration/actions,
plugins, internal events, HTP, CLI automation, screen/cursor snapshots, screenshots,
semantic UI nodes, revision waits, and OSC 7501 program status.

## Recommended priorities

1. **Self-describing commands/API.** Publish running-version method discovery,
   argument/result schemas, examples, and capabilities. Derive validation and
   discovery from shared command contracts, rather than another handwritten API.
2. **Typed actions across keys, palette, and CLI.** Extend existing action registry
   with argument validation, structured results, and invocation context. Do not
   replace Hollow's namespace or registration conventions.
3. **Consistent caller-relative targeting.** Keep explicit targets distinct from
   caller metadata and UI focus. Explicit targets win; document fallback behavior.
   Preserve deliberate tag broadcasting; reject ambiguous single-target matches.
4. **External events and completion waits.** Export scoped NDJSON events and waits
   for process exit, shell-command completion, and status changes. Subscribe before
   launching work; bound queues and report overflow. Revision changes do not mean
   command completion.
5. **Background execution workflows.** Combine no-focus creation, returned resource
   IDs, explicit argv versus shell input, completion waits, retained failure output,
   and cleanup limited to automation-owned resources.
6. **Config/keymap diagnostics.** Add headless checking, source provenance,
   conflict/unknown-action diagnostics, last-known-good reload, and public named
   key modes with exclusive/one-shot behavior.
7. **Version-matched agent guide.** Ship an installed-version CLI guide and opt-in,
   reversible agent setup instead of relying on stale copied instructions.
8. **Optional persistent remote sessions.** Treat as a separate design: durable
   ownership, reconnect, terminal-state retention, resize policy, cleanup, and
   authorization. Persistence does not require making shared PTY mux the default.

## Contract and context direction

The broad `Request` optional-field bag permits invalid command/argument
combinations and silently ignores malformed values. Prefer a tagged command union
with command-specific argument structs. Optional fields should represent real
optional behavior, not fields belonging to unrelated commands.

Use one invocation `ctx` for caller/origin metadata, separate from command
arguments and targets. Caller identity is not authorization and must not silently
change existing targeting semantics. A later Lua action-context migration should
be explicit rather than breaking callback signatures as a side effect.

## What not to copy

- Rex's session/window/block terminology: Hollow's model already works.
- A full server-first rewrite just to improve CLI discovery.
- Privileged multi-user login servers or embedded networking before demand exists.
- Rex's prohibition on config event handlers: Hollow's plugin model benefits from
  its existing event registration.

## Security and qualification

Hollow's documented loopback command socket does not authenticate local users.
Strengthen access controls before adding arbitrary Lua execution or broader
remote control. Loopback is not authorization. Neither this comparison nor the
presence of similar features establishes platform or performance parity.

## Sources

- https://www.superlogical.com/rex/docs/automate/server-api
- https://www.superlogical.com/rex/docs/customize/actions
- https://www.superlogical.com/rex/docs/automate/cli
- https://www.superlogical.com/rex/docs/automate/shell-scripting
- https://www.superlogical.com/rex/docs/automate/lua-events
- https://www.superlogical.com/rex/docs/customize/key-modes
- https://www.superlogical.com/rex/docs/customize/config
- https://www.superlogical.com/rex/docs/automate/agent-skill
- https://www.superlogical.com/rex/docs/linux/remote-access

Hollow reference points: `src/command.zig`, `src/native_cli.zig`,
`src/app/command_dispatcher.zig`, `src/lua/hollow/actions.lua`,
`src/lua/hollow/keymap.lua`, and `docs/reference/`.
