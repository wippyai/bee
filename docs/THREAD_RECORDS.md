# Thread records and driver bindings

Status: design contract agreed on 2026-09-08 between Claude (this repository's
harness inventory) and Astra (Codex CLI, design thread
`01a077f7-3266-7280-8dd5-a6c7b1cf35ea`). Nothing below is implemented; it is
the target the thread system and the driver system are built to. Sources of
truth for what harnesses actually emit are in
[the harness inventory](HARNESS_INVENTORY.md).

## What was reconciled

Claude's draft normalized every harness hook, stream event and transcript
line into a flat list of kinds. Astra's review kept that coverage but drew
authority lines the draft blurred, and the following are now agreed:

- Drivers and hooks only ever submit `observation` records. Lifecycle
  transitions (`turn.request`, `turn.end`, `receipt`), delivery marks,
  approvals and publication receipts are committed by Bee authorities only.
- A hook `Stop` or a stream `result` is a `turn.signal` observation, evidence
  for a Bee-settled `turn.end`, never the settlement itself. Process exit and
  `SessionEnd` are evidence, not receipts.
- `launch` splits into `attempt.started` (Bee) and a `session.state`
  observation (vendor). `tool.failure` merges into `tool.result` with an
  outcome. Shell commands carry phases, because "before execution" is not
  "ran". Compaction is a phase pair, not a declared gap.
- `ask` is the inbox: `approval.request` and `approval.transition`, with
  execution outcome recorded separately. Claude Code's elicitation is a
  correlated response channel for an outstanding request, not a push channel.
- Every record carries a `source` tag (`stream`, `hook`, `transcript`, `mcp`,
  `bee`) assigned by authenticated ingress, never taken from the payload.
- Dedupe by stable producer event keys; independent hook and stream evidence
  of the same moment stays separate.
- The legacy rule "a long-lived stdin can never receive messages" described
  the POC's implementation, not a law: protocol carriers (ACP, app-server,
  RPC, stream-json stdin) are valid when a binding profile declares them.
- The three-function driver becomes `prepare` (declarative launch or call
  spec), `dispatch` (structured turn and control operations) and `normalize`
  (protocol envelopes to observations); byte and line parsing moves into
  transport adapters, because a bidirectional permission RPC does not fit
  three functions.
- No binding auto-enables bypass flags, trust skipping or inherited
  environments. A private home is isolation of configuration, not OS
  confinement.

## The contract, as proposed by Astra

### 1. Normalized records

Use `record.kind` for the outer family and `body.type` for observations. Drivers submit observations; only Bee authorities commit lifecycle transitions, delivery marks, approvals, and receipts.

### Common envelope

Every committed record carries these fields:

| Field | Type | Rule |
|---|---|---|
| `schema_revision` | string | Initially `bee.thread-record@1`. |
| `record_id` | string | Globally unique immutable ID. |
| `thread_id` | string | Owning thread. |
| `sequence` | integer | Transactionally assigned per-thread order. |
| `recorded_at` | timestamp | Authority-assigned UTC time. |
| `kind` | enum | Family below. |
| `producer_id` | string | Authenticated producer identity. |
| `source` | enum | `stream \| hook \| transcript \| mcp \| bee`. Assigned by authenticated ingress, never trusted from payload. |
| `causation` | record reference or null | `{thread_id, record_id}`. |
| `correlation_id` | string or null | Related logical exchange. |
| `action_id` | string or null | Logical admitted work. |
| `attempt_id` | string or null | Execution attempt. |
| `turn_id` | string or null | Admitted conversational turn. |
| `body` | typed record | Determined by `kind`. |

Types: `Content` is bounded text/structured blocks or authorized artifact references; `Outcome` is `succeeded|failed|cancelled|uncertain`; `Error` is `{code:string,message:string,retryable:boolean}`. Nullable fields must be explicit.

### Record families

| `kind` | Required body fields |
|---|---|
| `observation` | `type:string`, `event_key:string`, `observed_at:timestamp|null`, `external_id:string|null`, `data:typed record`, `raw_ref:string|null`. Requires action/attempt IDs; turn may be unknown. |
| `message` | `message_id:string`, `message_kind:request|progress|reply|notification`, `sender_id:string`, `recipient_ids:string[]`, `content:Content`, `in_reply_to:message reference|null`, `outcome:Outcome|null`. |
| `action.admitted` | `request_id:string`, `principal_id:string`, `binding_ref:string`, `binding_digest:string`, `grant_refs:string[]`, `budget_ref:string`, `input:Content`. |
| `attempt.started` | `execution_kind:process|runner`, `execution_ref:string`, `owner_epoch:integer`. |
| `turn.request` | `input_message_ids:string[]`, `input:Content`, `resume_ref:string|null`, `delivery_ids:string[]`. Bee admission, not a prompt hook. |
| `turn.end` | `outcome:Outcome`, `answer_message_ids:string[]`, `evidence_refs:string[]`, `usage:Usage|null`, `error:Error|null`. Bee settlement. |
| `receipt` | `scope:attempt|action`, `outcome:Outcome`, `evidence_refs:string[]`, `error:Error|null`. One immutable terminal receipt per scope ID. |
| `approval.request` | `approval_id:string`, `request_kind:permission|question`, `requester_id:string`, `operation_ref:string|null`, `prompt:Content`, `response_schema:object`, `expires_at:timestamp`, `state:pending`. |
| `approval.transition` | `approval_id:string`, `expected_revision:integer`, `state:approved|denied|expired|cancelled`, `decider_id:string|null`, `response:Content|null`, `reason:string`. |
| `delivery.mark` | `delivery_id:string`, `message_id:string`, `recipient_id:string`, `state:claimed|delivered|released|uncertain`, `owner_epoch:integer`, `channel:string`, `evidence_ref:string|null`. |
| `request.answered` | `request_message_id:string`, `recipient_id:string`, `reply_message_id:string`, `outcome:Outcome`. |
| `recap.checkpoint` | `through_sequence:integer`, `content:Content`, `input_digest:string`, `policy_ref:string`. |
| `publication.receipt` | `publication_id:string`, `candidate_digest:string`, `registry_version:string|null`, `outcome:Outcome`, `evidence_refs:string[]`, `error:Error|null`. |

`Usage = {input_tokens:integer|null, output_tokens:integer|null, cached_tokens:integer|null, cost_decimal:string|null, currency:string|null}`. Missing usage is unknown, not zero.

Requests and progress require `outcome:null`. A terminal reply requires `in_reply_to` and a non-null outcome. A reply settles only its identified recipient obligation; fan-out needs one obligation per recipient.

Approval authorizes a response/operation under current grants; it does **not** prove execution succeeded. Execution has its own receipt.

### Observation types

All carry the common observation fields above.

| `body.type` | Required `data` fields |
|---|---|
| `session.state` | `state:started|resumed|ended`, `resume_ref:string|null` |
| `turn.signal` | `phase:submitted|started|ended`, `reported_outcome:Outcome|null`, `usage:Usage|null` |
| `text` | `segment_id:string`, `operation:append|replace|complete`, `text:string`, `channel:answer|progress|reasoning_summary` |
| `tool.call` | `call_id:string`, `tool_name:string`, `input:Content` |
| `tool.result` | `call_id:string`, `outcome:Outcome`, `output:Content`, `error:Error|null` |
| `permission.signal` | `external_request_id:string`, `phase:requested|resolved`, `operation:Content`, `reported_decision:allow|deny|null` |
| `model.exchange` | `exchange_id:string`, `phase:request|response`, `content:Content|null`, `model_ref:string|null`, `usage:Usage|null` |
| `file.change` | `resource_ref:string|null`, `path:string`, `change:create|modify|delete|rename|unknown`, `previous_path:string|null`, `call_id:string|null` |
| `command.state` | `command_id:string`, `phase:requested|started|ended`, `command:Content`, `exit_code:integer|null`, `call_id:string|null` |
| `subagent.state` | `external_agent_id:string`, `phase:started|ended`, `reported_outcome:Outcome|null` |
| `context.compaction` | `phase:started|ended`, `summary:Content|null` |
| `notice` | `level:info|warning|error`, `code:string`, `content:Content` |
| `execution.exit` | `exit_code:integer|null`, `signal:string|null` |
| `extension` | `event_name:string`, `payload:Content` |

Unknown vendor events use namespaced `extension`; never invent certainty. Full model prompts are optional, redacted evidence—not mandatory thread content.

**Changes to Claude’s draft:**

- Split `launch` into attempt start and observed vendor-session start.
- Hook `Stop` becomes `turn.signal`, not authoritative `turn.end`.
- Process exit and `SessionEnd` are evidence, not receipts.
- Merge `tool.failure` into `tool.result`.
- Split shell command phases; “before execution” does not mean “ran.”
- Compaction is not necessarily a thread-history gap.
- Replace `ask` with inbox requests; elicitation results are not execution outcomes.
- Deduplicate by stable producer event keys; do not merge independent hook/stream evidence merely because text matches.

### 2. Delivery rules

**Default session delivery:** a pending message becomes input to the next admitted resumed turn, where tested resume support exists. Do not expose unsupported Cline JSON resume as session capability.

Persistent protocol carriers remain valid: a blocked stdin read need not block the carrier’s event loop. The legacy “long-lived stdin can never receive messages” statement describes its implementation, not a universal restriction.

Push is enabled only by the selected binding profile: stream-json stdin, Amp steering, ACP, app-server/RPC, or another verified adapter. Claude elicitation is a correlated response channel for an outstanding request, not generic unsolicited push.

MCP pull is available **where an admitted MCP client or bridge exists**. Pi needs an extension bridge; native runners use the same thread port directly. Prompt-time context injection remains briefing, not delivery acknowledgment.

### `thread_wait`

Arguments: `consumer_id`, `turn_id`, `after_sequence`, `limit`, `wait_ms`, `idempotency_key`.

1. Authenticate consumer and active turn. Return only admitted recipient messages.
2. Effective wait is `min(requested, 60_000, transport_budget_minus_margin)`.
3. A 5-second MCP ceiling requires shorter waits; it cannot carry a 60-second call.
4. Atomically check eligibility and register the waiter, preventing replay/live gaps.
5. Claim eligible deliveries and return IDs plus cursor. Repeating the same key returns the same batch.
6. Commit `delivered` only on explicit consumer acknowledgment or a verified transport acceptance signal.
7. A correlated terminal reply atomically commits `request.answered`; it can acknowledge its delivery in the same transaction.
8. Timeout returns `status:timeout` and a cursor; it does not fail or finish the turn.
9. Turn end, cancellation, instance revocation, or gateway drain releases the waiter with an explicit status.
10. Next-turn selection excludes delivered messages and answered obligations. Delivered-but-unanswered work remains visibly outstanding; redelivery requires an explicit reconciliation decision.

No network protocol guarantees “never replayed” after acknowledgment loss. Guarantee **idempotent acceptance by delivery ID**, no automatic repeat after confirmed delivery, and explicit uncertainty after ambiguous dispatch. Merely appearing in `thread_read` is not delivery.

### 3. Binding capability schema

Put a validated `meta.driver` record on the `contract.binding`. Metadata describes support; host admission selects authority and placement.

A binding has `schema_revision`, `kind`, `title`, `implementation_version`, `profiles[]`, and `default_profile`. All required; reject unknown fields.

Each profile represents one tested mode/protocol combination. Defaults below are conservative.

| Field | Exact shape / default |
|---|---|
| `id`, `mode` | Required string; `window|session|batch`. |
| `protocol` | Required `stream-json|acp|app-server|rpc|sdk|native|pty|http-events`. |
| `protocol_revision` | Required string identifying tested dialect/schema. |
| `hooks` | `{transports:(command|http|mcp_tool|plugin)[], events:string[], adapter_ref:string|null}`; default empty/null. |
| `answer_path` | `{strategy:terminal_field|accumulate|transcript|runner, adapter_ref:string}`; required. A JSON path alone cannot express all thirteen. |
| `resume` | `{strategy:per-process|in-process|none, portable:boolean}`; default `none,false`. |
| `inbound` | `(next_turn|mcp_pull|stream_stdin|steering|acp|rpc|runner)[]`; default `[]`. |
| `isolation_env` | `{variables:string[], private_home:boolean}`; default `[],true`. Metadata requests the shape; host policy authorizes it and placement supplies the values. |
| `trust_preanswer` | `{supported:boolean, adapter_ref:string|null}`; default `false,null`. Applying it requires an admitted trust decision. |
| `exit_codes_trustworthy` | boolean; default `false`. Means process pass/fail evidence, never unconditional logical success. |
| `input_ready` | `{strategy:protocol|hook|probe|none, adapter_ref:string|null, timeout_ms:integer}`; default `none,null,15000`. No readiness means no automatic PTY typing. |
| `interrupt` | `{methods:(protocol|signal_group|runner_cancel)[], adapter_ref:string|null}`; default empty/null. Placement owns signals. |
| `mcp` | `{client_transports:(stdio|streamable_http|sse|ws)[], bridge_ref:string|null, tool_filter:{syntax:string,adapter_ref:string}|null, initialize_timeout_ms:integer|null, call_timeout_ceiling_ms:integer|null}`; default empty/null fields. |
| `sandbox` | `{providers:string[], required_placement_features:string[]}`; default empty arrays. Empty means no advertised built-in sandbox. |

Unknown timeout ceilings are not unlimited: host policy supplies a conservative bound. Tool-filter syntax belongs to a measured provider adapter, never interpolated shell text.

The old three-function interface needs generalization:

- `prepare` returns a declarative launch/call specification.
- `dispatch` handles structured turn/control operations.
- `normalize` consumes protocol envelopes.

Parsing bytes/lines belongs to transport adapters. Process argv is one dispatch implementation. One carrier state machine composes these adapters; three legacy functions alone do not cover bidirectional permission RPC.

Do not automatically enable `--yolo`, bypass flags, trust skipping, or inherited environments. Private homes do not establish OS confinement. Native Terminal retains OS-user authority unless an explicitly confined placement is selected.

### 4. Native agents and swarms

A native binding uses `protocol:native`, `answer_path.strategy:runner`, `inbound:[runner]`, no hooks/MCP, and `execution_kind:runner`.

`prepare` selects an exact published runner/model binding; dispatch invokes it asynchronously. Runtime callbacks normalize into the same observations. The runner still has an attempt, turn, budget, cancellation path, and terminal receipt—just no external process or exit code.

Batch dispatch starts a dataflow run. Child nodes become admitted child actions when Bee controls their execution; otherwise they remain observed subagents. The distinction prevents an observed vendor child from masquerading as an independently authorized Bee agent.

Agent creation remains publication plus instance admission. Native execution grants neither publication authority nor unrestricted Lua modules.

External-driver definitions and artifacts can also be packaged and moved where compatible. Native agents are simpler to relocate, not uniquely publishable.

### 5. Order of work

**Start thread records, delivery, and inbox this week, with one thin real-driver vertical slice.** Do not build thirteen command wrappers against an unsettled authority model.

| Workstream | Phase-1 scope | Acceptance |
|---|---|---|
| Thread foundation | Typed records, transactional sequencing/idempotency, requests/replies, delivery claims/acknowledgments, turn-aware waits, inbox transitions, restart recovery. | Two recipients receive correlated requests; one replies, one awaits approval. Restart during delivery, expire the approval, reconnect the waiter: no lost obligations, duplicate terminal receipts, or falsely answered requests. Exercise both 60-second and short transport slices. |
| Driver foundation | Shared carrier state machine, fixture runner, Claude and Codex per-process profiles, isolated launch configuration, gateway readiness, observations, answer extraction, process-group cleanup where supported. | Launch, deliver a second turn, recover resume references, distinguish tool failure from turn failure, crash before answer acknowledgment, and reconcile without blind redispatch. Approval cancellation must not report execution success. |
| Native proof | One admitted runner turn and a two-node dataflow batch. | Same request/delivery/receipt queries work without PID, PTY, or MCP assumptions. |

Freeze record schemas after those proofs, then add ACP and pi RPC. The other bindings should be fixture-driven compatibility work, not new lifecycle designs. Cluster work can proceed independently because ownership epochs, resumable reads, and uncertain outcomes are explicit from the first implementation.

## Amendments from the second round

- `approval.request` and `approval.transition` on a thread are reference and
  projection records of the owner-scoped approval store described in
  [approvals](APPROVALS.md), appended idempotently by `(owner_id, owner_event_id)`
  from the owner's outbox. They never commit a decision. Cross-reference shape:
  `ApprovalRef = {owner_id, scope_kind: machine|workspace, scope_id, approval_id, action_revision_digest}`.
- A session contains many threads. The thread owns records, delivery
  obligations and recap checkpoints; actions execute within a thread and may
  create another with an explicit causal reference and `parent_action_id`.
  Ancestry never confers membership or read rights.
- `recap.checkpoint` is produced by the projection service and submitted
  through a restricted thread-authority operation that validates cursor and
  digest.
- `producer_id` identifies the authenticated ingress adapter; `sender_id` on a
  derived message identifies the harness participant. Human-addressed vendor
  output is an `observation.notice` unless an adapter can name an admitted Bee
  recipient, in which case a `message` of kind `notification` is derived from it.
- Hook and MCP ingress use distinct per-attempt credentials binding
  `principal_id`, `action_id`, `attempt_id`, `owner_epoch`, `audience`,
  `allowed_event_types` and `expiry`; the endpoint derives those fields from
  the credential and rejects payload substitutions.
- Dialects are pinned in the admitted execution profile by executable version,
  adapter digest, `protocol_revision` and fixture-set digest; an unsupported
  executable identity is rejected before dispatch.

See [component layout](COMPONENT_LAYOUT.md) for where each of these lives.
