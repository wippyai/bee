# Hive protocol

Status: agreed on 2026-09-08 between Claude and Astra (Codex CLI design
thread `01a077f7-3266-7280-8dd5-a6c7b1cf35ea`, rounds eight to ten). This is
the cross-node protocol every Bee operation uses: how a request travels, who
vouches for whom, how an operation is exposed with one line, how one function
serves every interface, and when two endpoints may talk directly. Placement
(native or Docker, local or remote) is a value inside a launch request, not a
second protocol.

## Read this first

Six terms carry the whole model. A new engineer should be able to repeat each
sentence and the paragraph after them.


| Term | Definition |
|---|---|
| **Principal** | The person or service on whose behalf an operation is requested. |
| **Owner** | The authority responsible for admitting and committing an operation on a resource. |
| **Operation** | A typed capability implemented once and reached through any number of interfaces. |
| **Request** | An identified invocation of an operation with exact input on behalf of a verified principal. |
| **Grant** | An owner-issued permission bounded by subject, audience, scope, incarnation and lifetime. |
| **Session** | An admitted exchange between endpoints whose traffic is bounded by grants. |

A principal sends a request for an operation through the caller’s supervisor and, when remote, the destination supervisor. The owner decides whether to execute, require approval or reject. The result may include a grant authorizing a direct session, so supervisors need not relay every frame. Interfaces select the same operation without adding authority; placement selects where admitted work runs.


The same rule applies whether the caller is Lua code, an MCP tool, a CLI
command or a desktop control: caller, caller's supervisor, destination
supervisor, owning service. A process address never selects a bypass. Exposing
an operation is one line on its entry (`meta.hive: open | approval | policy`);
the host sets the ceiling per namespace with ordinary security policies, and
the owner still decides at admission. `open` means hive-public, not
Internet-public or unmetered.

## Runtime facts this rests on

Verified in the pinned runtime on 2026-09-08:

- A cross-node package carries `{Source, Target, Topic, Payloads}` only. `Source` is set by the runtime from the sending process (`runtime/lua/modules/process/module.go`, `yield.From = self`); with Bee's `actor-provenance.patch` the receiver knows `Source.Node` is the authenticated peer.
- A PID is `{node@host|uniq}`; its host component names the `process.host` the process runs on. Plain `process.spawn` checks `process.spawn` on the entry and `process.host` on the host under the caller's scope (`module.go:266-270`). Astra found on 2026-09-08 that the direct `spawn_monitored`, `spawn_linked` and `spawn_linked_monitored` variants check only `process.spawn` and omit the host check, and that the process dispatcher forwards a Start without it; the runtime fix and its reproducer are Astra's (journal entries 42, 44, 49). Until the pinned runtime carries that fix, the supervisor-host identity rule is a release gate, not a proven guarantee.
- `process.send`, `monitor`, `link`, `cancel` cross nodes; `spawn`, `exec`, `terminate`, `funcs.call`, `contract.open` do not. The registry is per node; overlays are process-local.
- Trust is a startup-pinned peer key map plus the shared membership secret. There are no invitations and no live trust provider; withdrawing trust does not fence an established connection (see [the Hive POC](HIVE_POC.md)). The runtime's Ed25519 identity is not exposed to Lua.
- TTY mesh mounts are recipient-bound with rights and a 30-second lease on their own internode class; a mount reference names the owner node.

Step 1 below must still prove, on two runtimes, that no path (including
`process.exec` and function pools) can place a process on the supervisor host
without that authorization.

## Astra's final answer
### Envelopes

All envelopes are typed, bounded and revisioned. Identity fields are supervisor-derived, not trusted caller arguments.

### Request

| Field | Type / meaning |
|---|---|
| `protocol_revision` | string; initially `bee.hive@1` |
| `request_id` | string; exchange identity |
| `idempotency_key` | string; stable across retries |
| `caller_node_id` | string; authenticated originating node |
| `caller_incarnation` | string; originating supervisor incarnation |
| `owner_ref` | `{node_id, service_id, resource_ref}` |
| `operation_ref`, `operation_revision` | strings; canonical operation and contract revision |
| `input`, `input_digest` | typed input and digest of normalized effective arguments |
| `principal_ref` | `{issuer, subject_id}` |
| `principal_assertion` | typed authentication provenance; audience and validity included |
| `delegation_refs` | grant references; defaults to empty |
| `deadline` | timestamp; bounds waiting, not proof of cancellation |
| `causation_ref` | optional parent request/action reference |
| `return_ref` | correlated response route; never arbitrary executable callback |

### Reply

| Field | Type / meaning |
|---|---|
| `protocol_revision`, `request_id` | strings |
| `ok` | boolean |
| `error` | optional `{code, message, retryable}` |
| `value` | optional typed operation result |
| `grants` | grant descriptors/references; defaults to empty |

Success has `value` and no error; failure has error and no value. Pending approval is a typed result containing its owner-qualified approval reference. Replies are accepted only from the expected admitted peer/owner route.

### Grant

| Field | Type / meaning |
|---|---|
| `grant_id` | opaque string; authoritative state retained by issuer |
| `issuer_owner_ref` | issuing authority |
| `subject_ref` | principal and admitted caller identity |
| `audience` | exact destination owner/endpoint |
| `allowed_operations` | versioned operation references |
| `resource_scope` | typed resource/argument restrictions |
| `limits` | bounded calls, bytes, concurrency or other applicable budgets |
| `owner_incarnation` | issuing supervisor/owner generation |
| `authorization_epoch` | monotonic authorization revision |
| `expires_at` | owner-enforced expiry |
| `delegation_policy` | default: no further delegation |

A copied descriptor is not self-authenticating. Owners/endpoints verify it against installed authoritative grant state; no Lua signature facility is assumed.

### Session

| Field | Type / meaning |
|---|---|
| `communication_session_id` | string |
| `transport` | `tty_mount` or `process_messages` |
| `grant_refs` | authorizing grants |
| `endpoint_refs` | exact admitted endpoints |
| `protocol_revision` | traffic protocol |
| `directions` | permitted message classes in each direction |
| `sequence_rules`, `limits` | ordering, duplicate handling and backpressure |
| `expires_at` | no later than authorizing grants |
| `mount_ref` | required only for native TTY mounts |

Process frames contain `{communication_session_id, sequence, payload}`; direction is derived from authenticated source and endpoint configuration. Each direction has its own sequence space.

### Supervisor identity

**Adopt the dedicated-host design instead of configuring PIDs**, subject to two mandatory runtime acceptance guarantees:

1. `Source.Node` and `Source.Host` are runtime-derived from the actual sending process and cannot be forged through payloads, PID construction or relay behavior.
2. Every path that creates a process on `bee.hive:supervisor_host` enforces host-selected authorization, including spawn variants, services and function-pool paths.

These guarantees have not been independently verified in this no-tools round. They are release gates, not assumptions to hide in documentation.

Configuration:

- Dedicated `bee.hive:supervisor_host`, capacity one.
- Only the designated boot lifecycle may instantiate its supervisor.
- Protect the host, supervisor definition and attached policies from ordinary publication.
- `max_processes:1` limits occupancy; it does not identify the authorized executable.

Eligibility is:

`Source.Node == expected_node` and `Source.Host == bee.hive:supervisor_host`.

Then perform a challenge/response `hello` and pin the **exact PID and supervisor incarnation** for that peer session. Subsequent requests must match that session. Restarts require a fresh hello, not manual PID configuration. Names remain discovery hints.

Trust node X’s admitted supervisor as an issuer only for configured principal namespaces. If either runtime guarantee fails, use trusted registration of the actual PID at boot or fix the runtime gate; hello alone is insufficient.

### Exposure and identity policy

| `meta.hive` | Admission |
|---|---|
| `open` | Eligible authenticated peers, public bounded output, host limits |
| `approval` | Exact owner decision or matching scoped grant, plus mandatory restrictions |
| `policy` | Destination policy permits `hive.invoke` for operation/resource |

The supervisor requires `security.can("hive.expose.<mode>", operation_ref)` under the host exposure scope before catalog inclusion and again at admission.

Validate callable kind, supported revision, input/output schemas, implementation identity, exposure mode, limits and interface argument mappings. `open` additionally requires reviewed public output and appropriately restricted implementation permissions.

**Roles and attributes use existing policy evaluation.** Trusted issuer mapping constructs destination-owned `actor.meta` attributes such as role, organization and Hive identity; conditions on `actor.meta.*` decide `hive.invoke`. No separate role engine is required. Caller-supplied roles are never copied unchecked; attribute/delegation changes invalidate affected grants.

### Interfaces

Every interface uses **`operation_ref`**; contract bindings use it per method.

An interface selects an operation, supplies validated fixed/default arguments or narrows its input schema, and adds no authority. Admission evaluates final effective arguments. Traits select interfaces and context rather than becoming alternate execution paths.

### Client and execution flows

`hive.call(owner_ref, operation_ref, input, {idempotency_key})`

| Path | Flow |
|---|---|
| Initial local call | Client → local supervisor admission → owning service |
| Initial remote call | Client → caller supervisor → destination supervisor → owning service |
| Granted local call | Client → **owner-side guarded dispatch** → same implementation |
| Granted remote traffic | Admitted endpoint → guarded endpoint/native TTY mount |

**Accept cached grants, reject client-side authority enforcement.** The client may cache a grant but cannot mint a privileged scope from its fields. The owner-side dispatch boundary verifies caller binding, operation/input restrictions, incarnation, epoch, expiry and budgets, then derives the permitted execution scope.

Direct implementation calls must not bypass that boundary. Idempotency and resource checks remain operation-owned. Grants must exclude operations whose semantics require a fresh decision.

The supervisor admits work and forwards it without blocking its event loop until execution completes; it need not serialize application execution.

### Guards and leases

- Supervisor pushes epoch invalidations directly to every endpoint it admitted.
- Endpoints acknowledge and retain monotonic high-water marks.
- Every accepted process frame/call checks current local grant state, source identity, bounds and expiry.
- Grants use bounded local leases; missing renewal or supervisor loss fails closed.
- Restarted endpoints reacquire admission.
- Revocation remains `pending` until endpoint acknowledgment or lease expiry establishes fencing.
- `pg` may provide wakeups; eventually consistent maps are not authorization authority.

**TTY exception:** Lua guards do not inspect native TTY internode frames. Revoke/close the owner’s mount and stop renewal; prove established-stream revocation and the runtime’s 30-second lease expiry. Without immediate runtime revocation, report pending fencing until expiry.

Application peer blocking does not remove startup-pinned runtime trust or fence unrelated mesh traffic.

### Launch ownership

**Evolve existing `bee.launch:supervisor`; do not create another launch authority.** Keep `bee.launch:headless` as its worker/entry adapter, not a competing owner.

| Responsibility | Owner |
|---|---|
| `launch.start`, attempts, native/Docker supervision | Per-node `bee.launch:supervisor`, independent of open workspaces |
| Project resource access | Declared filesystem owner, often workspace-scoped |
| Executor/Docker capacity | Node execution authority |
| Credential access | Credential broker |
| Private attempt home | Placement/resource authority |
| Retained session state | Declared session/workspace resource owner |

Placement selects destination, runner and profile. Destination resolves resource grants; no implicit filesystem copying or path substitution.

### Build steps

| Step | Two-runtime proof |
|---|---|
| 1. Supervisors, hello, requests, open telemetry/catalog | Host-origin enforcement; unauthorized spawning denied; sibling PID rejected; restart requires fresh hello; exposure ceiling enforced |
| 2. Principal mapping, delegation, policy | Untrusted issuer denied; trusted identity without permission denied; local/remote decisions match |
| 3. Process sessions, cached local grants, guards | Wrong PID, old epoch, replay and excess limits rejected; client bypass attempts fail; revocation/lease expiry fence endpoints |
| 4. Approvals | Exact-input decision once; conflicting answers rejected; callbacks authenticate approver |
| 5. Thread subscription sessions | Replay/live handoff, filter-bound cursors, lost acknowledgments and reconnect preserve semantics |
| 6. Remote native, then Docker and TTY | Destination resource checks, no duplicate launch after reply loss, cleanup, detach/reconnect, mount revocation/expiry |

### Telemetry example

```text
1. Principal: the laptop app acts as the authenticated local user.
2. Operation: its typed client selects forge’s public stats.get operation.
3. Request: the client supplies owner_ref, input and an idempotency key.
4. Request: laptop’s admitted supervisor forwards it with principal provenance.
5. Owner: forge verifies the peer supervisor and admits its bounded open operation.
6. Owner: forge’s telemetry service returns a timestamped sample; no grant is needed.
7. Request: the collector separately calls forge’s telemetry.subscribe.
8. Grant: forge permits bounded samples between the two specific admitted PIDs.
9. Session: the endpoints exchange sequenced telemetry and acknowledgments directly.
10. Session: revocation invalidates the grant epoch; fencing completes on acknowledgment or expiry.
```
## Decisions from the rounds

- Facade is not an authority term. Interfaces (contract binding per method, MCP tool export, trait, CLI command, desktop command) name an operation with `operation_ref` and ship with the module, so tools and traces exist on day one and nothing is written twice. A trait selects interfaces and context rather than being one facade.
- Owner is not destination: the destination node may host the owner or return an authenticated owner reference.
- A callback that invokes an operation is a new Request in the other direction with its own principal and idempotency. Subscription deliveries and acknowledgments ride the already admitted session; an approval answer is a Request to the approval owner.
- A per-pair `hello` establishes a peer session (protocol revision, supervisor incarnation, challenge) but proves nothing by itself; supervisor identity comes from the PID's node and host components. Names in the cluster registries are discovery hints, never authority.
- Local Hive calls also pass through the local supervisor; ordinary `funcs.call` security does not implement exposure, approval state, delegation or idempotency. A cached grant lets repeated local calls skip the supervisor, but the owner-side guarded dispatch, not the client, derives the execution scope.
- Supervisor-pushed epochs with acknowledgments and leases distribute revocation; `pg` is a wakeup and CRDT maps are not authorization. Native TTY frames are fenced by revoking the mount and letting its lease expire; a Lua guard cannot see them.
- `bee.launch:supervisor` evolves into the per-node launch owner; `bee.launch:headless` stays its entry adapter. Workspace hosts supply context, never machine execution authority.
- `bee hive join` is not shipped as if dynamic enrollment existed; configured-peer status is what the pinned runtime supports.

## Step 1 seam as built (round 5, 2026-09-08)

- Topics `bee.hive.request`, `bee.hive.reply`, `bee.hive.hello`, `bee.hive.epoch`; LOCAL name `bee.hive.supervisor`; protocol revision `bee.hive@1`.
- Two request payloads: `types.decode_call` for a local caller (owner, target as `operation_ref` or `interface_ref`, input, optional deadline; no principal fields) and `types.decode_request` for a forwarded request (supervisor-derived node and incarnation, effective input with a verified digest, principal with an assertion whose method is exactly `node_supervisor` and whose audience is the owner node, empty `delegation_refs`, a required deadline that the assertion validity cannot outlive). Identity, incarnation and clock checks stay in the supervisor.
- `catalog.snapshot()` runs under the supervisor's attached policies; `catalog.resolve` again at admission and before dispatch. `resolve_call` and `apply_interface` return the validated operation descriptor (mode, revision, schemas, limits, measured) with the effective input and its digest. `measured` covers the entry, not its executable closure; hot replacement is outside the step 1 claim.
- Replies route destination supervisor, local supervisor, original client. The local supervisor keeps a bounded route keyed by caller PID and request id and accepts the remote reply only from the pinned destination session; late replies cannot revive expired routes.
- Host policies in `src/_index.yaml`: `bee:hive_supervisor_policy` (send, monitor, unmonitor), `bee:hive_dispatch_policy` (`funcs.call` on the three telemetry operations only), `bee:hive_supervisor_spawn_deny` (spawn variants and `process.host` on the supervisor and its host; attached by the supervisor lane to application and launch scopes). The supervisor runs as a `process.service` on `bee.hive:supervisor_host` under actor `bee.hive.supervisor`; its entry blocks are added to `src/hive/_index.yaml` when Astra's files land.

## Relation to the build sequence

This lane runs beside [the build sequence](BUILD_SEQUENCE.md). Step 3 there (delivery and waits) and step 5 (subscriptions and cross-node send) consume Sessions from steps 3 and 5 here; step 14 there (remote placement) is step 6 here. Astra owns the supervisor, transport, admission, approval integration and guard semantics; Claude owns the operation catalog and interfaces, `bee.hive:client`, telemetry operations and thread subscription sessions. Both share the envelope, actor binding and revocation fixtures.
