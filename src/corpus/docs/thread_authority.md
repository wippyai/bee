# Thread authority, step 2

Status: implemented on 2026-09-08 from the contract agreed between Claude and
Astra (Codex CLI design thread `01a077f7-3266-7280-8dd5-a6c7b1cf35ea`),
seventh round, for step 2 of [the build sequence](BUILD_SEQUENCE.md). The
implementation notes at the end record where the code settles a detail the
contract left open.

## Read this first

The thread authority is a set of authenticated contract functions over one
owner's SQLite database. Each mutation validates a typed request, checks the
caller's rights, and commits its record and its index rows in one
transaction. Records are immutable, ordered facts; the lifecycle tables make
legal transitions and retries cheap to check. Drivers provide evidence but
cannot manufacture terminal receipts. The existing actor-owned journal keeps
working and stays separate. Waiters, remote transports and visualizations are
consumers added later; none is needed to commit or recover a thread.

It is not a resident service. SQL serializes commitments and the functions
enforce transitions, so nothing has to run between calls. Step 3 adds one
supervised process for waits and wakeups. A Timeline or thread view is an
application that subscribes; it is never a dependency, and it can be added or
replaced at any time.

## Shape in one table

| Namespace | Holds |
|---|---|
| `bee.threads` (existing) | `journal`, `local`, `client`, `protocol` unchanged; new contracts `authority` and `lifecycle` with bindings `authority_local`, `lifecycle_local` |
| `bee.threads.records` (new) | `types`, `bounds`, `values`, `observation`, `message`, `lifecycle`, `record`: pure typed decoders and the canonical encoder, no I/O |
| `bee.threads.service` (new) | `access`, `authority`, `lifecycle` libraries and one `function.lua` per operation in `<name>_method.lua` |
| `bee.threads.persist` (evolved) | `database`, `ledger`, `migrations`, `reader`, `transaction`, `legacy`; `store` stays as the compatibility surface |

Migrations 2 (`thread_authority`) and 3 (`work_lifecycle`) are appended to the
existing checked inline ledger; migration 1 is untouched in text, name and
checksum. Rich threads live in new tables; legacy threads keep actor-only
ownership and are never rewritten or bridged implicitly.

## Astra's specification in full

**Keep the authority as contract functions over transactional storage.** Step 2 needs no resident process: SQL serializes commitments, and authenticated methods enforce transitions. Step 3 adds a supervised waiter/wakeup service; visualization remains an independent client. Do not serialize all operations through a singleton actor to compensate for weak transactions.

## 1. Decomposition

Preserve `bee.threads:journal`, `:local`, `:client`, `:protocol`, and their response shapes. Add contracts `authority` and `lifecycle`, bindings `authority_local` and `lifecycle_local`. Legacy append cannot write authoritative rich records.

Notation: all Lua libraries have no `method`; callable files export `handle`. Module lists are exhaustive ceilings, narrowed further where possible.

| Namespace: entries | Kind / files | Imports | Modules / policies |
|---|---|---|---|
| `bee.threads.records:types` | `library.lua`, `types.lua` | none | none |
| `…:bounds`, `…:values` | libraries, matching files | types/bounds | none |
| `…:observation`, `…:message`, `…:lifecycle` | libraries, matching files | values/types | none |
| `…:record` | library, `record.lua` | family decoders | `json`; no policy |
| `bee.threads.service:access` | library, `access.lua` | persist reader, records | `security`; host method authorization |
| `…:authority` | library, `authority.lua` | access, persist transactions, records | none |
| `…:lifecycle` | library, `lifecycle.lua` | access, persist transactions, records | none |
| `…:create/get/list/join/leave/close/record/read_after` | `function.lua`, `<name>_method.lua` | records, authority | `security`; existing host-selected storage policy |
| `…:admit_action/start_attempt/request_turn/end_turn/receipt` | functions, `<name>_method.lua` | records, lifecycle | `security`; storage plus restricted lifecycle admission |
| `bee.threads.persist:database` | library, `database.lua` | resources, migration ledger | `sql` |
| `…:ledger` | library, `ledger.lua` | migrations, checksum helper | `sql`, existing hash module |
| `…:migrations` | library, `migrations.lua` | none | none |
| `…:reader` | library, `reader.lua` | database, records | `json` |
| `…:transaction` | library, `transaction.lua` | database, records | `json` |
| `…:legacy` | library, `legacy.lua` | database, legacy protocol | `json` |
| `…:store` | compatibility library, `store.lua` | legacy | none |

Public interfaces are root contracts and typed clients, not repositories. Function targets remain callable only under their declared admission policies. Add `ns.definition` to each namespace.

**Keep the checked inline ledger.** Extract its implementation without altering migration 1’s identity, text or checksum. There is no benefit in introducing a second migration-entry runner now.

## 2. Typed records

Step 2 commits observations, messages and work lifecycle. Delivery marks and recap/publication projections wait for their owning authority paths. Approval projections (`approval.request`, `approval.transition`) enter only through `bee.threads.approvals:append`, authenticated by the `bee.threads.approval` action rather than membership, keyed on the approval owner's event id, and never settle anything.

Use concrete tagged unions. Bounds are decoder rules, not properties magically enforced by Lua aliases.

```lua
type Source = "stream" | "hook" | "transcript" | "mcp" | "bee"
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type Ref = {thread_id: string, record_id: string}
type Fault = {code: string, message: string, retryable: boolean}
type Usage = {
    input_tokens: integer?, output_tokens: integer?,
    cached_tokens: integer?, cost_decimal: string?, currency: string?
}
type Content = {text: string?, artifact_ref: string?}
type Observation = {
    type: string, event_key: string, observed_at: string?,
    external_id: string?, data: ObservationData, raw_ref: string?
}
type Message = {
    message_id: string, message_kind: "request" | "progress" | "reply" | "notification",
    sender_id: string, recipient_ids: {string}, content: Content,
    in_reply_to: Ref?, outcome: Outcome?
}
type Admitted = {
    request_id: string, principal_id: string, binding_ref: string,
    binding_digest: string, grant_refs: {string}, budget_ref: string,
    input: Content
}
type Started = {
    execution_kind: "process" | "runner", execution_ref: string,
    owner_epoch: integer
}
type TurnRequest = {
    input_message_ids: {string}, input: Content, resume_ref: string?,
    delivery_ids: {string}
}
type TurnEnd = {
    outcome: Outcome, answer_message_ids: {string},
    evidence_refs: {string}, usage: Usage?, error: Fault?
}
type Receipt = {
    scope: "attempt" | "action", outcome: Outcome,
    evidence_refs: {string}, error: Fault?
}
type Body = Observation | Message | Admitted | Started | TurnRequest | TurnEnd | Receipt
type Record = {
    schema_revision: string, record_id: string, thread_id: string,
    sequence: integer, recorded_at: string,
    kind: string, producer_id: string, source: Source,
    causation: Ref?, correlation_id: string?,
    action_id: string?, attempt_id: string?, turn_id: string?, body: Body
}
```

`kind` is validated against exactly the seven supported families. Record-family decoding also checks the corresponding body type.

Observation union members:

| Tag | Concrete `data` fields |
|---|---|
| `session.state` | `state:"started"|"resumed"|"ended"`, `resume_ref:string?` |
| `turn.signal` | `phase:"submitted"|"started"|"ended"`, `reported_outcome:Outcome?`, `usage:Usage?` |
| `text` | `segment_id:string`, `operation:"append"|"replace"|"complete"`, `text:string`, `channel:"answer"|"progress"|"reasoning_summary"` |
| `tool.call` | `call_id:string`, `tool_name:string`, `input:Content` |
| `tool.result` | `call_id:string`, `outcome:Outcome`, `output:Content`, `error:Fault?` |
| `notice` | `level:"info"|"warning"|"error"`, `code:string`, `content:Content` |
| `execution.exit` | `exit_code:integer?`, `signal:string?` |
| `extension` | `event_name:string`, `event_revision:string`, `payload_json:string` |

Declare each row as a named Lua record and union them as `ObservationData`. Additional normalized types from the design document are **not accepted yet**; preserve their evidence through namespaced extensions pending implementation.

Rules:

- IDs: existing 160-byte/no-control rule.
- Full encoded record: ≤16 KiB; pages ≤64 records.
- Rich threads: ≤10,000 records; bound memberships/actions/attempts/turns explicitly at 128 each initially.
- Arrays: ≤64 entries; recipient IDs distinct.
- `Content`: exactly one nonempty member.
- JSON extension payload: valid bounded JSON, depth ≤16; never interpreted as authority.
- Timestamps: canonical UTC, authority-generated for commitment.
- Unknown fields rejected; optional Lua fields encode consistently as absent.
- `schema_revision` must equal `bee.thread-record@1`.
- Step-2 `delivery_ids` must be empty; no fictitious delivery evidence.

APIs: `decode_record`, `decode_observation`, `decode_message`, and one decoder per lifecycle body, each `(unknown) -> (T?, string?)`; `encode_record(Record) -> (string?, string?)`. Encoding revalidates and uses canonical JSON for identity comparisons.

## 3. Operations

All mutations require `thread_id`, `idempotency_key`. Actor identity is derived from authenticated context. Replies use a new rich result shape; legacy replies remain untouched.

| Operation | Additional input | Success payload / callers |
|---|---|---|
| `create` | `title` | thread summary; authenticated principal with create permission |
| `get` | none | summary/head; member |
| `list` | `after_thread_id?`, `limit≤64` | accessible summaries, continuation; authenticated principal |
| `join` | `member_id`, `role`, `expected_revision` | membership revision; owner only |
| `leave` | `member_id`, `expected_revision` | membership revision; self or owner; owner cannot leave |
| `close` | `expected_revision` | closed summary; owner; reject unsettled actions |
| `record` | observation/message submission, optional context references | committed record ID/sequence, replay flag; participant/owner, with producer restrictions |
| `read_after` | `cursor`, `limit`, `filter:{kinds?:string[],action_id?:string}` | records, `scanned_through`, `has_more`; member |
| `admit_action` | `action_id`, `Admitted` | committed record; lifecycle authority |
| `prepare_attempt` | action/attempt IDs, `Prepared` (pinned binding, profile, placement binding and placement attempt, plan digest), optional `expected_previous_attempt_id` | committed record; the attempt exists in state `prepared`; lifecycle authority (added 2026-09-09 per [the carrier contract](CARRIER.md)) |
| `start_attempt` | action/attempt IDs, `Started` | committed record; moves a `prepared` attempt to `running`; lifecycle authority |
| `request_turn` | action/attempt/turn IDs, `TurnRequest` | committed record; lifecycle authority |
| `end_turn` | IDs, `TurnEnd` | committed record; lifecycle authority |
| `receipt` | action ID, optional attempt ID, `Receipt` | committed record; lifecycle authority |

Rich result: `{ok:boolean, error:Fault?, value:typed operation result?}`; exactly one success value/error.

Errors: `INVALID_ARGUMENT`, `UNSUPPORTED_SCHEMA`, `DENIED`, `NOT_FOUND`, `CONFLICT`, `LIMIT_EXCEEDED`, `INVALID_STATE`, `BUSY`, `UNLINKED_RESOURCE`, `SCHEMA_MISMATCH`.

`record` accepts no committed envelope. Bee supplies producer, source, timestamp and sequence. Ordinary message submission derives sender from actor; observations require a scoped producer authorization. In step 2 trusted test producers exercise this path; real hook authentication arrives later.

No delivery, waits, inbox decisions, forced cancellation, owner transfer or remote operation implementation in step 2. Messages record recipients but do not claim delivery.


Conditional continuation uses `prepare_attempt.expected_previous_attempt_id`.
When supplied, it must name this action's latest committed attempt-scope
receipt. The owner checks that condition and reserves the new attempt in the
same transaction. An existing prepared/running attempt still refuses admission;
a missing, foreign or superseded predecessor returns `CONFLICT`. The condition
is part of the request's idempotency identity. Replaying an already accepted key
returns its historical reply even after later work settles, without allocating
another attempt. Ordinary initial attempts omit the condition.

This is an ordering precondition, not authority to resume a provider session.
The managed launch owner must still select the correct actor, driver and durable
session state and decide whether the previous outcome permits continuation.
No migration or new process is involved.

## 4. Access

Use local membership roles now:

- `owner`: membership administration, close, read/write.
- `participant`: read and submit permitted messages/observations.
- `observer`: read only.

Lifecycle authority is a separate host-granted permission, not an owner privilege. SQL policy attachment does not authorize lifecycle commands. Preserve the original caller before any privileged storage boundary.

Do **not** add a permissive placeholder `access_binding`. Implement a small internal access facade now; introduce the external contract when a real provider exists. Membership and operation checks occur inside the commitment transaction.

Legacy threads retain actor-only ownership. Rich membership cannot grant access to legacy tables.

## 5. Migrations 2 and 3

Separate rich tables; no implicit bridge/view or rewriting legacy records. An eventual explicit importer may attach provenance. Rich references identify only rich threads in step 2.

Migration **2: `thread_authority`**:

```sql
CREATE TABLE bee_thread_heads (
  thread_id TEXT PRIMARY KEY,
  owner_actor TEXT NOT NULL,
  title TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','closed')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  head_sequence INTEGER NOT NULL DEFAULT 0
    CHECK(head_sequence BETWEEN 0 AND 10000),
  created_at TEXT NOT NULL
);
CREATE TABLE bee_thread_members (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('owner','participant','observer')),
  revision INTEGER NOT NULL CHECK(revision > 0),
  active INTEGER NOT NULL CHECK(active IN (0,1)),
  PRIMARY KEY(thread_id, actor)
);
CREATE UNIQUE INDEX bee_thread_one_owner
  ON bee_thread_members(thread_id) WHERE role='owner' AND active=1;
CREATE INDEX bee_thread_member_list
  ON bee_thread_members(actor, active, thread_id);

CREATE TABLE bee_thread_records (
  record_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  sequence INTEGER NOT NULL CHECK(sequence BETWEEN 1 AND 10000),
  schema_revision TEXT NOT NULL CHECK(schema_revision='bee.thread-record@1'),
  kind TEXT NOT NULL CHECK(kind IN (
    'observation','message','action.admitted','attempt.started',
    'turn.request','turn.end','receipt')),
  producer_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('stream','hook','transcript','mcp','bee')),
  event_scope TEXT,
  event_key TEXT,
  action_id TEXT,
  attempt_id TEXT,
  turn_id TEXT,
  record_json TEXT NOT NULL
    CHECK(length(CAST(record_json AS BLOB)) <= 16384),
  committed_at TEXT NOT NULL,
  CHECK((event_scope IS NULL AND event_key IS NULL)
     OR (event_scope IS NOT NULL AND event_key IS NOT NULL)),
  UNIQUE(thread_id, sequence),
  UNIQUE(thread_id, producer_id, event_scope, event_key)
);
CREATE INDEX bee_thread_records_kind
  ON bee_thread_records(thread_id, kind, sequence);
CREATE INDEX bee_thread_records_action
  ON bee_thread_records(thread_id, action_id, sequence);

CREATE TABLE bee_thread_commands (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  operation TEXT NOT NULL,
  request_json TEXT NOT NULL,
  reply_json TEXT NOT NULL,
  PRIMARY KEY(thread_id, actor, idempotency_key)
);
```

`event_scope` is authority-derived from source, adapter identity and attempt identity—not a caller-selected escape from deduplication. Persist the complete canonical envelope in `record_json`; extracted columns must match it. Validate JSON in Lua; do not depend on optional SQLite JSON extensions.

Migration **3: `work_lifecycle`**:

```sql
CREATE TABLE bee_thread_actions (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  action_id TEXT NOT NULL,
  admitted_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('admitted','running','ended')),
  PRIMARY KEY(thread_id, action_id)
);
CREATE TABLE bee_thread_attempts (
  thread_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0),
  started_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  state TEXT NOT NULL CHECK(state IN ('running','ended')),
  PRIMARY KEY(thread_id, attempt_id),
  UNIQUE(thread_id, action_id, attempt_id),
  FOREIGN KEY(thread_id, action_id)
    REFERENCES bee_thread_actions(thread_id, action_id)
);
CREATE UNIQUE INDEX bee_thread_live_attempt
  ON bee_thread_attempts(thread_id, action_id) WHERE state='running';

CREATE TABLE bee_thread_turns (
  thread_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  request_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  end_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id),
  PRIMARY KEY(thread_id, turn_id),
  FOREIGN KEY(thread_id, action_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, action_id, attempt_id)
);
CREATE UNIQUE INDEX bee_thread_live_turn
  ON bee_thread_turns(thread_id, attempt_id) WHERE end_record_id IS NULL;

CREATE TABLE bee_thread_settlements (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  attempt_id TEXT,
  scope TEXT NOT NULL CHECK(scope IN ('action','attempt')),
  outcome TEXT NOT NULL CHECK(outcome IN
    ('succeeded','failed','cancelled','uncertain')),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  CHECK((scope='action' AND attempt_id IS NULL)
     OR (scope='attempt' AND attempt_id IS NOT NULL)),
  FOREIGN KEY(thread_id, action_id)
    REFERENCES bee_thread_actions(thread_id, action_id),
  FOREIGN KEY(thread_id, action_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, action_id, attempt_id)
);
CREATE UNIQUE INDEX bee_thread_action_receipt
  ON bee_thread_settlements(thread_id, action_id) WHERE scope='action';
CREATE UNIQUE INDEX bee_thread_attempt_receipt
  ON bee_thread_settlements(thread_id, attempt_id) WHERE scope='attempt';
```

Cross-check referenced record thread/kind/context transactionally. These foreign keys prove existence, not semantic correspondence. Reserve enough remaining record capacity before admitting lifecycle work to permit its terminal records.

Migration 1’s SQL text, name, checksum algorithm and recorded identity must remain unchanged.

## 6. Transaction rules

SQLite writes use `BEGIN IMMEDIATE`; all membership checks, retry lookup, head increment, record insertion, lifecycle indexes and command reply commit together. Rollback restores the head, so committed sequences remain gap-free.

Identical retries return the stored result; different canonical input conflicts. Producer-event dedupe performs the same content comparison, not unconditional “already exists.”

Use WAL and foreign keys on every connection; use durable synchronization appropriate to acknowledged commitments. Configure bounded busy handling and retry the **whole transaction**, never just its last statement.

“No yield” means no process wait, network call, model call, notification or sleep while holding the transaction. SQL calls themselves may suspend through the runtime. Retry delays happen after rollback.

PostgreSQL later uses row locking on the thread head instead of `BEGIN IMMEDIATE`. Keep transaction primitives behind the repository adapter. Rebinding alone does not provide PostgreSQL support; dialect migrations and acceptance remain required.

## 7. Tests

Wippy suites under `tests/lua/threads`, run by `make test`, prove:

- Version-1 history survives migrations 2/3 byte-for-byte through legacy APIs.
- New authority works in that populated database.
- Concurrent writers produce contiguous sequences and unique IDs.
- Identical retries replay; changed requests and changed producer events conflict.
- Owner/participant/observer and lifecycle permissions remain distinct.
- Removal racing write respects transaction order.
- Invalid transitions and duplicate terminal receipts fail.
- Filters advance bounded cursors without skipping matching records.
- All size/count limits, including terminal-capacity reservation.
- Crash rollback leaves neither head gaps nor partial lifecycle indexes.
- Altered/newer migration ledgers still fail closed.

`make threads-module` boots the module alone and exercises the journal, authority and lifecycle contracts with no desktop entries loaded; the unlinked reference case stays refused.

## 8. Engineer introduction

The thread authority is a set of authenticated contract functions over one owner’s database. Each mutation validates a typed request, checks the caller’s rights, and commits its record and indexes in one transaction. Records are immutable ordered facts; lifecycle tables make legal transitions and retries efficient. Drivers provide evidence but cannot manufacture terminal receipts. The existing actor-owned journal remains compatible and separate. Waiters, remote transports and visualizations consume these contracts later; none is needed to commit or recover a thread.

## 9. Implementation notes

- Producers declare the `source` of an observation (`stream`, `hook`, `transcript`, `mcp`); the authority supplies `bee` for messages and lifecycle records, and derives `event_scope` as `source/attempt_id`.
- `bee.threads.service:types` holds the reply and summary types and `bee.threads.service:boundary` the shared method edge; the contract's table listed neither.
- Host grants are the security actions `bee.threads.create`, `bee.threads.observe` and `bee.threads.lifecycle`, evaluated with `security.can(action, thread_id)` against the caller's scope. The runtime's Lua type manifest declares `can(resource, action)` while the implementation and its spec read `(action, resource)`; the code follows the implementation.
- The runtime opens each SQLite resource with a single connection, so writers serialize on the pool and `BEGIN IMMEDIATE` is not reachable through `db:begin`. `PRAGMA busy_timeout`, `foreign_keys` and `synchronous` are set per open, and a busy failure retries the whole transaction after rollback.
- `bee_thread_commands` stores the canonical JSON of the raw request and the reply; a retry replays when operation and request bytes match and conflicts otherwise. Producer events compare canonical bodies.
- `read_after` scans at most 1024 sequences per call; `scanned_through` is the last returned sequence when more matches follow, otherwise the end of the window.
- An attempt receipt requires its open turn to be ended first; an action receipt requires no running attempt. `owner_epoch` must exceed every earlier attempt of the action.

### Carrier operations (2026-09-09)

Migration 6 `carrier` rebuilds the records table for the `attempt.prepared`
family and the attempts table for the `prepared` state (one live attempt per
action, `prepared` or `running`; an attempt may end without ever starting),
and adds `bee_thread_carriers` (attempt, carrier epoch, checkpoint revision,
checkpoint JSON). Contract `bee.threads:carrier` with action
`bee.threads.carrier`: `claim`, `commit` (records plus checkpoint in one
transaction, fenced by epoch and revision; replayed event keys deduplicate),
`checkpoint`. `bee`-sourced carrier records are `bee.*` extension
observations only. The full rules are in [CARRIER.md](CARRIER.md).
