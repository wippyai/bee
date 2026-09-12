# Carrier contract

Status: agreed 2026-09-09 between Claude and Astra (Codex CLI design thread
`01a077f7-3266-7280-8dd5-a6c7b1cf35ea`, rounds 12 and 13). It fixes how a
carrier turns a placement's byte streams into thread records without
losing, duplicating or inventing anything across a crash, and what the
threads contract has to offer for that. Read [thread records](THREAD_RECORDS.md),
[thread authority](THREAD_AUTHORITY.md) and the
[placement module](../src/placement/README.md) first.

## Terms

| Term | Meaning |
|---|---|
| Carrier | One Wippy process per attempt that owns the driver protocol and the logical turn state. It holds no executor and no SQL of its own. |
| Provenance | Where a normalized event came from: stream, chunk range, envelope position, event index. Supplied by the carrier, never by the driver. |
| Checkpoint | The durable carrier state after which the runner's output may be acknowledged: consumed stream positions, framing carry bytes, normalizer state, measurements. Thread-owned. |
| Carrier epoch | The fence a replacement carrier acquires on an attempt. Thread commits and placement attachment carry it; the previous carrier is rejected after takeover. |
| Control record | An owner-written record of carrier intent or outcome: an input write, a placement status. Never a driver observation. |

## 1. Provenance is not a cursor

A chunk can carry several events and an event can span chunks. Every
normalized observation the carrier commits carries a versioned provenance
structure `bee.carrier.provenance@1`:

| Field | Purpose |
|---|---|
| `stream_id` | `stdout` for protocol data; other streams are named, never mixed |
| `source_first_sequence`, `source_last_sequence` | Runner chunk range that contributed to the event |
| `envelope_index` | Position of the framed envelope in the stream, from the transport decoder |
| `event_index` | Ordinal of the normalized event within that envelope |

The carrier passes that value beside each `stream` record in `commit`; the
authority derives the observation's `event_key` from attempt, stream,
envelope index and event index and persists the mapping in
`bee_thread_carrier_events` atomically with the record and the checkpoint,
so a replayed chunk can never become a second record and the same
provenance with different content is a `CONFLICT`. `raw_ref` stays null:
it names retained evidence, and a position is not evidence. Control records
carry no provenance.

## 2. Checkpoint plus retained unacknowledged output

The runner keeps output until the carrier acknowledges it. The carrier
acknowledges only after one thread transaction has committed every record
derived from that output together with the checkpoint `bee.carrier.checkpoint@1`:

| Field | Purpose |
|---|---|
| `schema_revision` | `bee.carrier.checkpoint@1` |
| `consumed` | `{stdout: integer, stderr: integer}` fully consumed chunk sequences |
| `carry` | Framing carry bytes for a partial frame, per stream |
| `envelope_index` | Next envelope index the decoder will assign |
| `normalizer_state` | The driver's opaque state, including accumulated answer state |
| `binding_ref`, `binding_digest`, `profile_id`, `profile_digest` | The pinned measurements |
| `attachment_generation` | The placement attachment this carrier holds |

A crash between two events of one chunk replays the chunk; the first
event is deduplicated by its key, the second is committed. A crash after a
partial frame is checkpointed resumes from the carry bytes. A crash after
the commit and before the acknowledgment replays already-committed output,
which the keys absorb.

Capacity: the checkpoint is bounded at 64 KiB, so the carrier frames with
a 16 KiB bound per stream and never acknowledges a frame it could not
checkpoint; a longer frame ends the attempt `uncertain` with a `framing`
notice, and `bee.harness.carrier:capabilities` reports the bound. Chunk
size and frame size are independent: a frame split across chunks resumes
from the carry, and a chunk with many envelopes commits in batches. An
envelope that yields more than one commit's worth of records is committed
in consumed-prefix order with `event_cursor {envelope_index,
events_committed}`, and a resuming carrier re-derives the remainder from
the carry and skips what the cursor names.

## 3. Lifecycle order

1. `admit_action` with the pinned execution plan and a preallocated
   `attempt_id` in the admitted body's grant and budget references.
2. `prepare_attempt`: commits `attempt.prepared` with the pinned binding
   and profile measurements, the placement binding and the placement
   `attempt_id`. The attempt exists in state `prepared`; one live
   (`prepared` or `running`) attempt per action.
3. Placement `prepare` records intent.
4. `request_turn` commits `turn.request` on the prepared attempt before
   the initial prompt is delivered, including when the prompt is a launch
   argument.
5. Placement `start`.
6. `start_attempt` commits `attempt.started` from the placement's recorded
   execution identity; the attempt becomes `running`.
7. Buffered output drains into thread records through checkpointed commits.

`start_attempt` on an attempt that is not `prepared` is `INVALID_STATE`.
A placement start followed by a failed thread commit reconciles the same
attempt; it never launches another child.

## 4. Input writes

Before any stdin dispatch the carrier commits a control record
`bee.carrier.write@1` with `write_id`, `attempt_id`, `turn_id`,
`input_digest`, `attachment_generation`, `phase: intended`, holding the
write in the checkpoint's `pending_writes`. After the runner acknowledges,
`phase: accepted` is committed and the write leaves the checkpoint.
`accepted` means the runner wrote the bytes, not that the harness processed
them. A carrier replaced between the two asks the surviving runner for the
write's status: `accepted` is recorded as such; `unknown` means the bytes
never reached the child, and the write is dispatched for the first time;
no runner to ask makes it `uncertain`, and nothing rewrites it.

## 5. Settlement and receipts

Turns settle from the driver's terminal envelope. Process exit is observed
first, then a bounded drain of remaining output, and only then is a missing
terminal envelope decided: the turn ends `uncertain`. A terminal envelope
with a failed process keeps the observed answer and settles per the
profile's rules before any action success is reported.

Placement status is recorded as owner-written observations
`bee.placement.attempt@1` (execution state, cleanup state, exit source,
evidence count) as it changes. The attempt receipt is committed once, when
execution is settled, after the turn end; later cleanup outcomes are
further placement observations, never receipts, and may follow the
receipt. A pending input write holds settlement until the runner answers
or the drain ends, at which point the write is `uncertain`.

## 6. Ownership and pinning

`claim` returns a new carrier epoch for the attempt. `commit` carries the
epoch and is rejected with `CONFLICT` when a newer epoch exists; so are
`request_turn`, `end_turn` and `receipt` when they name a `carrier_epoch`,
which a carrier always does. Placement `attach` takes the epoch as the
recipient generation and refuses a generation at or below the current one.

Takeover has two stages. The replacement's `claim` commit fences thread
authority: from that record on, the old carrier can neither commit output,
nor open or end a turn, nor commit a receipt, nor begin a new write (a
write begins with the commit of its `intended` control record). The
replacement's placement `attach` fences the execution channel: the
placement service sends the new generation to the runner and returns only
after the runner acknowledges that it installed it (or records the attempt
`uncertain` when the runner does not answer), and from then on the runner
refuses input and acknowledgments from any other sender or generation and
answers a refused write with the sender's own generation so the fenced
carrier can record it. A write the old carrier admitted before the claim
and dispatches after the attach is refused by the runner, and the old
carrier's attempt to record that refusal fails on the stale epoch. The
replacement asks the surviving runner for every pending write only after
its attach returned, so an `unknown` answer is proof that the bytes never
reached the child and a first dispatch is safe. Between the claim and the
attach, the runner still routes output to the old carrier, which cannot
commit or acknowledge it; the runner resends it to the new recipient on
attach. Only a carrier that learned the runner's address from the
placement's own reply acknowledges output, and only sequences its durable
checkpoint already covers are re-acknowledged. Catalog digests are
entry-scoped; an adapter change during an active attempt is rejected at
the next resolve rather than claimed pinned.

## 6a. Launch policy

Required cleanup and exit observation come from a host-selected protected
launch-policy entry, never from the caller or the driver. The execution
owner selects the policy and pins its digest into the prepared plan;
placement enforces the requirements independently; a profile may request
stronger requirements and the effective ones satisfy both; a policy change
never changes an attempt already prepared. Test policies may permit
`eof_gated` only in isolated fixture compositions.

## 7. Threads contract additions

Contract `bee.threads:carrier`, local binding `carrier_local`, action
`bee.threads.carrier`:

| Operation | Input | Effect |
|---|---|---|
| `claim` | `thread_id`, `idempotency_key`, `attempt_id` | New carrier epoch on a live attempt; replay by key |
| `commit` | `thread_id`, `idempotency_key`, `attempt_id`, `carrier_epoch`, `expected_revision`, `checkpoint`, `records[]` | Appends every record (`stream` observation with a typed provenance, or a control observation with source `bee` limited to `bee.carrier.write@1` and `bee.placement.attempt@1`) and stores the checkpoint at `expected_revision + 1` in one transaction; `CONFLICT` on a stale epoch or revision |
| `checkpoint` | `thread_id`, `attempt_id` | The stored checkpoint, revision and epoch; member read |

Lifecycle gains `prepare_attempt` (`action_id`, `attempt_id`, `Prepared`)
and `start_attempt` now moves a `prepared` attempt to `running`.
Migration 6 `carrier` rebuilds the records and attempts tables for the new
kind and state and adds `bee_thread_carriers`.

## 8. Fixture boundary and crash points

Integration runs the shipped Claude binding against a fixture executable
bound explicitly for the test runtime that replays the captured
`stream-json-2` streams: a Claude protocol fixture, not acceptance of the
installed executable. The production carrier process carries no fault
hooks: crash points are driven through a test-only carrier entry that
wraps the same carrier library with injected barrier callbacks, and that
entry is excluded from packs. Crash points the suite drives:

- between two normalized events from one chunk;
- after a partial frame is checkpointed;
- after the thread commit and before the output acknowledgment;
- after placement start and before `attempt.started`;
- after an input write and before its acknowledgment;
- after the terminal envelope and before turn settlement;
- an old carrier writing after replacement, both a new write and a write
  admitted before the claim and dispatched after the attach.

## 9. Permission exchange

The exchange is proven against the fixture harness for its crash
boundaries and against the real Claude executable for its protocol.
`bee.driver.claude:permission_adapter` describes Claude Code's stream-json
control protocol as captured on 2026-09-09
(`tests/fixtures/drivers/claude/stream-json-2/control.jsonl`): the request
is the `control_request` line (`request_id` correlates the response,
`request.tool_use_id` is what the harness echoes back, `request.tool_name`,
`request.input`, `request.description`); the response is one
`control_response` line with `response.subtype = success`,
`response.request_id` and `response.response.behavior` (`allow` or `deny`
with `message`); an allow is acknowledged by the `tool.result` observation
whose `call_id` is the tool use id, a deny by the correlated failed
`tool.result`; a closed stdin denies a pending request, so the cancellation
is `deny_before_close`. Both Claude profiles pin that adapter's digest, so
they are eligible; shipped launch policies still enable no exchange. When
the host enables one, the driver prepares the exchange launch: the brief is
the first stream-json user line on stdin (canonically encoded, part of the
plan digest), stdin stays open, permission prompts route to the stdio
prompt tool, and the launch declares `session_end: stdin_close` because
the harness idles after its result until stdin closes. The session then
ends in this order: terminal envelope, pending-write resolution, the
closure intent committed to the checkpoint (`input_closed`, so a recovered
carrier never writes to that session again) with a `bee.carrier.input`
record `close_intended`, placement closes stdin through `close_stdin` and
its runner records `stdin.closed` (or `stdin.uncertain` where the runtime
cannot close it) apart from input acceptance and exit, the carrier
records `closed` or `close_uncertain`, the exit is awaited within the
policy grace, then the cooperative stop and the runner's kill after its
grace remain the fallback, all before the settlement records end the
attempt. A launch that declares no session end is stopped cooperatively
after settlement when it still runs. Closing stdin while a prompt is
pending is a denial, never a completion, so the carrier closes only after
every exchange is closed on record. The post-close wait and the fallback
stop's grace are separate intervals: the carrier waits
`stop_grace_ms + runner_drain_ms + drain_ms` after the close, then again
after the cooperative stop while the runner escalates to a kill after its
own `stop_grace_ms`, so the bound on the whole end is twice that sum.

**Executable measurement.** A path is not an identity. Placement offers
`measure_executable`, a read-only content measurement
(`bee.executable-measurement@1`: sha256 of the file the path opens, its
kind as `elf`, `script` with the interpreter line, or `other`, and its
size) through the host filesystem volume, streaming through the runtime's
hasher where the build carries it and from one bounded string otherwise.
The carrier measures the host-bound absolute executable at plan time, the
measurement is part of the plan digest and of the placement request, and
the runner measures again immediately before exec, refusing a change with
`executable.changed` on record and recording `executable.measured`
otherwise. A script's digest covers the script file only, never its
interpreter, and a launcher is measured as the file it is, not as what it
starts. The runtime executes by path, so a replacement between the
runner's measurement and the exec is not excluded; the window is that one
call. An enabled permission exchange stands on an acceptance record
(`bee.permission-acceptance@2`) that carries the measurement revision,
kind and digest, so it needs a bound absolute executable the runtime can
measure, and the plan refuses when any of the three differs from the
record (a new attempt never opens with such a refusal; a recovered attempt
keeps its plan, closes its exchange on record with that reason and
settles without dispatching; the refusal permits recovery and its
recording only, never fresh admission, a replaced plan or a dispatch under
the rejected measurements); a production exchange covers a measured
native image (`elf`) only, since a script's digest pins neither its interpreter nor what it
starts; a fixture policy proceeds without a measurement where the
runtime cannot take one. Production therefore needs a runtime that
measures a stream (runtime PR 699) beside process groups, independent
exit observation and stdin closure, and the measurement volume should be
read-only by construction (runtime PR 700, `readonly` on fs.directory);
until the pinned build carries them, shipped policies enable no exchange.
`tests/lua/harness/claude_acceptance_test.lua` proves with the executable
that a typed request appears and the harness waits, a correlated allow
executes the action once, a deny prevents it and is acknowledged, and a
wrong correlation or silence authorizes nothing and leaves the harness
waiting; `tests/lua/harness/claude_control_test.lua` proves allow, deny
and approval expiry through the carrier, placement and the approvals owner
with the action landing in the project only on allow. Both run when
`BEE_CLAUDE_BIN` names the executable and report the gate open otherwise.

When the host launch policy names a permission adapter, its acceptance
record, the proven fixture digest and an approver policy, the carrier runs
the exchange specified in [approvals](APPROVALS.md). A permission request
among a chunk's observations becomes an intent in the checkpoint
(`permissions`, at most four) and a `bee.carrier.permission` control record
in the same commit, with every key derived once from owner, attempt and the
request's event key. The approval is asked under that idempotency key; the
decision is polled from the owner; an approved decision is consumed under
the authority incarnation the carrier observed, revalidating when the
owner answers `REVALIDATE`; the response goes out under the one write id
through the write path above. Phases recorded: `intended`, `requested`,
`decided`, `revalidated`, `consumed` (an approved effect consumed at the
owner), `declined` (a denial or expiry answered; no effect consumed, no
authorization to act), `acknowledged`, `closed`, `refused`.
Settlement closes every open exchange on record; a written response the
harness never acknowledged is closed as accepted by the input transport
with harness acknowledgment unproven. Crash points the suite drives:
after the intent commit, after the owner created the approval and before
the checkpoint recorded it, after the requested commit, after consumption
and before the write intent, after the write intent and after dispatch,
an authority restart between revalidation and consumption, runner loss
during write recovery, and a decision after the attempt ended. An attach
reaches a runner that outlives its exited child while it holds
unacknowledged output; once the runner is gone the pending write is
uncertain and nothing is resent. When exit is observed independently while
descendants still hold the pipes, the runner drains for the placement's
`timeouts.drain_ms` (launch policy `runner_drain_ms`; the carrier's own
post-exit wait is `runner_drain_ms` plus `drain_ms`, which is timing, not
ordering: when the carrier's deadline wins it settles with output
`incomplete`, and elapsed time never implies completeness), then closes the streams and records
`output.drain_elapsed`; closing on the deadline is forced truncation, not
observed end of output, so the runner marks those EOF chunks `truncated`
and its status reports it. The carrier keeps the output state in its checkpoint (`complete` only
when both streams ended on their own, `truncated`, `open` while streams
are open; settlement turns `open` into `incomplete`, and a recovery whose
runner is gone turns only `open` into `unobserved`, never a checkpointed
`complete` or `truncated`), records each truncated stream and the final state as
`bee.carrier.output` control records (the state before the turn ends) and, when no terminal envelope exists, in the settlement reason. A durable terminal
envelope still establishes the protocol outcome; output completeness and
cleanup remain separate facts. A runner retains unacknowledged output after
the child exited and both streams ended only for the placement's
`timeouts.retain_ms`; past it the runner records `output.lost` with the
unacknowledged chunk and byte counts and finishes, so a lost tail is never
mistaken for consumption. Placement reconcile asks a live runner for a
typed status carrying the attempt identity and a fresh probe, accepts the
reply only from the recorded runner for that attempt, attachment
generation and probe, and records `reconcile.supervised` with what the
runner observes; that proves supervision, never exit or cleanup. Lost output and a
process exit never establish success: settlement needs the durable
terminal envelope, and without it the attempt is uncertain. Every dispatch after recovery and every
revalidation under a new authority incarnation re-checks the pinned
measurements, the proposal digest and the placement's grants first. Both shipped profiles keep the exchange
off; only the fixture policy enables it.

Wakeup hints: with the exchange enabled the carrier holds a durable
subscription to the thread's `approval.transition` records (kept in the
checkpoint as `hint_subscription`, resumed under the replacement's lease
so an old carrier's pages are fenced) and registers a private topic with
the thread waiter. The consumer identity is one per attempt and a subscription that cannot
be resumed is closed before another opens, so superseded rows never
accumulate. A wake or the poll tick pages the subscription; any
transition is only a reason to read the approval owner, the projected
decision authorizes neither consumption nor a write, hints coalesce into
one refresh, and the page is acknowledged after its hints were processed,
which certifies neither consumption nor child-input acceptance. Bounded
polling stays the fallback through a missing projection, exhausted
delivery, subscription loss (the next tick reopens it) and reconnect; the
subscription is closed at settlement.

## Claimed hook records

`bee.harness.carrier:hook_records.batch` decodes up to 16 claimed hooks into
canonical thread observations and their acknowledgment IDs. It rejects malformed
or sparse batches and duplicate IDs before commit, preserves the gateway's
accepted field values and stable event keys, and omits `turn_id` when no turn
exists. An empty decoded batch is idle; a malformed reply is a delivery error.
Both the structured carrier and native window use this helper. The native
window supplies no turn ID; hook observations cannot establish a logical result.
See [window delivery](handoffs/NATIVE_WINDOW.md#window-checkpoint-and-hook-delivery)
for the checkpoint, asynchronous delivery and shutdown contract.

## 10. Generated configuration and stdin end of file

Every driver binding supplies `configure`. The carrier measures the activated
method, copied provider record, gateway endpoint, admitted tools/hooks and
credential environment names. Placement independently reconstructs those inputs
from host policy and checks their digest before admitting an attempt. Requests
cannot supply rendered files, arguments or a private `delivery` value.

For a new intent, placement derives its actual private HOME without creating it,
then calls the activated driver under an empty callee scope. The reply supplies
bounded argument literals and measured files with safe relative paths. Placement
freezes this validated delivery in the existing intent row. Identical retries
reuse that row without calling the renderer again; the caller-request digest
remains separate from the private output. Both native execution transports
prepend the frozen arguments and materialize the frozen files.

The callee receives copied configuration inputs and the owner-derived home path,
with no registry, executor, placement or nested-call permissions. Actor and
context inheritance are unchanged by scope selection. Constructing the empty
scope is a protected host-selected capability; metadata grants none of it.

Claude receives MCP and hook JSON through `--mcp-config` and `--settings`, with
`--strict-mcp-config` and `--setting-sources ""`. Even an unconfigured launch
supplies explicit empty settings. A fresh attempt can select current endpoints
without replacing files in its retained conversation home.

Codex renders `.codex/config.toml` from the selected `bee.codex_provider`
(name, base URL, model, and optional bounded `developer_instructions`; plain
http only for the loopback fixture under a fixture policy), with
`env_key = "OPENAI_API_KEY"` and the responses wire API. The field name is
the pinned Codex 0.154.0 configuration key; `--strict-config exec` rejects
the older guessed `model_instructions` name. Instructions allow ordinary text
and escaped line breaks, carriage returns and tabs; unsupported control bytes
are rejected, and the rendered file must remain within the shared 8192-byte
configuration bound after escaping.
Placement writes an admitted file with exclusive creation inside the home
before start (`configuration.materialized`); a pre-existing file refuses the
start (`configuration.refused`). The key itself reaches the child only through
the credential broker's environment projection. Drivers own their provider, MCP and hook formats. Codex also renders its
protected hook and trust files using the owner-derived absolute home path.
Placement has no provider-specific formatting branches.
A launch that declares `stdin_eof` writes its complete initial input first
and closes stdin once (`stdin.accepted`, `stdin.closed`, or
`stdin.uncertain`); placement admits it only where the executor can close
stdin, the runner refuses later input, and the carrier records a later
write as `refused`. `tests/lua/harness/codex_runner_test.lua` proves
API-key authentication-path selection through the placement runner with
the pinned executable and a controlled endpoint; the endpoint's 400 proves
neither provider acceptance nor a completed turn, and
`launch.CODEX_AUTHENTICATION` stays `unproven` until that proof runs in the
pinned build. The Claude path needs no file: the launch policy's
`environment` selects the endpoint (`ANTHROPIC_BASE_URL`) and the broker
projects `ANTHROPIC_API_KEY`; the private home carries no login state, so
the executable has only the API-key path to select.
`tests/lua/harness/claude_runner_test.lua` proves that selection through
the runner with the version-recorded executable, and
`launch.CLAUDE_AUTHENTICATION` stays `unproven` on the same condition.
The configuration write trusts the runtime fs module's containment of
symlinks below the placement root; the runner creates the configuration
parent itself inside the home it just created and refuses any existing
entry there, but it does not resolve links on its own.

Launch admission can select a retained provider home through a host-owned
`session_resource` name. It derives one bounded session identity from the
workspace and launch request, obtains a separate writable session resource
grant, and passes both to placement. Omission keeps the per-attempt home.
Placement reuses the session home only when the launch names its writable
session grant. Existing retained configuration is accepted only when its
content is byte-identical to the host-approved file. The existing intent
transaction excludes another unfinished attempt for the same owner/session;
reuse requires both native exit and completed cleanup. A repeated admission
replays its original attempt. No additional lock or session store is involved.
Application checkpoint and provider conversation recovery remain a later
boundary. Claude can refresh per-attempt endpoint settings through argv; Codex
still refuses changes to an existing protected configuration file.

The managed-window acceptance launches two real shell children through the
broker, resource admission, carrier checkpoint and placement. It reads each
child's marker after normal close and proves the second launch preserves the
first file. Existing detach/rebind, revoked-input and truthful receipt checks
also pass. This proves retained files for distinct launches, not provider
conversation recovery after a node restart.

An explicit window continuation at `machine.plan` can resolve a conversation
from the predecessor's committed hook observations. The request supplies the
previous attempt and retained session; owner lookups check the action, actor,
driver/profile measurements and session. Native exit and completed cleanup
are required before a bounded, member-authorized thread scan. Only eligible
observations committed by that actor under the predecessor's recorded gateway
binding supply a session ID; ambiguous occurrences supply none and conflicting
IDs refuse. The plan
calls the driver's existing resume method with an empty brief. It never
replays the original prompt or changes a cancelled/uncertain attempt into
a successful one. Structured continuation retains its successful-turn rule.

The focused continuation tests cover sparse pages, mismatched references,
cleanup uncertainty, denied reads, conflicting/ambiguous IDs and invalid page
progress. They also prove native Claude/Codex resume argv contains no prompt
or stdin input. Both drivers reject option-like resume references, and a window
plan rejects brief replay before dispatch. Public
Agent checkpoint/restore wiring, changed retained Codex configuration and actual
provider conversation recovery after restart remain separate acceptance gates.

Launch admission now accepts an optional `continuation` containing only
`origin_request_id`, `previous_attempt_id` and `thread_id`. It requires an empty
brief, the saved launch-plan digest and a current window definition with a
retained session resource. The original request and requested workspace
derive the session identity; the new request derives a fresh attempt. Owner
reads verify the predecessor and committed provider identity before admission
obtains new resource grants or credential projections. The carrier request keeps
the original action and thread and names the predecessor for its existing
prepare-attempt compare-and-swap. A retry reuses the new attempt's grant receipts.
No caller-selected session grant, actor or provider resume ID is accepted.

The launch-owner fixture proves this path against real thread and resource
operations, including current resource refusal and foreign-actor denial. It
constructs completed placement state explicitly and starts no native process;
it therefore does not prove native cleanup or public app restore. The Agent
app still has no saved-state recovery wiring or advertised resume schema.
