# Threads, hooks and subscriptions

**Status: a bounded local journal and Test Status application are implemented.**
The richer membership, subscription and workflow contract below remains a
proposal. No Kickside, AI, MCP or Hub dependency is required.

## Implemented local slice

`bee.threads:journal` is a native contract, bound by `bee.threads:local`.
The public `bee.threads:client` Lua library provides `open(thread)`, then
`claim(run)`, `append(run, key, kind, body)` and `read_after(cursor)`.
Events contain `seq`, `run`, `key`, `kind` and JSON string `body`.
Reads return at most 64 ordered events; bodies are limited to 16 KiB.
The store bounds runs and events per thread and rejects conflicting retries.

Native methods derive ownership from the authenticated `security.actor()`;
a payload cannot select its author. Host-selected function policies grant those
methods their own SQLite access without granting the caller direct SQL access.
The subsystem owns `bee.threads:db` (`BEE_THREADS_DB`, default
`.wippy/threads.db`) and its checked migration ledger. This is separate from the
primary desktop store and registry history. Ownership is actor-based, not a
per-window isolation boundary; applications sharing an actor and granted journal
operations share that actor's access. Dynamic membership is not implemented.

One runtime owns this SQLite file. Concurrent actor callers are tested through
that runtime's SQL pool. Multiple runtimes opening the same file are unsupported:
a stress probe encountered write-lock failures. Future remote callers must use
the owner's contract; mesh membership does not make SQLite a replicated store.

**Test Status** is an on-demand application under Start → Tools. Run it with:

```sh
./run.sh --app bee.test_status:app desktop-checks first-run
```

The first argument selects a thread; the optional second starts an idempotently
claimed run. Without arguments it shows `desktop-checks`. R starts another run;
G replays; arrows, Page Up/Down, Home/End and the wheel browse recorded results.
Six real shared-UI checks execute in a standalone worker, paced 300ms apart for
visibility. Closing the view does not stop the worker. Reopening or restarting
Bee replays committed results; it does not resurrect a process. The view keeps
200 display lines and currently polls one bounded journal page every 300ms.
There is no production push subscription or durable consumer cursor yet.

A run claim and process spawn are separate operations. Failure between them can
leave a claim without execution; retrying that run ID will not spawn again.
Unexpected shutdown may leave queued/started as the last recorded event. The UI
labels this as recorded history, not evidence of current liveness. Durable job
scheduling, automatic retries and arbitrary script execution are not implemented.

`tests/test_status.py`, included in `make check`, exercises source and pack
argument launch, completion after view close, reopen/F12/cold replay and duplicate
run suppression. `make threads` exercises the separate subscriber prototype.
`tests/thread_storage.py` checks the production contract's caller SQL denial,
actor spoof denial, page boundaries, retry conflicts and migration integrity.
The live worker fixture also checks that spawning through the run contract does
not inherit a TTY surface or direct journal SQL authority.

## Proposed full contract

## Durable resource

A thread is a durable resource with a stable `thread_id`. It is an ordered log
for requests, results, progress and observations; it is not a process, window,
chat transcript or agent. A thread view may close while the thread, subscribers
and their cursors continue. Subscriber and view lifetimes should remain separate.

Every event carries a bounded, versioned type and body, a thread-local
`sequence` assigned at commit, a durable `event_id`, a source participant, and
optional parent/correlation/causation references. The sequence is the local
ordering authority. Source timestamps and upstream order are metadata only.

Process IDs are transport credentials with process lifetime. They are not
durable authors, cursors or correlation IDs. A boundary authenticates the actual
sender and maps it to an explicitly admitted durable participant before reading,
appending, waiting or acknowledging.

Append dedupe uses a stable source idempotency key, scoped to the thread and
source participant. Retrying the same key with the same canonical type/body
returns the original committed receipt. Reusing it with a different body or
type is a durable conflict and is rejected; it never silently creates a second
event or merges payloads.

## Access and nesting

Participant membership grants named operations and bounded resources. Registry
metadata, an event's claimed author, a hook name, and a parent thread do not
grant authority. Parent/child relationships are organizational references:
creation validates the parent, rejects cycles, and records explicit edges, but
does not inherit read, append, wait or execution rights. Cross-thread causes use
explicit references, and a parent read never reveals unauthorized child events.

The minimum operations are `create/open`, `append`, `read_after`, `wait_after`,
`subscribe/resume`, and `revoke`. Access is checked again on every operation;
revocation cancels denied waits and subscriptions. Page size, body size,
correlation filters, queue depth, wait deadline and fan-out are bounded. Storage
failure and retention exhaustion are visible errors.

## Replay and live delivery

`read_after(thread_id, replay_cursor)` returns a bounded page with a continuation
cursor. A subscriber owns a durable consumption cursor, independent from the
view's visual browsing cursor; scrolling a view must not acknowledge an event.
On reconnect, replay starts after the consumer cursor.

`wait_after` and live subscriptions use the same durable log as replay. A
successful append commits before it acknowledges the producer. A wakeup is only
a hint: the subscriber re-queries after its cursor, in bounded pages, before
advancing or acknowledging. The read/register boundary must be covered by an
atomic server operation or by a wake-and-catch-up rule, so an event committed in
that gap cannot be lost. Wake queue overflow triggers catch-up rather than skip.

Hook adapters and application producers can use the same subscription contract.
The adapter retains its authenticated source, stable upstream hook/event ID,
source schema version, run/session ID, attempt and source timestamp. A missing
hook is an explicit unknown; a generic hook fact is not evidence that a tool or
command succeeded.

## Hooks, progress and effects

Progress is an event projection that can be rebuilt from the log. Correlate a
trigger, attempts, results, cancellation and timeout with durable IDs and
causation references; do not correlate through a live PID. Applications may post
status events, while a hook adapter maps external facts to typed events.

Consumption and retries are at least once. A subscriber may receive a duplicate,
so projections and work receipts need idempotency keys. External side effects
(shell, GitHub, or another service) have no exactly-once guarantee: a timeout
means that no result was observed by the deadline, not that the work did not
happen. Running a side effect requires an independently admitted execution
identity, bounded attempts, cancellation semantics and durable failure/result
reporting. An outbox or job receipt is needed when recording an event and
scheduling work must be coordinated.

## Isolated prototype limits

The fixture is a local SQLite proof with fixed bootstrap participants and bounded
replay/wait. It can demonstrate durable order, duplicate append behavior,
sender-authenticated denial, reconnect replay and a real test-status projection.
It does not provide remote authentication, dynamic membership, compaction or
cross-database transactions, and it makes no exactly-once or arbitrary-code
execution claim. AI drivers, MCP transport, hook adapters and desktop promotion
remain future work until their own contracts and acceptance checks exist.

Run `make threads` for the fixture acceptance checks (also part of `make check`).
These cover multi-page replay and live catch-up, exclusive cursor resume,
invalid cursors, per-thread sequence isolation, byte-identical retry/conflict,
subscriber SQL/append/foreign-thread denial, and changed-migration rejection.
The fixture does not yet implement the full event envelope proposed above:
its rows contain `seq`, `source`, `key`, `kind`, and JSON `body`. It compares JSON
bytes rather than canonicalizing arbitrary input and persists no consumer cursor.

The native contract framing probe confirms on the pinned W1 runtime that a bound
Lua function has a different execution PID from its caller, while retaining the
caller's security actor and SQL denial. A public native contract adapter must
authorize the security actor and resource; it cannot pretend its outgoing actor
message was sent by the original PID. The fixed participant fixture still uses
exact PID admission internally. Native definitions/bindings are the intended
public operation boundary. Trait/tool metadata may describe adapters to those
operations later but does not supply authority. W2 compatibility remains unproved.

The fixture now exercises a native contract read adapter and a typed Lua reader.
An owner-issued bearer capability authorizes read access to exactly one thread
for that owner lifetime; a bound function returns through its own PID. It does
not forward a claimed caller PID as authentication. These ephemeral capabilities
are intentionally delegable and must not enter checkpoints. Public actor/resource
membership and revocation are still proposals; this fixture does not implement
them. Its subscriber uses the reader to catch up after private wake messages.
