# Managed launch acceptance

## Current checkpoint — September 11, 2026

The managed session is not enabled in production. Current source has carrier,
placement, driver, credentials, approvals and gateway components, but the shipped
managed policy has no executable or environment bindings, no production launch
definition is installed, and the default composition does not start the gateway
listener. Public Claude/Codex aliases still launch ordinary native Terminals.

On runtime `674b58a1a117fa79398f723c4311201cca8472e1`, the current
managed-launch gate completed with **192 passed and 7 failed**. All mandatory
real-executable proof names passed, including loopback authentication, permission
exchange and gateway interoperability; the seven gateway-carrier integration
failures prevent acceptance. Three report a listener readiness generation
conflict, and later cases fail before the child presents its credential. The
cause was concurrent test compositions sharing loopback port `18790`: a request
could reach another runtime's listener, which correctly refused the generation.
A fresh run on unchanged source `4900c6d` passed **199/199** in 213.4 seconds.
Fixture endpoint isolation and concurrent acceptance are being implemented;
production generation checks are unchanged. The full integrated gate including
the workspace handoff correction below remains pending.

Reproduction (real provider credentials removed; fixtures use isolated homes,
sentinel credentials and loopback endpoints):

```sh
env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY make managed-launch-check \
  BEE_RUNTIME=/path/to/pinned/wippy \
  BEE_CLAUDE_BIN=/absolute/path/to/claude \
  BEE_CODEX_BIN=/absolute/path/to/codex
```

Evidence: `/tmp/bee-current-managed-launch-check.log`, source checkpoint
`b3e0f71`. This is a failed integration gate, not production enablement.

Launch admission now retains the selected workspace ID in its carrier request.
This is the same workspace used to obtain resource grants and credential
projections; permission exchange needs it when creating approvals. The actual
launch-admission suite passes 4/4, including grant/projection ownership and
start recovery. With the old handoff restored, the workspace assertion fails
while the other three cases pass. Evidence:
`/tmp/bee-launch-workspace-baseline.log` and
`/tmp/bee-launch-workspace-fixed.log`. This correction is source-only and does
not activate a provider or change workspace authorization.

A durable follow-up prompt is also unfinished. Both driver `dispatch` methods
explicitly describe a new process on a provider `resume_ref`; the carrier currently
calls only `prepare` and settles one attempt. Placement already has retained
session directories. A conversation can span process attempts: it must preserve
thread identity, provider continuation and the selected session directory, with
idempotent admission and recovery. Increasing Claude's `max_turns` does not provide
that user-facing conversation lifecycle. The launch surface, follow-up composition
and detach/recovery acceptance remain required.

## Historical September 9 evidence

The runtime limitations and PR table below describe the old September 9 pin.
They are historical evidence, not unresolved requirements of the current pin.


The state of managed harness launches (Claude Code and Codex through the
carrier, the native placement runner, the credential broker and the
approvals owner) as of 2026-09-09, what the pinned runtime can run, what a
combined runtime build proves, and the exact commands. Production
enablement of the interactive permission exchange waits for the runtime
pin; nothing here enables it.

## Runtime commits and patch order

The combined build is `origin/main` at `fdad09cef2` plus these branches,
merged in this order (worktrees under `~/kickside`):

| Order | Branch | Commits | PR | What it adds |
|---|---|---|---|---|
| 1 | `feat/exec-combined-stdin` (`runtime-exec-combined2`, head `9d85cbaf6e`) | `95d1400414` process groups, `42eef72ec9` done(), `6e2efa5a4b` combined acceptance, `ce9d9a3b62` close_stdin, merges `23d9cf4a78` `a87a1baeda` `e3bac4f65c` `9d85cbaf6e` | 694, 695, 696, 698 | `process_group` and `pid`, exit on a channel without consuming the handle, `close_stdin` |
| 2 | `feat/hash-streaming` (`runtime-hash-stream`, head `dc0390d9fc`) | `dc0390d9fc` | 699 | `hash.new` streaming hasher (`update`, `sum`, `reset`) |
| 3 | `feat/fs-readonly` (`runtime-fs-readonly`, head `5bd7e8345f`) | `5bd7e8345f` | 700 | `readonly` on `fs.directory`, every mutation refused at the boundary |

Builds: `runtime-combined3` (`feat/exec-combined-hash`, `a83f68fc2e`) is
1 + 2; `runtime-combined4` (`feat/exec-combined-readonly`, `6655516751`)
is 1 + 2 + 3. Each is `make build-wippy-local` in its worktree with the
binary copied to `bin/wippy`. PR 691 (lint parse errors) and the go-lua
PRs 42 and 43 concern the checker, not these builds. None of the PRs is
pinned; the pin and its acceptance are the runtime lane's.

## Production requirements and fixture exceptions

A launch policy with `fixture: true` is a test policy. What production
(a policy without it) requires, and how the current pin answers:

| Requirement | Production | Fixture exception | On the pinned runtime |
|---|---|---|---|
| Profile pins the adapter (`permission_exchange` with the exact digest) | required | bypassed | Claude profiles pin `bee.driver.claude:permission_adapter`; eligible, not enabled |
| Acceptance record (`bee.permission-acceptance@2`) matches binding, profile, adapter, fixture and executable measurements | required | required | matches where the measurement can be taken |
| Executable bound to an absolute path and measured (`bee.executable-measurement@1`) | required; plan refuses without | proceeds unmeasured when the runtime cannot measure | files above 8 MiB refused (no streaming hasher): "production exchange: executable measurement: UNAVAILABLE" |
| Measurement kind `elf` | required; scripts and launchers refused | fixture script allowed | refused for a script |
| Runtime measures a stream (`executable_measurement.streaming`) | required | not required | false; refused "cannot measure an executable as a stream" |
| Measurement volume proven read-only (`executable_measurement.read_only_volume`: a creating open through the host volume inside the placement root refused with the runtime's own read-only error; any other failure reports unknown) | required | not required | false; refused "not proven read-only" |
| Process groups and independent exit observation | required; the policy codec admits `eof_gated` only in a fixture policy, and placement refuses a launch whose requirement the runtime cannot meet | fixture policies ask for `direct_process` / `eof_gated` | offers `direct_process`, `eof_gated`; a production launch is refused at prepare |
| `close_stdin` for `stdin_eof` launches (Codex) and `session_end: stdin_close` (Claude exchange) | required | Claude exchange falls back to the cooperative stop | refused for `stdin_eof`; fallback stop for the Claude exchange |
| Shipped launch policies enable an exchange | none | n/a | none |

The carrier refuses at plan time with a reason prefixed `production
exchange:`; `tests/lua/harness/permission_carrier_test.lua` proves that
refusal on the host it runs on. The check-to-exec window remains: the
runner measures the executable immediately before a path-based exec, so
acceptance establishes that the file was measured then, not that those
exact bytes executed; dynamic libraries and interpreters are outside the
measurement.

## Commands

Both executables are required; a missing or wrong one fails the target
rather than reducing coverage.

```
make test                                   # pinned runtime, 344 tests; proofs report the gate open without the executables
BEE_CLAUDE_BIN=$HOME/.local/bin/claude BEE_CODEX_BIN=/usr/bin/codex make test
make managed-launch-check BEE_RUNTIME=$HOME/kickside/runtime-combined4/bin/wippy \
  BEE_CLAUDE_BIN=$HOME/.local/bin/claude BEE_CODEX_BIN=/usr/bin/codex
```

`managed-launch-check` runs `tests/managed_launch.py`: the placement,
harness, driver, credentials and thread suites against the named runtime,
and fails unless every real-executable proof passed (Codex and Claude
authentication paths, Claude acceptance and the carrier control matrix).
The suites open a loopback endpoint fixture, an isolated home and a
sentinel key; no provider is contacted.

## Full gate coverage

`make check` is installer-check, lint, test, threads, threads-module,
pack, headless-check and workspace-hosts-check. On 2026-09-09 the
composite run was stopped by the session's memory guard twice; each
constituent was then run alone on the same tree:

| Constituent | Result |
|---|---|
| installer-check | exit 0 |
| lint | exit 0 (pinned checker, 255 source entries) |
| test | exit 0, 344 tests, both executables bound |
| threads | exit 0 |
| threads-module | exit 0 |
| pack | exit 0 |
| headless-check | exit 0 |
| workspace-hosts-check | exit 0 |

Run alongside, outside `make check`: `tests/architecture.py` (source and
pack, 443 entries), `tests/thread_storage.py`, and `managed-launch-check`
on `runtime-combined3` and `runtime-combined4` (154 tests each). Not run:
the hive checks (`hive-*-check`), `desktop-check`, `repository-check`,
`client-desktop-check`, `local-launcher-check`, `layout-ack-check` and
`attachments-check`, which belong to other lanes and are not implied by the
list above.
