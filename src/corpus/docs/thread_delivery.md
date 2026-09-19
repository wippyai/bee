# Thread delivery, step 3

Status: implemented on 2026-09-08 from the contract agreed between Claude and
Astra (Codex CLI design thread `01a077f7-3266-7280-8dd5-a6c7b1cf35ea`),
rounds six and seven, for step 3 of [the build sequence](BUILD_SEQUENCE.md).
Step 2 (`docs/THREAD_AUTHORITY.md`) is the base. Claude's proposal follows,
then Astra's amendments, which take precedence wherever they differ, then the
implementation notes.

## Read this first

Three things are kept apart. A recipient obligation is created only by a
`message` commit and settles only by a delivery acknowledgment or a
correlated terminal reply. A subscription is a consumer cursor with one
outstanding page at a time; acknowledging a page is never a delivery
acknowledgment. A projection (the recap) folds immutable records into a
checkpoint committed together with its cursor and settles nothing.

Claims carry the owner runtime's incarnation, not a per-thread or waiter
epoch; the waiter consumes it. A claim released before any dispatch intent
returns to pending; a claim with dispatch intent and no acceptance becomes
uncertain and needs an explicit reconciliation. Every transition is a
`delivery.mark` record in the thread, so the stream is the history and the
tables are the index. Waits never hold a transaction: check, register,
recheck, wait, and a final authoritative check before any timeout.

## Claude's proposal (round 7)
## 0. Families and the kind CHECK

Migration 2 fixed `bee_thread_records.kind` to seven families with a CHECK. Delivery marks and answered requests are record families in THREAD_RECORDS, so migration 4 rebuilds `bee_thread_records` once (create new table, copy rows unchanged, drop, rename, recreate indexes) with the CHECK extended to every family the contract names: the seven plus `delivery.mark`, `request.answered`, `approval.request`, `approval.transition`, `recap`, `publication`. Rows and record_json bytes do not change; the ledger test proves it. Decoders for `delivery.mark` and `request.answered` are added in `bee.threads.records`; the others stay rejected by the decoder until their owning step. Alternative I reject: keeping marks out of the record stream as side rows only, because then read_after cannot show a thread's delivery history and the recap has nothing to derive from.

## 1. Obligations versus subscriptions

Two tables, two lifecycles, never one row.

`bee_thread_obligations` (migration 4): one row per recipient of a message, created in the same transaction that commits the `message` record.

| column | meaning |
|---|---|
| thread_id, message_id, recipient_id | PK |
| message_record_id | FK records |
| kind | request | progress | reply | notification (copied from the message) |
| state | pending, claimed, delivered, answered, released, uncertain |
| delivery_id | the live claim, else NULL |
| answered_record_id | the correlated terminal reply record, requests only |
| created_sequence | the message sequence, for ordering and next-turn selection |

Only `message` commits create obligations; observations, lifecycle records, reads and pages never touch them. A `reply` commit with `in_reply_to` naming a request in this thread, sent by a recipient of that request, moves that recipient's obligation to `answered` in the same transaction (details in 2). Bounds: recipients are already ≤64 per message; obligations per thread are bounded by records.

`bee_thread_subscriptions` (migration 4): consumer cursors, created by `subscribe` in their own transaction.

| column | meaning |
|---|---|
| subscription_id | PK, uuid |
| thread_id, consumer_id, filter_digest | UNIQUE for durable subscriptions |
| filter_json | canonical normalized filter (kinds, action_id), digest is sha256 of it |
| durability | durable | reconstructible |
| after_sequence | committed consumer progress |
| handed_through | highest `scanned_through` handed to this consumer, so an ack cannot certify what was never delivered |
| owner_epoch | authority epoch at creation |
| created_at, closed_at | |

Consumer identity is the authenticated actor plus a caller-chosen `consumer_id` (≤160 bytes). Widening a filter is a new subscription with an explicit replay point; the old one is closed. Reading, paging or displaying records advances nothing; `ack` advances `after_sequence` only, and only to a value ≤ `handed_through`. A subscription ack is never a delivery acknowledgment; a delivery ack never moves a cursor. Bounds: ≤128 subscriptions per thread, pages ≤64 records, scan window 1024.

## 2. Claim, acknowledgment, recovery

`bee_thread_deliveries` (migration 4): one row per claim attempt.

| column | meaning |
|---|---|
| delivery_id | PK, uuid |
| thread_id, message_id, recipient_id | FK obligations |
| consumer_id, turn_id | who claimed, under which turn (turn optional) |
| channel | wait | push | mcp | native (the profile's delivery channel) |
| owner_epoch | authority epoch at claim |
| state | claimed, delivered, released, uncertain |
| claimed_at, expires_at | claim TTL |
| idempotency_key | the thread_wait key; UNIQUE(thread_id, consumer_id, idempotency_key) |
| evidence_ref, mark_record_id | transport evidence and the `delivery.mark` record of the last transition |

Partial unique index: one `claimed` delivery per obligation. Every transition commits a `delivery.mark` record (`delivery_id, message_id, recipient_id, state, owner_epoch, channel, evidence_ref`) in the same transaction as the row change, so the stream carries the history and the index makes it cheap.

Authority epoch: migration 4 adds `authority_epoch INTEGER NOT NULL DEFAULT 1` to `bee_thread_heads`. The waiter service bumps it once per thread it touches after an owner restart (first wakeup registration after start). A claim carries the epoch it was made under; an ack or release whose delivery epoch is older than the head's current epoch is refused with CONFLICT and the delivery moves to `uncertain`.

Transactions (each BEGIN IMMEDIATE, each idempotent through `bee_thread_commands` like step 2):

1. `claim` (inside `thread_wait`): authenticate the caller as the recipient (an active member whose actor is the recipient_id; or a lifecycle-authorized consumer acting for that recipient under a running attempt when turn_id is given); select obligations in state `pending` for that recipient, ordered by created_sequence, up to limit; for each insert a delivery `claimed` with expires_at = now + claim TTL (default 5 minutes, bounded by profile), set the obligation to `claimed` with that delivery_id, commit one `delivery.mark`. Same idempotency key returns the same batch.
2. `ack(delivery_id, evidence_ref?)`: by the claimant, or by the authority on a verified transport acceptance signal: `claimed` → `delivered`, obligation → `delivered`, mark record. Repeating is a replay. A `delivered` obligation is never claimable again: no automatic prompt replay after a confirmed delivery.
3. `release(delivery_id, reason)`: by the claimant only, and only while `claimed` and before the claimant reports any dispatch (the profile's carrier knows whether bytes left the process); `claimed` → `released`, obligation → `pending`, mark record. This is the only path back to `pending`.
4. Expiry (waiter service, its own transaction): a `claimed` delivery past expires_at with no ack becomes `uncertain`; the obligation becomes `uncertain`. Nothing is re-claimed automatically.
5. `reconcile(delivery_id, decision: redeliver | delivered | abandon)`: owner or lifecycle authority; `uncertain` → obligation `pending` (redeliver: a new claim will be made, the old delivery stays uncertain in history), or `delivered` with the evidence given, or `released` with abandonment recorded. The decision is a mark with the deciding actor as producer.
6. `answered`: inside the `record` transaction that commits a `reply`: the reply must be sent by the actor holding the obligation for the request named in `in_reply_to`; the obligation moves to `answered` with `answered_record_id`; if a `claimed` delivery for that obligation belongs to the same consumer, it moves to `delivered` in the same transaction (a reply is proof the request arrived); commit `request.answered` and, when applicable, the `delivery.mark`. A reply from someone who holds no obligation for that request is INVALID_STATE.

Next-turn selection reads obligations for the recipient in state `pending`; `delivered`-but-not-answered requests stay visible as outstanding in `get` and in the recap, never redelivered without transition 5.

## 3. Wait, replay handoff, cursors

`thread_wait(consumer_id, turn_id?, after_sequence, limit, wait_ms, idempotency_key)`, a contract function in `bee.threads.delivery`, plus one supervised process `bee.threads.delivery:waiter` (process.service on the host's process host, LOCAL name `bee.threads.waiter`).

1. Effective wait = min(wait_ms, 60000, caller transport budget minus margin); the caller passes its budget; a 5-second MCP ceiling yields ≤4 seconds.
2. Phase A, one transaction: claim (transaction 1 above) and read records after `after_sequence` for this consumer's implied filter (its recipient messages plus lifecycle records of its turn) as a bounded page. If the claim batch or the page is nonempty, return `{status: ready, deliveries[], records[], scanned_through, has_more}` at once. No wait is ever inside a transaction.
3. Phase B, when empty: the function opens a private wakeup topic (`bee.threads.wakeup.<waiter_id>`, process.listen), registers `{waiter_id, pid, thread_id, consumer_id, after_sequence, deadline}` with the waiter by message, then runs Phase A again (register, then recheck: a commit between the first check and the registration is caught by the recheck; a commit after registration is caught by the wakeup). Then it selects on the wakeup channel and the deadline.
4. The authority sends `bee.threads.committed {thread_id, sequence}` to the waiter after every successful commit (after commit, never inside). The waiter wakes every registration on that thread whose after_sequence < sequence, at most once per registration, and removes it. Missing waiter service: no wakeups; waits still end at the deadline, so the worst case is latency, never a lost record.
5. Timeout returns `{status: timeout, scanned_through}`; it does not end the turn. Turn end, attempt receipt, thread close or waiter drain send `{status: released, reason}` to registered waiters; the function returns that status.
6. Bounds: ≤64 registrations per thread, ≤1024 per node, BUSY beyond that; the waiter's table is memory only and rebuilt from nothing after restart (callers re-register; their next Phase A catches up).

Subscriptions: `subscribe(thread_id, after_sequence, filter, consumer_id?, durability, idempotency_key)` returns `{subscription_id, owner_epoch, after_sequence}`. Pages come from `read_after` with the subscription's filter and cursor; each page updates `handed_through` in its own short transaction. `ack(subscription_id, through_sequence, idempotency_key)` requires `after_sequence ≤ through_sequence ≤ handed_through` and advances `after_sequence`. `unsubscribe` sets `closed_at`; durable consumer state stays until an explicit `forget`. Retention floor is 0 until pruning exists; `CURSOR_EXPIRED` is reserved and returned when `after_sequence < floor`.

Projection (migration 5): `bee_thread_projections {thread_id, kind, through_sequence, revision, checkpoint_json, checkpoint_digest, updated_at; PK(thread_id, kind)}`. A projection update is one transaction: read the stored checkpoint and cursor, read records after the cursor (bounded), fold, write the new checkpoint and cursor together with a compare-and-set on revision. The recap kind folds messages, obligations and lifecycle into `{open_requests, outstanding_deliveries, last_turn, summary_lines}`; it is derived, rebuildable by deleting the row, and settles nothing. A stale checkpoint (revision mismatch) is CONFLICT and the fold restarts.

Namespaces: `bee.threads.delivery` (obligations, claims, waits; contract `delivery` with claim, ack, release, reconcile, wait, subscribe, ack_subscription, unsubscribe), `bee.threads.projection` (recap fold and read), both under the threads module root with `ns.definition`; `bee.threads.persist` gains `delivery` and `projection` readers and writers and migrations 4 and 5. Tests in `tests/lua/threads`: correlated fan-out to two recipients where one replies and one waits; lost ack becomes uncertain and needs reconcile; release before dispatch returns to pending; 60-second and 4-second slices; register-then-recheck catches a commit in the gap; waiter absent degrades to deadline; subscription ack cannot exceed handed_through; recap rebuilt from records equals the incremental one; the rebuild of bee_thread_records keeps every row byte-for-byte.


## Astra's amendments (round 7), binding

**Go after the corrections below.** The separation of recipient obligations, subscriptions and projections is right. The blockers are the batch idempotency constraint, waiter-owned epochs, acknowledgment evidence, and exhaustion of the bounded record stream.

## A. Migration 4: rebuild the CHECK, narrowly

**Yes, rebuild `bee_thread_records`, but add only the families implemented in migration 4:** `delivery.mark` and `request.answered`.

Do not pre-admit approval/publication families or shorten agreed names to `recap`/`publication`. Migration 5’s derived projection table does not require a new thread-record family.

The rebuild must preserve incoming foreign keys from lifecycle tables. Use SQLite’s documented generalized table-rebuild procedure:

- Disable foreign-key enforcement on the **dedicated migration connection before beginning** the transaction.
- Create the replacement under a temporary name, copy every column unchanged, drop the original, rename replacement, and recreate indexes.
- Run `foreign_key_check` before committing.
- Commit the ledger entry atomically with the schema change.
- Restore foreign-key enforcement before releasing the connection.

Do not rename the old table first: SQLite may rewrite foreign-key references to that temporary name. Prevent application traffic during migration.

Acceptance must compare record bytes **and** verify foreign keys, indexes, unique constraints, populated lifecycle references, crash rollback and the unchanged migration-1 checksum.

## 1. Correct the delivery schema

### Obligations

Use:

`pending | claimed | delivered | answered | uncertain | abandoned`.

Remove `released` from obligation states. Releasing a claim returns its obligation to `pending`; abandoning a recipient obligation is a distinct terminal decision.

Store `reply_record_id` and `answered_mark_record_id` separately. The reply and the `request.answered` mark are different records.

Persist exact recipient identity. Current actor-based membership is sufficient for the self-service path, but `consumer_id` is not authority to act for another recipient.

### Claim batches

Your proposed unique constraint breaks whenever one wait claims multiple messages: every delivery would share the same idempotency key.

Add a claim-batch table:

| Field | Rule |
|---|---|
| `batch_id` | Primary key |
| `thread_id`, `claimant_actor`, `consumer_id`, `idempotency_key` | Unique together |
| `request_digest` | Reject conflicting retries |
| `turn_id`, `attempt_id` | Nullable, validated together where required |
| `created_at` | Authority time |

Each delivery references `batch_id`; enforce one member per obligation within a batch. `bee_thread_commands` retains the committed reply for exact replay.

The “one claimed delivery per obligation” index is useful, but not sufficient by itself. Transactions must also reject claims unless the obligation is `pending`.

**Bound total obligations explicitly.** “Bounded by records” permits roughly 640,000 obligations at the current recipient/record limits. Choose and test a practical module limit rather than relying on that multiplication.

### Event capacity

Every claim/transition creates another record. A full thread must not prevent acknowledgment, uncertainty settlement or terminal replies.

Extend step 2’s reservation accounting:

- A request admission reserves capacity for required terminal settlement.
- Claim admission reserves capacity for its remaining mandatory marks.
- Reply admission includes the reply plus `request.answered` and any delivery acknowledgment.
- Reject new work before it consumes reserved capacity.

Unlimited release/reclaim or reconciliation cycles are not possible in a 10,000-record thread. Return `LIMIT_EXCEEDED` before admitting a cycle that cannot finish.

## B. Claim TTL

**Keep five minutes as the module default, but cap it by the actual claimant’s admitted lifetime.**

For a turn-bound claim:

`expires_at = min(now + configured_claim_ttl, admitted_turn_deadline, applicable_grant_expiry)`.

Missing deadlines do not mean infinite leases. The caller cannot extend these bounds by supplying a larger “profile” value.

For self-service claims without a turn, use the configured TTL and applicable grant expiry. Claim expiry concerns unacknowledged delivery—not how long the agent may take to answer. A delivered request may remain unanswered beyond the claim TTL.

The 60-second wait slice is independent of claim TTL.

## C. Epoch ownership

**Reject epochs bumped by the waiter.** A waiter restart must not invalidate otherwise healthy delivery authority.

Use an **owner-runtime incarnation**, shared across the linked Threads store, established by trusted module startup. Keep a stable epoch throughout that owner lifetime. The waiter consumes it; it cannot mint or advance it.

This belongs to the Threads ownership boundary, not Hive transport and not each thread head. The local-only subsystem must still work without Hive.

On owner restart:

- Prior unacknowledged claims require reconciliation.
- Prior confirmed deliveries remain delivered.
- Old claimant-control requests fail with `CONFLICT`.
- Durable subscription progress survives; old active subscription leases must be rebound.

Do not let an invalid stale acknowledgment itself mutate state. Reject it; recovery performs the uncertainty transition through an authenticated operation.

## 2. Dispatch evidence, release and reconciliation

The “carrier knows whether bytes left” rule needs an owner-recorded boundary.

Before push dispatch, the authorized carrier records **dispatch intent** against the delivery. Then:

- No dispatch intent exists: release is allowed.
- Dispatch intent exists, acceptance unknown: uncertainty/reconciliation.
- Verified acceptance: delivered.

This requires a typed `dispatch` operation and stored dispatch evidence, or an equivalent internal authority operation. A claimant’s post-crash assertion “I did not send it” is insufficient.

For MCP/native pull, the response itself may already expose the message. A caller cannot safely release it after receiving that response merely because it has not acknowledged. Lost pull responses become uncertain after expiry.

Reconciliation must append an explicit transition mark identifying the decision and evidence. On redelivery, mark the old delivery `released` with a reconciliation reason and return the obligation to `pending`; its prior uncertainty remains in history. On abandonment, use `abandoned` for the obligation.

Do not leave the current delivery permanently uncertain after recording a supposedly final reconciliation decision elsewhere without a link.

## D. Answering requests

**Require the reply sender to be the obligated recipient. No implicit owner substitution.**

An owner may act on behalf of a recipient only through a separately authorized delegation operation that records both identities. Leave that out of this step.

Additional checks:

- The referenced message is a request.
- The reply has a terminal outcome.
- The sender is currently authorized to submit it.
- A terminal reply already recorded for that obligation produces replay or conflict, not another answer.
- A reply settling an abandoned obligation requires explicit reconciliation rather than silently reopening it.

A valid reply proves the recipient received the request, but **not which ambiguous transport attempt delivered it**. If there is an exact matching live claim, commit acknowledgment with the answer. Otherwise mark the obligation answered and reference the reply evidence without inventing acceptance for a particular delivery.

Cross-thread replies remain deferred unless the owning authorities and cross-reference admission are implemented.

## 3. Subscription acknowledgment must identify a batch

`through_sequence ≤ handed_through` is too weak. A later handed page could allow a consumer to acknowledge a range it never processed.

Persist bounded page deliveries:

`page_id`, `subscription_id`, `lease_generation`, `from_sequence`, `scanned_through`, `filter_digest`, `acknowledged`.

For this step, allow **one outstanding page per subscription**. Repeated fetch returns that same page until acknowledged. Acknowledgment names `page_id` and its exact `scanned_through`.

Consequences:

- No skipped outstanding page.
- Empty filtered pages may still advance scanned progress.
- Filter replacement gets a new subscription identity.
- Subscription uniqueness includes **authenticated actor**, not merely caller-chosen `consumer_id`.
- Rebinding after restart fences stale page acknowledgments through `lease_generation`.
- `unsubscribe` stops active delivery; `resume_subscription` explicitly rebinds a retained durable consumer.

Use a dedicated `subscription_page` operation. Ordinary `read_after` must remain a read, without silently creating delivery state.

### Owner-authorized subscription lifecycle (2026-09-09)

A subscriber closes its own subscription with `unsubscribe`, preserving its
durable cursor for a later `resume`. The thread owner runs two additional
operations against **any** subscription, so it can retire subscriptions an
abandoned consumer never closes. Both are authorized by thread ownership
(`head.owner_actor == actor`), not by holding the subscription, take strict
typed requests (`thread_id`, `idempotency_key`, `subscription_id`) and reply
idempotently.

| Operation | Effect |
|---|---|
| `close_subscription` | Sets `closed_at`, retires the outstanding page, and preserves the durable cursor. Idempotent: closing an already closed or absent subscription reports it closed. Fences the old lease so a late `page` is `INVALID_STATE` and a late `ack_page` finds no outstanding page. The consumer may still `resume` from the preserved cursor under a new lease. |
| `forget_subscription` | Deletes a **closed** subscription's row and pages, reclaiming capacity. An open subscription is refused `INVALID_STATE` so an ordinary detach never loses a cursor. Idempotent: forgetting an absent subscription reports it forgotten. After it, every operation on that id is `NOT_FOUND`. |

`close_subscription` is a resumable delivery suspension, not a permanent
revocation: the consumer may `resume` under current authorization from the
preserved cursor. Permanent removal is close followed by `forget_subscription`.
A closed subscription keeps its durable cursor and still counts toward the
thread's subscription capacity; capacity is reclaimed only by an explicit
`forget_subscription`, never by silently discarding resumable progress, and a
thread at capacity refuses a new subscription until the owner forgets a closed
one. Replaying an old `subscribe` or `resume` idempotency key returns its
historical receipt but never resurrects a forgotten row or yields a usable
stale lease; the forgotten id stays `NOT_FOUND`. Thread records and recipient
obligations keep their existing owners; the lifecycle touches only
subscription rows and their pages. No migration is
added: `closed_at` and `created_at` already exist. The Wippy suite
`tests/lua/threads/subscription_lifecycle_test.lua` proves owner close with
cursor preservation and lease fencing, forget as terminal and explicit,
idempotent replies, retry replay under one key, authorization denial of a
non-owner, and the retained bound forgetting the oldest closed. Populated-store
upgrade and restart persistence are covered by the migration ledger (unchanged)
and `tests/thread_storage.py`.

## E. Wait protocol and Hive compatibility

**Private wakeup topics and post-commit notifications fit the supervisor plan**, with these amendments:

1. The function authenticates the actual waiter PID on wakeups; knowing a topic is not authority.
2. The waiter derives registration PID from authenticated message source, not the supplied `pid` field.
3. Registration is acknowledged before the second check. No acknowledgment means bounded fallback, not an assumed installed waiter.
4. Every exit path unregisters; requester exit and registration deadline also remove it.
5. Wakeups are hints. After every wake, run the authoritative check again. A claim mark, unrelated record or spurious wake must not complete the wait incorrectly.
6. At deadline, perform a **final authoritative check** before returning timeout. Otherwise “missing waiter only adds latency” is false for that call.
7. Effective transport budget comes from trusted ingress context. A caller-provided smaller budget is accepted; a larger one cannot override the gateway’s ceiling.

Do not persist an empty preliminary claim under the wait’s idempotency key. That would make every subsequent recheck replay the empty result. Commit the wait result when returning a nonempty batch or final timeout/release, with concurrent same-key waits coordinated explicitly.

`scanned_through` must describe the actual scanned prefix, not the thread head. A scan-window limit returns `has_more` even if its filtered result is empty; it must not start sleeping while unscanned records remain.

No Hive-specific identity, transport, or approval dependency belongs in the waiter.

## 4. Projection correction

Recap must fold **records only**, or read live tables at the exact same consistent cut. Reading current obligations while labeling the checkpoint with an older sequence produces an unrebuildable projection.

Use:

1. Read checkpoint/revision and a bounded immutable record batch.
2. Pure fold outside the write transaction.
3. Commit checkpoint and cursor together under revision comparison.
4. Retry on conflict.

Membership/control state absent from records cannot appear as historically derived recap state. Checkpoint digests include projection schema revision and `through_sequence`.

## Go

**Go with these amendments.** First implement migration safety, batch identities, owner incarnation and record-capacity reservations; then claims/answers, subscriptions/waits, and finally recap.

Add tests for multi-message claims, empty-wait idempotency, stale page acknowledgments, waiter restart without owner restart, owner restart with live claims, capacity exhaustion during acknowledgment, and lifecycle foreign keys after the record-table rebuild.

## Order of implementation

1. Migration 4 safety: the record-table rebuild with foreign keys disabled on the migration connection, `foreign_key_check` before commit, byte-for-byte row proof, lifecycle references intact, migration 1 checksum unchanged.
2. Owner incarnation established at Threads module startup and consumed by claims, subscriptions and the waiter.
3. Claim batches, obligations with the amended states, explicit obligation bound, record-capacity reservation extended to marks and answers.
4. Claims, acknowledgments with dispatch intent, release, expiry to uncertain, reconciliation, correlated answers.
5. Subscriptions with one outstanding page, `subscription_page`, page acknowledgment by `page_id` and exact `scanned_through`, lease generations, resume.
6. Waits: private wakeup topics, authenticated registration, register then recheck, final check before timeout, post-commit notifications from the authority.
7. Recap projection over records only, folded outside the write transaction, committed under revision comparison.

Tests: multi-message claims, empty-wait idempotency, stale page acknowledgments, waiter restart without owner restart, owner restart with live claims, capacity exhaustion during acknowledgment, lifecycle foreign keys after the rebuild, correlated fan-out with one reply and one waiter, 60-second and 4-second slices, register-then-recheck gap, waiter absent, recap rebuilt equals incremental.

## Implementation notes

- Migration 4 admits exactly `delivery.mark` and `request.answered`; the record table rebuild runs with foreign keys off on the migration connection and `foreign_key_check` before commit; the ledger applies one migration per transaction and tolerates a concurrent opener.
- The owner incarnation is one row per store advanced by `bee.threads:owner` (a `process.service` on the module's `process_host` requirement) at start; the waiter only reads it.
- Claims are self-service: the recipient actor claims its own obligations; `consumer_id` names the cursor, never another recipient. A turn-bound claim checks the turn is open; claim lifetime is the five-minute default because admitted turn deadlines do not exist yet.
- Obligations are bounded at 2048 per thread. Reservation counts one record per open request and per live claim; a reply needs one free unreserved slot for itself.
- `wait` accepts a caller-supplied transport budget that can only shorten the 60-second ceiling; the gateway ceiling arrives with the gateway. A final authoritative check precedes every timeout; registration acknowledgment within 250 ms, otherwise a one-second bounded poll.
- Post-commit notifications are sent by the method boundary after any successful non-replayed mutation on a thread; the waiter treats them as hints.
- Subscriptions store a normalized filter as canonical JSON and its sha256 as the identity digest; pages hold the range only, records are re-read from the immutable stream.
- The recap folds eight summary lines of at most 120 bytes, open requests by message id, delivery mark counts, action states and the last turn; a stale revision restarts the fold from the stored checkpoint.

## Waiter startup permission

The waiter service selects `bee.threads.waiter` as its actor through
`lifecycle.security`. The host supplies `bee:thread_waiter_policy`, permitting
registration of only `bee.threads.waiter` and message delivery to waiting actors.
It grants no database, spawn or scope-creation authority. The standalone module
host supplies the same policy. Source and source-free pack headless checks now
reject background service failures even when the workspace reports readiness;
they pass with this startup grant.

### Subscription restart acceptance (2026-09-09)

`tests/thread_storage.py` now runs the subscription lifecycle probe across real
runtime restarts on the typed-listener integration candidate. The command actor
has contract-call permissions and an explicit create grant for its one fixture
thread. Close preserves the committed page cursor across restart, resume advances
the lease generation and starts at that cursor, and forget remains `NOT_FOUND`
after another restart. The staged probe is itself linted before execution. This
passes without changing a production policy or the migration ledger; release
cutover remains separate.
