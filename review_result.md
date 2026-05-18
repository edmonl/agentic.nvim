# Code Review 2026-05-18 fix/codex-acp-orphan-subprocess

## lua/agentic/acp/acp_transport.lua

- SIGTERM immediately followed by SIGKILL with no delay. `uv.kill` is
  synchronous signal delivery, not wait. SIGTERM never has a chance to run
  cleanup handlers in the group before SIGKILL clobbers. If graceful is
  intended, defer SIGKILL via `vim.defer_fn`. If immediate termination is
  intended, drop the SIGTERM call entirely. acp_transport.lua:260-261,
  264-267

- `process:close()` called after `uv.kill(-pid, ...)` without going through
  `process:kill`. Valid (close just releases the handle, signal delivery is
  decoupled), but the exit callback at line 116 still fires asynchronously.
  After `process:close()` the handle is closed; the callback then
  dereferences `self.process` (line 153) which was already niled at line
  247. The `if self.process` guard saves it, but `process:close()` is
  called twice (once in stop, once would-be in callback - guard prevents
  that). OK, but note: `process:close()` in `stop` races the exit
  callback's own close. libuv tolerates close-after-exit; flag only for
  awareness.

- Re-entrancy: if `stop` runs while the spawn exit callback is in flight,
  `self.process` is niled in `stop` (line 247) before callback's
  `if self.process` check (line 153). Callback skips close. Stop's
  `process:close()` (line 271) runs on the local ref. Safe, but
  `reconnect_count` logic in the exit callback (line 159-169) still fires
  after a user-initiated `stop`, causing unwanted reconnect. Need a
  `stopped` flag to suppress reconnect on intentional stop.
  acp_transport.lua:159-169

- `pid` not cleared in exit callback (line 153-156). After natural process
  exit, `self.pid` remains set while `self.process = nil`. A subsequent
  `stop()` call short-circuits at line 244 (`self.process` is nil), so
  stale `pid` never used - currently safe. But if any future code reads
  `self.pid` independently of `self.process`, it gets a stale PID that may
  have been recycled by the OS. Clear `self.pid = nil` alongside
  `self.process = nil` at line 155. acp_transport.lua:153-156

- `tonumber(pid)` on line 180: `uv.spawn` returns pid as integer already.
  The `tonumber` is harmless but suggests uncertainty about the type. If
  pid is ever a string from some libuv version, `-pid` at line 260-261
  would error inside `pcall` and silently swallow - meaning the group kill
  silently fails and you fall through to nothing (no `process:kill`
  fallback on POSIX). Verify pid is integer; drop `tonumber` or assert.

- `vim.fn.has("win32") == 1` evaluated on every `stop` call. Cheap, but
  better cached at module level since OS doesn't change at runtime. Minor.

- Stop-before-start: `self.process` is nil, `if self.process` guard at line
  244 skips the kill block. `self.stdin`/`self.stdout` also nil, skipped.
  Then `callbacks.on_state_change("disconnected")` fires unconditionally -
  emitting `disconnected` when never connected. Pre-existing behavior, not
  introduced by this diff, but worth noting if reviewing transport
  lifecycle.

- Double-stop: second call hits `self.process` nil (cleared on first
  stop), skips kill block, emits `disconnected` again. Idempotent state
  change emission may confuse downstream state machine. Pre-existing.

## lua/agentic/acp/acp_transport.test.lua

- File under `lua/agentic/acp/` but `tests/AGENTS.md` says "ACP /
  transport-touching tests MUST stub `agentic.acp.acp_transport`". This
  test intentionally bypasses the stub; document the exception inline or
  move to `tests/integration/`. The comment mentions bypassing `child.lua`
  setup but doesn't justify violating the ACP stubbing rule.

- `vim.wait(2000, ...)` return value ignored. If grandchild PID never
  arrives, `assert.is_not_nil(grandchild_pid)` fails with no diagnostic;
  capture the bool and assert it for a clearer failure.
  acp_transport.test.lua:64-66

- `is_alive` PID reuse race is real. After SIGTERM the kernel can recycle
  the PID; `kill -0` against a recycled PID returns success and
  `wait_for_death` returns false, then the cleanup `kill -9` hits an
  unrelated process. Capture the start time and additionally check
  `/proc/<pid>/stat` starttime, or read the child's pgid once and verify
  `kill -0 -<pgid>` to scope to the original group. On macOS use
  `ps -o lstart= -p <pid>` snapshot before stop, compare after.

- 1500ms window: SIGTERM on a backgrounded `sleep 9999` via pgid is
  near-instant on a healthy box, but CI under load can stall. The wait
  loop polls every 25ms which is fine, but a flaky CI run will fall
  through to `kill -9` of a possibly-recycled PID (see above). Consider
  3000ms to reduce flake without hiding regressions.

- Cleanup ordering: `kill -9` runs only when `died == false`, but
  `child.stop()` in `after_each` happens after the assertion. If
  `assert.is_true(died)` fails, the `kill -9` already ran on a
  possibly-stale PID. Move best-effort cleanup into a guarded block that
  runs regardless of assertion outcome (e.g. wrap in pcall and use a
  flag).

- Missing assertion on `_G.t.state == "disconnected"` post-stop. The bug
  report is "stop should clean up the process tree"; verifying transport
  state transitions to disconnected pins down the full contract, not just
  descendant death. acp_transport.test.lua:80

- Test name "kills descendant processes when wrapper does not forward
  signals" describes the scenario but not the contract under test. Prefer
  "ACPTransport.stop signals process group so non-forwarding wrappers do
  not orphan children" or similar.

- `exec cat >/dev/null` makes the shell's PID become cat's PID via exec -
  correct, so the transport's tracked PID is the foreground process. The
  shell `&` backgrounds `sleep` in the same session before `exec`, so
  `sleep` is in the new session's process group (because `setsid` was
  already applied by `detached = true` at spawn time, and `sh -c` does not
  create a new pgrp without job control). SIGTERM to `-pid` reaches
  `sleep`. Verify this remains true if libuv's `detached` semantics
  change; pin with a comment referencing ADR 0006.

- `child.lua("vim.opt.rtp:prepend(...)", { vim.fn.getcwd() })`:
  `vim.opt.rtp:prepend` does not consume varargs. Passing arguments to
  `child.lua` is a no-op for this expression - `getcwd()` here is the test
  runner's cwd, not the child's, and is never substituted into the
  string. Either interpolate with string concat or use `child.lua_func`.
  As written this might still work because the parent's cwd matches the
  project root in `make test`, but it's silently broken.
  acp_transport.test.lua:13

- `before_each` calls `child.restart` with `-i NONE -u NONE` but does not
  load the plugin via the standard `tests.helpers.child` setup. That's
  intentional per the comment, but no rtp validation - if the runtime
  path injection fails, `require("agentic.acp.acp_transport")` will error
  inside `child.lua` with a stack trace that's hard to attribute. Assert
  `package.loaded` or pcall the require with a clear message.

- TDD red/green: test added in same commit series as fix. Cannot prove it
  was red against pre-fix code from diff alone. Recommend the author
  confirm in PR description per `tests/AGENTS.md` step 1.

## docs/adr/0006-acp-subprocess-process-group.md

- `Commits:` empty. Acceptable pre-merge but flag for backfill after
  squash-merge per `docs/adr/README.md` anti-staleness rule. Line 5.

- `Related:` empty. Template requires refs in `<kind> #N` form; add the
  PR number once opened (or omit the line if truly none, matching ADR
  0004/0005 which leave it blank). Line 6.

- Changelog row missing `Commit` SHA. Same backfill-after-merge concern.
  Line 57.

- "ACP children survive a hard kill of nvim ... because they are no
  longer in nvim's process group." Partially imprecise: surviving
  SIGKILL/OOM/segfault of nvim is not just about process-group
  membership; it is about the absence of `PR_SET_PDEATHSIG` / job-object
  teardown. Being in a separate pgrp is necessary (no SIGHUP from
  controlling-tty teardown) but not sufficient as causation. Phrasing
  reads as if pgrp separation alone is what makes them survive. Consider:
  "Children no longer receive SIGHUP from nvim's controlling tty on
  crash; nothing reaps them on hard kill." Lines 37-40.

- Rejected alternatives table column widths produce a very long
  second-row cell (>200 chars on one line). Markdown still renders, but
  breaks the visual line-wrap norm used in ADRs 0001/0003 (multi-line
  cells). Minor; project AGENTS.md does not mandate wrap inside table
  cells. Skip if intentional.
