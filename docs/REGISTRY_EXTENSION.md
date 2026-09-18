# Registry-driven extension of threads and drivers

Status: design contract agreed on 2026-09-08 between Claude and Astra (Codex CLI
design thread `01a077f7-3266-7280-8dd5-a6c7b1cf35ea`), fourth round after
[the thread records contract](THREAD_RECORDS.md) and
[the component layout](COMPONENT_LAYOUT.md). It answers one question: how a new
harness, transport, delivery channel, observation type, approval presentation,
native agent or tool becomes an applied set of registry entries, delivered by a
Hub module or a registry overlay, with no change to core code. Nothing here is
implemented.

## The rule

Registry-driven means a module may add an implementation of a supported
contract, discovered from a pinned registry snapshot and admitted through the
same candidate, validate, activate, receipt lane as everything else. It never
means metadata can add an authority, a terminal state or a permission.
Installed, visible, compatible and activated are four different states, and
nothing launches because discovery found it.

## Extension points at a glance

| Extension | Entry | `meta.type` | Who validates |
|---|---|---|---|
| Driver | `contract.binding` | `harness.driver` | profile and contract validator, admission |
| Driver profile | `registry.entry` | `harness.profile` | capability schema, executable pinning |
| Transport | `contract.binding` | `harness.transport` | transport conformance, grant review |
| Inbound delivery channel | `contract.binding` | `thread.delivery_channel` | delivery contract tests; core keeps claims and acks |
| Observation schema | `registry.entry` | `thread.observation_schema` | bounded schema validator; presentation only |
| Approval presentation | `registry.entry` | `approval.presentation` | schema validator; standard fallback mandatory |
| Approval decision adapter | `contract.binding` | `approval.decision_adapter` | adapter conformance; owner authorizes |
| Native runner | `contract.binding` | `agent.runner` | runner conformance, grant review |
| Dataflow batch adapter | `contract.binding` | `agent.batch` | batch conformance |
| MCP tool export | `registry.entry` | `mcp.tool_export` | schema, collision, visibility and grant checks |

Core keeps: record families and transitions, core record schemas, admission,
publication, approval authority, and the carrier lifecycle with fencing and
settlement. Those change only through a core upgrade under the maintenance
boundary.

## Astra's proposal in full

**Make extension discovery registry-driven, while keeping authority and execution semantics explicit.** A module may add an implementation of a supported contract without a Bee code change. It cannot add a new authority, terminal state, or permission merely by declaring metadata.

“Registry-driven” includes published adapter code. It does not mean every new protocol can be described without code.

## 1. Registry model
> Amendment 2026-09-08 (Claude and Astra, round nine; corrected the same
> day): `meta` carries discovery tags and scalar references only, and every
> structured declaration with arrays lives in the entry's `data`. This is a
> layout rule, not a runtime limit: the runtime preserves list values in
> `meta` through the loader, the store, history, packs and `registry.get`
> (verified in-process and with the pinned binary; the Hive interface tests
> read `meta.hive_interface.allow[]`). An earlier note here blamed a runtime
> list drop; that was wrong. The shipped
> drivers do this: `bee.driver.<harness>:binding` carries
> `meta.type: harness.driver`, `meta.driver_id` and `meta.profiles_ref`, and
> `bee.driver.<harness>:profiles` (`meta.type: harness.profile`,
> `meta.driver_ref`) carries the validated declaration under `data.driver`.
> Read `requires_contracts[]`, `required_features[]`, `profile_refs[]` and
> `channel_refs[]` below as `data` fields. `channel_digests[]` belongs to the
> admitted execution record, not to discovery metadata; entry-only digests are
> labelled as such until executable closures are measured.


Use a single catalog service to discover and validate entries from a pinned registry snapshot. Each query below also includes `[".kind"] = "contract.binding"` or `"registry.entry"` as indicated. Discovery runs under the caller’s visibility rules.

All extension descriptors carry:

`schema_revision`, `requires_contracts[]:{id,revision}`, `requires_record_schema`, `required_features[]`.

Executable descriptors additionally identify their callable bindings. The validator computes entry and dependency-closure digests; it never trusts a supplied digest as measurement.

| Extension | Entry kind / `meta.type` | Validated payload | Discovery `meta.type` |
|---|---|---|---|
| Driver | `contract.binding` / `harness.driver` | `driver_id`, `title`, `profile_refs[]`; implements `bee.driver:driver` | `harness.driver` |
| Driver profile | `registry.entry` / `harness.profile` | Existing capability schema; explicit `driver_ref`, `transport_ref`, `channel_refs[]`, executable requirement | `harness.profile` |
| Transport | `contract.binding` / `harness.transport` | `protocol`, `protocol_revision`, `framing`, `limits`, `features[]`; implements connect/send/receive/close contract | `harness.transport` |
| Inbound delivery channel | `contract.binding` / `thread.delivery_channel` | `channel_id`, supported modes, readiness/ack semantics, interrupt behavior, limits | `thread.delivery_channel` |
| Observation schema | `registry.entry` / `thread.observation_schema` | Namespaced `event_name`, `event_revision`, bounded JSON schema, display hints | `thread.observation_schema` |
| Approval presentation | `registry.entry` / `approval.presentation` | Supported request schemas, `application_ref`, standard fallback, bounded display configuration | `approval.presentation` |
| Approval decision adapter | `contract.binding` / `approval.decision_adapter` | Supported vendor protocol, decision encoding, correlation/reconciliation features | `approval.decision_adapter` |
| Native runner | `contract.binding` / `agent.runner` | Runner contract revision, input/output schemas, event schema references, cancellation/recovery features | `agent.runner` |
| Dataflow batch adapter | `contract.binding` / `agent.batch` | Batch contract revision, dataflow reference, input/output schemas, child-event mapping | `agent.batch` |
| MCP tool export | `registry.entry` / `mcp.tool_export` | `name`, `description`, `callable_ref`, input/output schemas, effect class, required context | `mcp.tool_export` |

For example: `registry.find({[".kind"]="contract.binding", ["meta.type"]="harness.transport"})`. Never use the ambiguous unprefixed filter keys discussed earlier.

Tool exports reference existing callable definitions; they do not duplicate executable authority. Reject exposed-name collisions within an actor’s surface.

### Pinning

Each admitted profile records:

`registry_version`, `driver_binding_digest`, `profile_digest`, `closure_digest`, `transport_digest`, `channel_digests[]`, `protocol_revision`, `executable_version`, `executable_digest`, `fixture_manifest_digest`.

Native profiles replace executable identity with runner/dataflow closure digests. Platform-specific executable resolution happens before admission; a portable Hub manifest need not contain a publisher’s live registry generation.

Namespaced observations remain inside:

`kind:observation`, `body.type:extension`, `data:{event_name,event_revision,payload}`.

Registering a schema adds validation and presentation, **not a new authoritative record family**. Unregistered vendor events remain bounded opaque extension evidence and cannot drive settlement.

## 2. Overlay activation and replacement

Use the same admission path for Hub entries, local source and overlays:

1. Stage against an expected registry version.
2. Resolve and measure the full candidate closure.
3. Validate contracts, schemas, effects, grants and fixtures.
4. Obtain the required governance decision.
5. Apply definitions.
6. Activate selected bindings/profiles through a durable activation record.
7. Record publication and activation outcomes separately.

Catalogs subscribe before loading their initial snapshot, then rebuild on changes. Notifications are wakeups; reconnect and missed notifications require version reconciliation. Publish a complete validated catalog generation, never an incremental half-catalog.

**Installed, visible, compatible and activated are four different states.**

| Change | Live behavior |
|---|---|
| Add binding/profile/schema/presentation | Hot discovery; available only after appropriate activation/admission. |
| Change user default profile/presentation | Hot for subsequent requests. |
| Replace executable adapter/profile | New admissions use the new generation. Existing attempts retain their admitted closure. |
| Remove/deactivate binding | Prevent new admissions; ordinary removal drains existing attempts. Explicit revocation fences further effects. |
| Change an active attempt’s protocol, executable, environment or channel | Requires attempt replacement after reconciliation. |
| Change protected core, incompatible migrations or resources lacking live lifecycle support | Requires an explicit maintenance/restart plan; reject otherwise. |

Retaining a digest is insufficient: the runtime must retain an executable closure addressable by that identity. If it cannot, block replacement until dependent attempts drain. Never let an old attempt resolve a replaced ambient entry.

Unknown or interrupted dispatch remains uncertain. Revocation does not imply an external tool stopped.

Rollback reapplies a previously accepted definition set and activation selection through the same lane. It does not undo records, decisions, migrations or external effects.

Runtime overlay history alone is not a cold-start durability guarantee. Persist the admitted source/candidate and desired activation in the owning store; rebuild disposable overlays at boot. Durable published definitions remain registry-authoritative.

## 3. Hub module shape

`bee/driver-<vendor>` contains:

- Root `ns.definition`, README with slices/dependency/testing sections.
- Driver binding and immutable profile descriptors.
- Provider-owned launch and normalization functions/libraries.
- References to shared transport/channel contracts, or additional adapter bindings.
- Observation schemas where vendor-specific events need typed presentation.
- Test manifests and sanitized fixtures; test entries excluded from production loading.
- `ns.requirement` holes only for genuine external bindings: `runtime_binding`, `credential_binding`, and any configurable transport/channel binding. Privileged holes have no permissive default.

The driver returns a launch specification; placement resolves executors, homes and secret material. It does not acquire filesystem or container authority by importing a kit.

Fixture bytes must be included in the validation artifact or available through digest-pinned artifact references. A mutable fixture URL is insufficient.

Applying the host’s `ns.dependency` expands and links the closure. Publication must validate that expansion under the candidate’s namespace, kind and grant limits—not merely validate the original dependency entry.

A native-agent module supplies its actual supported `agent.gen1` entries, runner binding, dataflow definitions and batch adapter. Its holes name model/tool/runner/resource bindings; installation cannot grant those resources. Validate `agent.gen1` against the installed runtime/compiler rather than assuming a proposed shape is callable.

The durable receipt contains:

`operation_id`, `module_id`, `module_version`, `artifact_digests[]`, `dependency_lock_digest`, `parameter_digest`, `candidate_digest`, `test_receipt_refs[]`, `decision_ref`, `registry_version`, `activation_refs[]`, `outcome`.

The thread stores a publication receipt referencing that owner record.

## 4. Core versus registry

Core code is also represented by registry entries, but belongs to a **protected maintenance boundary**. “In the registry” does not mean “ordinary extension may replace it.”

| Concern | Ordinary overlay change? | Hub addition? | Validator/authority |
|---|---|---|---|
| Record families and state transitions | No | Only through core upgrade | Thread authority and maintenance validation |
| Core record schemas | No | New revision through core upgrade | Versioned core decoders |
| Namespaced observation payload schemas | Yes, versioned; old revisions retained | Yes | Bounded schema validator |
| Driver profiles | Yes | Yes | Profile/contract validator plus admission |
| Transport implementations | Yes, admitted closure | Yes | Transport conformance and grant review |
| Delivery-channel implementations | Yes, admitted closure | Yes | Delivery contract tests; core still owns claims/acks |
| Approval presentation | Yes | Yes | Presentation/schema validator; standard fallback mandatory |
| Vendor decision encoding | Yes | Yes | Adapter conformance; approval owner authorizes the decision |
| Tool catalogs/exports | Yes | Yes | Tool schema, collision, visibility and grant checks |
| Native agent definitions | Yes | Yes | Agent compiler, runner conformance, grant review |
| Carrier lifecycle, fencing and settlement | No | Only through core upgrade | Maintenance authority and recovery acceptance |

An approval renderer cannot approve. A decision adapter translates an already committed owner decision into a vendor response; it cannot reinterpret denial as approval.

New channels and transports must fit the carrier’s existing events: readiness, accepted/uncertain delivery, progress, terminal evidence and cancellation. A protocol requiring different lifecycle semantics needs a core contract revision.

## 5. Version negotiation

`bee.thread-record@1` remains the committed envelope revision. Bindings declare exact supported contract revisions and required features; protocol revisions identify provider dialects, not Bee record versions.

At candidate validation and again at dispatch:

- Reject unsupported record/contract revisions with `INCOMPATIBLE_SCHEMA`.
- Reject missing lifecycle features with `UNSUPPORTED_CAPABILITY`.
- Reject unmeasured executable or adapter identity with `BINDING_CHANGED`.
- Do not silently downgrade, drop required fields, or reinterpret unknown states.

Schema compatibility is explicit. A new optional field is accepted only where the current schema permits it; a new authoritative meaning requires a new supported revision.

Publishing a dialect records fixtures for initialization, answer extraction, failure, permissions, interruption and resume where claimed. Tests execute the candidate normalizer against captured input and expected records.

Fixtures establish tested compatibility, not future compatibility. Executable updates require a new candidate and fixture run. Unexpected live protocol input produces bounded diagnostic evidence and an explicit unsupported/uncertain outcome, never fabricated success.

## 6. Agents publishing extensions

Expose **`bee:publish` as the governed publication interface**, not raw registry access.

Input:

`operation:stage|validate|activate|status|rollback`, `candidate_id?`, `expected_registry_version?`, `summary?`, `entries?`, `module_requests?`, `artifact_refs?`, `requested_activations?`, `idempotency_key`.

- `stage` accepts authored entries or exact Hub/local module requests.
- `validate` records validation/test outcomes.
- `activate` references an unchanged validated candidate and the current governance decision.
- Principal, namespace ceilings and grant ceilings come from authenticated context, never input.

Validation performs:

1. Typed decoding and ownership/namespace checks.
2. Complete dependency expansion and digest measurement.
3. Registry lint, contract/profile/schema compatibility and reference validation.
4. Per-entry module/policy review and transitive executable-closure checks.
5. Tool-name collision and exposure validation.
6. Isolated executable tests and claimed transport/driver fixtures.
7. Migration, lifecycle and active-attempt compatibility checks.
8. Governance admission of the exact candidate digest.

Routine extensions within preauthorized namespaces and grants may activate autonomously. Anything pending review creates an owner-scoped inbox request bound to the immutable candidate digest. Editing the candidate invalidates that approval.

**An agent must never publish without human maintenance approval** a change to protected thread/admission/publication/approval/carrier authorities, host security attachments, or an expansion beyond its delegated permission ceiling. Grant issuance and credential disclosure remain separate authorized operations; even human publication approval must not implicitly perform them.

After activation:

- Driver/profile entries appear in the authorized driver catalog and launch UI—not automatically in Start.
- Tool exports appear only in actor surfaces whose policy admits them.
- Native agents appear in the compatible agent catalog.
- Only admitted `desktop.application` descriptors appear in Start.
- Nothing launches merely because discovery found it.

This lets agents extend Bee through measured registry contracts while preserving one place that decides who may execute, approve and settle work.
