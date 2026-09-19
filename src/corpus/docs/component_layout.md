# Component layout for threads, approvals and drivers

Status: design contract agreed on 2026-09-08 between Claude and Astra (Codex
CLI design thread `01a077f7-3266-7280-8dd5-a6c7b1cf35ea`), second round after
[the thread records contract](THREAD_RECORDS.md). Everything here is a proposal
until implemented and accepted; existing namespaces and applied migrations are
not changed by this document.

## Decisions carried into the record contract

The first-round record contract left six questions open. The answers below are
now part of the contract and the records document has been amended to
match: approval records on a thread are references and projections of the
owner-scoped approval store, never decision commands; a session holds many
threads and a thread owns its records, obligations and recaps; recaps are a
projection service writing through a restricted authority operation; hook and
MCP ingress use distinct per-attempt credentials; dialects are pinned by
executable version, adapter digest, protocol revision and fixture digest.

**Evolve `bee.threads`; preserve the implemented journal contract.** Introduce richer authority contracts alongside it, without turning legacy `append` into permission to write lifecycle, approval, or delivery records.

All additions below are proposals until implemented and accepted. The current shell remains the packaging boundary; do not create nominal Hub packages before their dependency closures are independently mountable.

### Decisions

| Question | Decision | Rationale |
|---|---|---|
| Human-addressed vendor notifications | Always ingest an `observation.notice`; create a separate `message` with `message_kind:notification` only when an adapter can identify an explicit Bee recipient and the message passes admission. | Vendor evidence and an addressed communication have different delivery obligations. |
| Notification identity | `producer_id` identifies the authenticated ingress adapter; `sender_id` on a derived message identifies the harness participant. Preserve vendor event identity and the observation reference. | A hook process is neither proof of the harness’s process identity nor a human sender. |
| Thread ownership | A session contains many threads; each thread owns its ordered records, recipient delivery obligations, and recap checkpoints. Actions execute within a thread and may explicitly create another. | “One thread per action” confuses execution lifetime with conversation ownership. |
| Parent/child scope | Record `parent_action_id` and, for another thread, an explicit causal reference; derive child access through admission, never through ancestry alone. | Subtree scope can narrow an admitted view, but ancestry must not silently confer membership or read rights. |
| Recap | A separate projection service computes recaps and submits checkpoints through a restricted thread-authority operation. | Recap may require IO or model calls; the transactional authority validates its cursor/digest without becoming a summarizer. |
| Dialect pinning | Pin executable artifact/version, adapter digest, protocol revision, and fixture-set digest in the admitted execution profile; reject unsupported executable identity before dispatch. | Fixtures catch incompatible candidate upgrades before promotion; they cannot make an unpinned self-updating executable safe. |
| Approval ownership | The owner-scoped approval DB is authoritative; thread records contain references and projected transition evidence only. | A thread must not become a second place where the decision can be committed. |
| Hook authentication | Use distinct, scoped hook and MCP credentials for each attempt, minted by the admission authority before preparation and revoked independently. | Sharing a per-action token gives observation ingress unnecessary tool authority and survives attempt replacement too broadly. |

### Approval cross-reference

Define:

`ApprovalRef = {owner_id, scope_kind:machine|workspace, scope_id, approval_id, action_revision_digest}`.

The approval record stores an optional origin:

`{thread_owner_id, thread_id, action_id, turn_id, request_record_id}`.

An owner-local decision transaction commits the transition and an outbox item. Its thread projection contains:

`approval_ref`, `approval_revision`, `state`, `owner_event_id`, `decision_digest`.

The thread authority appends that projection idempotently using `(owner_id, owner_event_id)`. Delivery may lag or repeat; it cannot change the approval decision. The operation owner rereads its approval authority and current authorization before execution.

Amend the record contract accordingly: thread `approval.request` and `approval.transition` are **reference/projection records**, not decision commands. Decision details remain access-controlled by the approval service. Never copy sensitive approval parameters into a broadly readable thread.

### Fixtures and hook limits

Put sanitized wire captures in:

`tests/fixtures/drivers/<harness>/<protocol_revision>/`

Include `manifest.json`, raw stream/hook samples, expected normalized records, and interruption/error cases. The manifest names tested executable versions and capture provenance. Colocated tests consume these fixtures; no fixture namespace becomes a runtime dependency.

Hook credentials bind:

`principal_id`, `action_id`, `attempt_id`, `owner_epoch`, `audience:hook`, `allowed_event_types`, `expiry`.

The endpoint derives those fields from the credential, rejects payload substitutions, bounds bodies, and deduplicates producer event keys. Source tags come from the authenticated route.

**A bearer token cannot prevent forgery by another process running as the same OS user if that process can read the token.** Keep credentials out of argv/logs, use protected configuration or a credential broker, and use stronger executor isolation when required. Native Terminal retains OS-user authority. Hooks remain untrusted evidence about effects, not an enforcement boundary.

## Layout

### Structural rules

- Retain `src/<area>/` and one `_index.yaml` per namespace.
- Within an operation: **API/binding → service → persistence → records**.
- Records are pure; persistence may use records, never application implementations.
- Cross-subsystem dependencies go through contracts, not another subsystem’s repositories.
- Tables named below are proposed additions. Existing table names and applied migrations remain unchanged.
- Grants listed below are upper bounds: each entry receives only the modules and host-selected policies it actually needs.

### Thread foundation and approvals

| Namespace / status | Purpose and owned state | Contracts and imports | Grants; extraction holes | Acceptance |
|---|---|---|---|---|
| **`bee.threads` — evolve** | Preserve `journal`, `local`, and `client`; add authenticated rich thread operations. | Keep `journal`; add `thread` contract/binding for create/get/list/join/leave/send/close/read. Import service and records. | `contract`, boundary `security`; independent subsystem. Future `target_db`, `access_binding`, `process_host`. | Existing Test Status/journal callers pass unchanged; rich operations cannot be forged through legacy append. |
| **`bee.threads.records` — new** | Pure decoders, normalized records, identities, bounded content/reference schemas. No store. | Library entries; used by thread services, delivery, drivers, and projections. | No IO modules. Part of Threads. | Wrong types, oversized bodies, invalid source claims and malformed references rejected. |
| **`bee.threads.service` — new** | Membership, record admission, message obligations, turn/action transitions and terminal settlement. | Implements root contracts; imports persist, records, host access binding. | `security`; narrowly selected `process` for notifications. | Concurrent admission produces ordered records and one terminal receipt per identity. |
| **`bee.threads.persist` — evolve** | Existing journal; additive membership, recipient obligations, action/attempt/turn state and durable outbox. | Internal repository interfaces only. | `sql`, `json`, existing approved storage helpers/policies. Same owner-local `bee.threads:db`. | Upgrade a populated database; conflicting retries fail without changing history. |
| **`bee.threads.delivery` — new** | Claims, acknowledgments, wait registrations and recovery. Durable `bee_thread_deliveries`; live wait handles remain memory-only. | `delivery`: claim/ack/wait/cancel/status; imports thread service transaction interfaces and records. | `channel`, `time`, `process`; SQL only in its persist child. Future `process_host`. | Lost replies, duplicate acknowledgments, short transport limits, drain, and 60-second timeout slices. |
| **`bee.threads.projection` — new** | Transcript/recap folds and supervised checkpoint production. Rebuildable cache only. | Restricted `checkpoint` submission to thread service; read contract; optional summarizer binding. | Reader worker: `contract`, `process`, `channel`; model IO only in admitted summarizer adapter. | Rebuild from records; stale or mismatched checkpoint inputs rejected. |
| **`bee.approvals` — new** | Owner-scoped requests, revisions, decisions and transactional outbox. `bee_approval_requests`, `bee_approval_transitions`, `bee_approval_outbox`. | `approval`: request/get/list/decide/cancel/subscribe. Imports own service/persist/records and host authorization binding. | Boundary `security`; persist `sql/json`; supervisor `process/channel/time`. Independent subsystem; future `target_db`, `owner_identity`, `authorization_binding`, `process_host`. | Two approvers race: one decision; expiry enforced by owner; thread projection repairs after restart. |

Delivery tables must participate in the same transaction as the thread transitions they certify. Namespace decomposition must not accidentally split that atomic boundary across unrelated databases.

The local journal’s existing actor ownership is **not** dynamic membership. The rich contract must implement membership explicitly while leaving legacy ownership semantics intact.

### Drivers, carriers, gateway and placement

| Namespace | Purpose and state | Contracts/imports | Grants; boundary | Acceptance |
|---|---|---|---|---|
| **`bee.driver`** | Driver contract, profile validation, transport-neutral envelopes. No store. | Defines `driver`; imports thread records. | Pure contract/value component. No placement or thread repository imports. | Invalid profiles and incompatible protocol revisions rejected. |
| **`bee.driver.kit`** | Pure framing, quoting, normalized event helpers. | Imports record/profile types only. | No IO. Extractable with driver support code. | Malformed and fragmented input fixtures; no provider-specific policy. |
| **`bee.driver.transport.{stream_json,pty,acp,rpc}`** | Transport adapters, framing, bounded bidirectional exchanges; connection state only. | Transport port used by carriers; placement-provided streams/handles. | Relevant `channel/time/process/contract`; tty only for PTY adapter. | Partial frames, backpressure, cancellation, readiness and peer disconnect. ACP/RPC deferred. |
| **`bee.driver.<harness>`** | One namespace each for `claude`, `codex`, `gemini`, `cursor`, `copilot`, `amp`, `opencode`, `goose`, `cline`, `grok`, `agy`, `kiro`, `pi`. | Binds driver contract; imports kit and provider-specific pure decoders. | No direct executor, secrets, or thread SQL. Optional future packages with runtime/credential adapter references. | Pinned fixture matrix; only Claude/Codex enter initial live acceptance. |
| **`bee.harness.catalog`** | Pinned, actor-visible binding/profile projection; no authoritative table. | Driver schemas and admitted registry-read boundary. | `registry`, `security` where needed. Optional harness subsystem. | No mixed-generation binding; metadata never authorizes launch. |
| **`bee.harness.carrier`** | Window/session/batch execution state machines and reconcilers. Durable state belongs to thread action/attempt records. | Driver, placement, thread, delivery and approval contracts. | `process/channel/time/contract`; no ambient executor or SQL. Future `process_host` and named contract bindings. | Crash/restart resumes or reports uncertainty; no blind effect redispatch. |
| **`bee.gateway`** | Authenticated MCP thread tools, hook HTTP ingress, `mcp_tool` receivers. Credential hashes/revocations in owned gateway store. | Thread/delivery/approval/carrier contracts; host authentication/admission. | HTTP/JSON/security/contract at boundaries; credential-store access only in persist. Independent proposed subsystem; `api_router`, `credential_store`, authority bindings. | Forged action IDs, revoked attempts, excessive payloads and unauthorized tools denied. |
| **`bee.placement.native`** | Native executor attempts, process groups, private homes, cleanup/reconciliation. Owner-local resource receipts. | Binds `placement`; imports admitted launch specification and credential broker. | Explicit executor/fs/process grants. Future `executor`, `workspace_root`, `credential_binding`. | Child/grandchild cleanup, timeout, environment isolation, uncertain launch recovery. |
| **`bee.placement.docker`** | Container placement and reconciliation. Own resource receipts. | Same placement contract; narrow container backend. | Container API only here. Optional/deferred component. | No leaked containers/secrets; equivalent lifecycle outcomes. |
| **`bee.agent.native`** | Runner-call driver binding; dataflow batch adapter. No duplicate job journal. | Binds driver; runner/dataflow contracts and thread observations. | Explicit `funcs/contract` and admitted runner grants; no default publication authority. | Turn and two-node dataflow graph settle using the same records without external PIDs. |

Define `placement` under a neutral `bee.placement` contract namespace. Carriers—not provider implementations—compose driver, transport and placement.

Keep secret bytes out of driver profiles, thread records, and process arguments where possible. A narrowly granted placement credential adapter materializes them and records only references and cleanup outcomes.

### Desktop applications

Add standalone processes:

| Namespace | Role | Dependencies and proof |
|---|---|---|
| `bee.inbox` | Combined projection of eligible approval requests from reachable owners. | Approval client contracts; tty/UI values. Disconnect never changes a decision; unavailable owners remain distinguishable from empty inboxes. |
| `bee.thread_view` | Thread navigation, membership and addressed messages. | Thread/delivery clients; actor-filtered pages. Hidden threads never appear. |
| `bee.timeline` | Ordered observations, lifecycle, messages and references. | Thread read/projection contracts. Distinguishes observed vendor signals from Bee receipts and approval execution outcomes. |

These are default/optional application implementations, not core authority. The core broker launches their admitted definitions; neither renderer nor window manager imports their logic.

## Existing namespaces: change versus preserve

| Treatment | Namespaces |
|---|---|
| **Evolve directly** | `bee.threads`, `bee.threads.persist`. Preserve public journal identities and bounds. |
| **Minimal integration changes** | `bee.host` for resources/services; `bee.session` for explicit thread references and admitted participant context; root `bee` for composition/catalog entries. |
| **Extend only if required by typed launch contracts** | `bee.launch`, `bee.protocol`, `bee.client`; avoid making them collections of driver internals. |
| **Untouched implementations** | `bee.application`, `bee.applications`, `bee.console`, `bee.desktop`, `bee.interaction`, `bee.processes`, `bee.settings`, `bee.storage`, `bee.terminal`, `bee.test_status`, `bee.workspace`. |

In particular, leave broker-owned dialogs in `bee.interaction` as live questions. Inbox approval decisions are a new durable subsystem, not a reinterpretation of existing confirmations.

Existing apps may receive new catalog wiring without changing registry identities. The archive/legacy tree supplies reference material only, never runtime dependencies.

## Import direction

**Apps/gateway → authority contracts → services → owned persistence → records.**

**Carrier → driver + transport + placement contracts + thread/delivery/approval contracts.**

**Provider → driver kit + records.**

**Projection → thread reads; checkpoint writes → thread authority.**

**Approval owner outbox → authenticated thread projection operation.**

No reverse imports from thread authority into harness providers, desktop apps, MCP, or model runners.

## Build order and proof

1. **Records plus additive thread authority.** Prove legacy compatibility, authenticated authorship, bounded ordered reads, typed records and conflicting retries on a populated DB.
2. **Delivery and inbox.** Prove correlated fan-out, short/60-second waits, lost acknowledgment, approval races, expiry, and restart/outbox repair. Do not require any model.
3. **Driver contract, fixture kit, native placement, thin gateway, Claude and Codex carriers.** Prove real two-turn consultation, readiness, answer extraction, cancellation and process-tree cleanup. Treat missing runtime process-group support as a blocker for that claim.
4. **Native runner and dataflow proof.** Execute the same request/receipt tests without PTY, MCP, or external-process assumptions.
5. **Freeze version-1 contracts.** Publish fixture manifests and restart acceptance evidence; document implemented versus still-proposed behavior.
6. **ACP, then pi RPC.** Add transports and provider bindings without new thread record families or alternate authority stores.

Start steps 1–2 this week. Build the two live drivers immediately afterward as the first adversarial consumers, rather than broadening the catalog before the foundation survives failure.

## Round three: module conventions learned from Kickside

Kickside's published modules (`kickside/core`, `kickside/jobs`, `kickside/channel`
and the rest under `.wippy/vendor/kickside`) are the reference shape for a
publishable Wippy component. What they do, and what Bee adopts:

- One root slice per module holding `ns.definition` (title, a readme with a
  slices table, a dependency interface and a testing section) and the
  `ns.requirement` holes (`target_db`, `process_host`, `api_router`,
  `security_scope`, `env_storage`, `user_security_scope`) whose `targets`
  enumerate the exact entries and paths the host fills.
- The root slice holds the shared types: `types.lua`, `consts.lua`, `config.lua` with
  env-tunable knobs and code defaults, `clock.lua`, and `contract.definition`
  entries with JSON schemas per method.
- Sub-slices `api/`, `persist/`, `service/`, `security/`, `migrations/`; contract
  methods implemented in `<verb>_method.lua`; `notify.lua` for fan-out; access
  delegated to a contract so the engine never reads another subsystem's tables.
- Colocated `*_test.lua` run by a standalone test app that provisions a
  database, a process host, scopes and sibling modules; the same suite runs on
  PostgreSQL by rebinding `target_db`.

Decisions from the round, Astra's text follows unedited below: adopt the
interfaces and testing discipline now, keep implementation under `src/<area>/`
until a module passes extraction acceptance, then move its closure to
`modules/<package>/src/` atomically; implement Bee's thread foundation
independently of Kickside's engines while reusing their laws; thread
authority and delivery entries, additive migrations and the standalone test
application are specified concretely.

**Adopt Kickside’s module interfaces and testing discipline now; extract physical packages only after their contracts pass acceptance.** Keep implementation under `src/<area>/` during the thread-foundation work. Changing the production source boundary and the storage model simultaneously would obscure regressions.

## 1. Modules versus slices

A namespace is not automatically a Hub package. Each module has one root `ns.definition`, dependency-interface requirements, and a README slices table. Child namespaces belong to that module unless they have a separate lifecycle and release contract.

| Future module | Namespace ownership | README slices table: slice → responsibility |
|---|---|---|
| `bee/threads` | `bee.threads` and children | root → contracts, types, configuration; `records` → record decoders; `service` → authenticated methods; `persist` → transactions; `delivery` → claims/waits; `projection` → recap/cursors; `security` → policy templates; `migrations` → owned schema |
| `bee/approvals` | `bee.approvals` | root → approval contract/types; `service` → decisions/outbox; `persist` → owner-local records; `security` → policy templates; `migrations` → schema |
| `bee/driver` | `bee.driver`, `.kit`, `.transport.*` | root → driver/transport contracts; `kit` → pure helpers; `transport` → stream-json/PTY/ACP/RPC adapters |
| `bee/harness` | `bee.harness` | root → execution contracts/types; `catalog` → pinned discovery; `carrier` → lifecycle state machines; `service` → supervisors |
| `bee/gateway` | `bee.gateway` | root → configuration/types; `api` → authenticated HTTP/hooks; `mcp` → tool protocol; `service` → listener lifecycle; `persist` → credential state; `security`, `migrations` |
| `bee/persist` | `bee.persist` | root → checked migration ledger and SQLite open helper; mechanics only, no schema or resource |
| `bee/placement` | `bee.placement` | root → placement contracts and launch/receipt schemas only |
| `bee/placement-native` | `bee.placement.native` | root → binding/configuration; `service` → execution/reconciliation; `persist` → resource receipts; `security`, `migrations` |
| `bee/placement-docker` | `bee.placement.docker` | Same division, with container backend adapter |
| `bee/driver-<vendor>` | `bee.driver.<vendor>` | root → binding/profile; `protocol` → normalization; `launch` → declarative launch specification |
| `bee/agent-native` | `bee.agent.native` | root → runner binding; `turn` → runner adapter; `batch` → dataflow adapter |
| `bee/inbox`, `bee/thread-view`, `bee/timeline` | Corresponding application namespaces | root → application descriptor; `model` → view state; `view` → rendering; `process` → standalone application |

None becomes a core dependency by being installed. Core still owns composition, admission and application lifetime. Provider packages do not contain placement code. Driver transports remain one support package initially; split them only when independent dependencies justify it.

### Dependency interface

Use these exact conventions. `N` below is the module namespace; actual YAML must enumerate concrete entries, never wildcard targets.

| Requirement | Default | Target rule |
|---|---|---|
| `target_db` | `app:db` | Every `N.migrations:<migration>` at `.meta.target_db`; runtime `N:database_ref` data entry at `.data.resource_ref` |
| `process_host` | `app:processes` | Every supervised `process.service` at `.host` and its concrete lifecycle host dependency |
| `env_storage` | `app.env:store` | Each actual `env.variable` at `.storage` |
| `security_scope` | **Required** | Relevant function/endpoint `.meta.scope`, consumed explicitly by boundary adapters |
| `user_security_scope` | **Required when endpoints exist** | `N.security:endpoint_access` at `.groups +=` |
| `api_router` | `app:api` | Each actual `http.endpoint` at `.meta.router` |
| `<name>_binding` | **Required unless stated otherwise** | `N:<name>_ref` data entry at `.data.binding_ref`; a contract client resolves it |
| `owner_identity` | **Required** | `N:owner_ref` at `.data.owner_id` |

`.meta.scope` is configuration, not authority by itself. Host-attached policies must authorize the operation; adapters must enforce the configured access contract.

A single injected `database_ref` feeds runtime access and migrations. Do not reproduce the migration-target/environment-variable divergence identified in Kickside.

Module-specific requirement lists:

| Module | Requirements |
|---|---|
| Threads | `target_db`, `process_host`, `env_storage`, `security_scope`, `access_binding`, `owner_identity`; optional summarization is disabled without `summarizer_binding` |
| Approvals | `target_db`, `process_host`, `security_scope`, `authorization_binding`, `owner_identity`, `thread_binding` |
| Driver support | None initially; transports receive admitted connections, not ambient resources |
| Harness | `process_host`, `security_scope`, `admission_binding`, `thread_binding`, `delivery_binding`, `approval_binding`, `placement_binding`, `credential_binding` |
| Gateway | `target_db`, `process_host`, `api_router`, `security_scope`, `user_security_scope`, `authentication_binding`, `admission_binding`, `thread_binding`, `delivery_binding`, `approval_binding`, `harness_binding` |
| Placement contract | None |
| Native placement | `target_db`, `process_host`, `security_scope`, `executor_binding`, `workspace_binding`, `credential_binding`, `owner_identity` |
| Docker placement | Same, substituting `container_binding` for `executor_binding` |
| Vendor driver | No host-resource holes; published profile references measured provider implementations |
| Native agent | `runner_binding`, `admission_binding`; `dataflow_binding` required only when batch is enabled |
| Inbox | `approval_directory_binding`, `approval_client_binding`, `desktop_binding` |
| Threads view | `thread_binding`, `delivery_binding`, `desktop_binding` |
| Timeline | `thread_binding`, `desktop_binding` |

Threads does not acquire HTTP requirements merely to resemble Kickside. Gateway owns HTTP/MCP adaptation. No unused holes or empty slices.

## 2. Repository shape

**Keep `src/<area>/` now.** This respects the implemented production boundary and avoids duplicate namespace loading.

Exact current pattern:

`src/<area>/_index.yaml`, `src/<area>/<slice>/_index.yaml`, colocated tests, and `tests/modules/<area>/` standalone composition.

When a module passes extraction acceptance, move its closure to:

`modules/<package>/src/`, with `wippy.yaml`, `wippy.lock`, `README.md`, `LICENSE`, `Makefile`, and `test/`.

Then production `src/` contains its `ns.dependency` mount instead of the implementation. Perform that switch atomically: never load both copies. Registry IDs, storage identity and existing migrations do not change with filesystem location.

The module root README must document slices, requirements, authority boundaries, storage ownership, and tests. Adopt Kickside’s shape without requiring every shared helper to live at root: `records` remains a real child namespace because drivers consume it.

## 3. Relationship to Kickside engines

**Implement Bee independently, reusing organizational patterns and proven laws—not Kickside storage or a new shared-engine extraction.**

Kickside’s thread identity, component lifecycle and access context are coupled. Depending on it would introduce component registration and access semantics into Bee’s existing actor-owned journal. Extracting a shared engine now would require stabilizing two systems before either gains the requested functionality.

Consequences:

- Preserve `bee.threads:journal`, `:local`, `:client`, existing database ownership and applied migrations.
- Add rich contracts and tables through forward migrations; no wholesale journal conversion.
- Delegate rich-operation authorization through an injected Bee access contract; never read another subsystem’s access tables.
- Legacy journal ownership remains actor-based. Rich membership is explicit and does not retroactively change legacy access.
- Keep one owner runtime per database. Remote clients call that owner’s contract; neither mesh membership nor a PostgreSQL connection grants authority.
- Keep thread events, delivery obligations and settlement indexes in one transactional store.
- Do not import the leased Kickside jobs engine just for waits or recap. Introduce only the leases/cursors actually needed; later extraction requires demonstrated shared requirements.
- Optional Kickside integration remains an adapter with distinct domain identities.

## 4. Concrete thread and delivery entries

Root `bee.threads` defines `thread` and `delivery` contracts with input/output JSON schemas. Bindings `thread_local` and `delivery_local` point to the entries below. Existing journal bindings remain unchanged.

Every method file exports `handle`. Boundary methods normalize once, authenticate the caller, then invoke typed command/query logic.

| Entry | Kind / file | Imports | Modules |
|---|---|---|---|
| `bee.threads.service:create` | `function.lua`, `create_method.lua` | records, access, commands | `security` |
| `…:get` | `function.lua`, `get_method.lua` | records, access, queries | `security` |
| `…:join` | `function.lua`, `join_method.lua` | records, access, commands | `security` |
| `…:leave` | `function.lua`, `leave_method.lua` | records, access, commands | `security` |
| `…:send` | `function.lua`, `send_method.lua` | records, access, commands | `security` |
| `…:close` | `function.lua`, `close_method.lua` | records, access, commands | `security` |
| `…:read` | `function.lua`, `read_method.lua` | records, access, queries | `security` |
| `bee.threads.delivery:claim` | `function.lua`, `claim_method.lua` | records, access, commands | `security` |
| `…:ack` | `function.lua`, `ack_method.lua` | records, access, commands | `security` |
| `…:wait` | `function.lua`, `wait_method.lua` | records, access, waiter_client | `security` |
| `…:cancel` | `function.lua`, `cancel_method.lua` | records, access, commands, waiter_client | `security` |
| `…:status` | `function.lua`, `status_method.lua` | records, access, queries | `security` |

Supporting entries:

| Namespace | Entries |
|---|---|
| `bee.threads.service` | `access`, `commands`, `queries`: libraries; `notify`: post-commit wakeup library |
| `bee.threads.delivery` | `commands`, `queries`, `waiter_client`: libraries |
| `bee.threads.delivery.service` | `waiter`: `process.lua`; `waiter.service`: `process.service` |
| `bee.threads.persist` | Transaction coordinator, thread/event repositories, obligation/delivery repositories, settlement indexes |

`commands` owns transaction orchestration; repositories own SQL. Wait registration/recheck prevents lost wakeups. SQL transactions must never remain open during a long poll. `notify` is an accelerator; durable rows remain authoritative.

### Additive migrations

Use the **next unused sequence numbers**, assigned after inspecting the ledger; do not guess numbers or rewrite historical entries.

| New migration suffix | New tables |
|---|---|
| `thread_authority` | `bee_thread_threads`, `bee_thread_members`, `bee_thread_records`, `bee_thread_idempotency` |
| `work_lifecycle` | `bee_thread_actions`, `bee_thread_attempts`, `bee_thread_turns`, `bee_thread_settlements` |
| `delivery` | `bee_thread_obligations`, `bee_thread_deliveries`, `bee_thread_delivery_transitions`, `bee_thread_outbox` |
| `projection` | `bee_thread_projection_cursors`, `bee_thread_recap_checkpoints` |

Each migration is a numbered `function.lua` entry in `bee.threads.migrations`, with `meta.target_db`. Existing legacy tables remain authoritative for legacy records. The new record chain serves rich threads; any legacy-history attachment is explicit and provenance-preserving, never silently rewritten.

Approval tables remain in the approval owner’s database, joined through references and outbox delivery—not cross-database “atomic” promises.

## 5. Standalone test applications

Before extraction, each `tests/modules/<area>/` contains a Wippy test composition and lockfile mounting only the candidate closure and required siblings. After extraction, this becomes the package’s `test/` directory.

It provisions:

- An isolated SQL resource.
- Process host, environment storage, explicit test actors/scopes.
- Contract-bound access/clock/executor fixtures as needed.
- Test runner and readiness checks.
- Distinct denied actors, not just a permissive scope.

Use a temporary SQLite file by default: pool behavior must match production. In-memory SQLite is suitable only when connection semantics are controlled.

Separate acceptance runs:

1. **Fresh-store suites:** pure laws, methods and packaging.
2. **Populated-store upgrade:** create a database using the previous release/schema, write representative history, migrate with the candidate, restart, verify legacy reads and new operations.
3. **Failure recovery:** terminate between durable commits and delivery/projection, then reconcile.
4. **Host-mounted packaging:** nondefault resources, exact requirement targets, no test-entry publication or application namespace leakage.

For PostgreSQL, keep the same contract-level tests and rebind `target_db`; run dialect-specific migrations beneath them. Add an isolated schema/database per run. PostgreSQL support is a deliverable, not something implied by using `sql`; do not advertise it until that lane passes.

Driver fixture tests load only a manifest-selected bounded fixture set from `tests/fixtures/drivers/<harness>/<protocol_revision>/` through a test-only resource. Published production entries have no fixture filesystem grant. Extraction copies the applicable fixtures into the package’s test resources, preserving digests and provenance.

## 6. Build order

1. **Specify module roots and dependency interfaces in place.** Proof: isolated thread closure loads without desktop, Kickside, AI or MCP.
2. **Evolve thread records and authority.** Proof: legacy compatibility plus populated-DB migration and authenticated rich records.
3. **Delivery and approvals.** Proof: acknowledgment loss, short/60-second waits, approval races and owner-outbox repair.
4. **Driver support, native placement, thin gateway, Claude and Codex.** Proof: real resumed conversation, bounded credentials, correct answer settlement and process-tree cleanup.
5. **Native runner/dataflow.** Proof: same records without external-process assumptions.
6. **Freeze contracts and extract accepted modules.** Proof: independently mounted package and host assembly produce equivalent behavior; no archive dependencies or duplicate IDs.
7. **ACP, then pi RPC.** Proof: new transports reuse existing authority contracts and record families.

The module shape adds isolation tests at the beginning and extraction at the freeze point. It does not put packaging ahead of the thread and delivery proofs.

## Claude's notes on the layout

- The namespace count is high for a first slice. Build order keeps it honest:
  steps one and two touch only `bee.threads*` and `bee.approvals`; nothing under
  `bee.driver*`, `bee.harness*`, `bee.gateway` or `bee.placement*` exists until
  step three, and ACP and RPC transports until step six.
- The bearer-token limit is real: two processes under one OS user can read each
  other's credentials, so hooks are evidence and the sandbox or a confined
  placement is the enforcement line. Per-attempt credentials still matter for
  revocation and for scoping what an ingress may claim.
- Fixture captures for every harness live under
  `tests/fixtures/drivers/<harness>/<protocol_revision>/` with a manifest naming
  the executable version and provenance. The inventory's version column is the
  first manifest entry for each.
