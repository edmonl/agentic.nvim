# Review context

## Branch

`fix/codex-acp-orphan-subprocess` vs `origin/HEAD`.

## Type

Bug fix + regression test + ADR.

## Summary

`codex-acp.js` is a Node wrapper that uses `spawnSync` with no signal
handlers. On `:q` / `VimLeavePre`, `transport:stop` sent SIGTERM/SIGKILL via
`process:kill(signum)` (direct PID only). The wrapper died, but the native
grandchild was reparented to PID 1 and kept running.

Fix: spawn ACP subprocesses with `detached = true` (becomes session +
process-group leader via `setsid`), then signal the whole group with
`uv.kill(-pid, ...)` on POSIX. Windows path keeps `process:kill`.

## Files changed (vs origin/HEAD)

- `lua/agentic/acp/acp_transport.lua` (M) - spawn detached, kill by pgid
- `lua/agentic/acp/acp_transport.test.lua` (A) - regression: wrapper does
  not forward signals; assert grandchild dies
- `docs/adr/0006-acp-subprocess-process-group.md` (A) - ADR

## Config changes

None.

## Common types

- `agentic.acp.ACPTransportInstance` defined inline in
  `lua/agentic/acp/acp_transport.lua` (class block inside
  `create_stdio_transport`). New `pid` field added.

## Renamed symbols

None.

## Import graph

`acp_transport.lua` consumers:

- `lua/agentic/acp/acp_client.lua` - imports `create_stdio_transport`
- `lua/agentic/acp/acp_transport.test.lua` - new test

No call-site changes required; `transport:start` / `transport:stop`
signatures unchanged.

## Working-tree noise (ignore for this review)

Uncommitted docs reorg (`docs/architectural-decisions/` -> `docs/adr/`,
`CONTEXT.md`, multiple new ADRs) is unrelated to this PR's scope. Only the
three committed files above are in scope.
