# Supervisor implementation boundary

The peer-exchange library, request admission, internal supervisor process and
open telemetry dispatch are implemented. Public bootstrap, enrollment and
workspace discovery remain pending. The Hive supervisor lane owns `src/hive/supervisor`;
public envelopes, the catalog and the local client remain in `bee.hive`.
The launch supervisor remains the authority for starting work. This component
admits and routes requests; it must not create a second launch owner.

## Implemented components

| Entry | Responsibility |
|---|---|
| `bee.hive.supervisor:peers` | Pure bounded handshake state and exact peer replacement |
| `bee.hive.supervisor:admission` | Originating actor identity and assertion/deadline validation |
| `bee.hive.supervisor:dispatch` | Revalidate the selected operation, execute and validate output |
| `bee.hive.supervisor:execute` | Function-worker adapter over the same dispatch implementation |
| `bee.hive.supervisor:main` | Peer discovery, handshake retry, request routes and asynchronous worker results |
| `bee.hive.supervisor:principals` | Destination principal mapping: the host's table of admitted trusted issuer and subject pairs and the policies each acts under; the `bee.hive.member.` actor is derived from the pair (harness lane) |
| `bee.hive.supervisor:thread_admission` | Thread-operation admission after verified ingress: a forwarded `bee.threads.service:send` or `send_status` runs as the mapped actor under the mapping's scope with the authenticated caller node (harness lane) |
| `bee.hive.supervisor:admit_thread` | The worker for that path, taking the accepted request and answering with the hive reply (harness lane) |

The internal process takes `{configured_nodes = {...}}` from its trusted boot
owner and requires the dedicated supervisor host. It does not read arbitrary
configuration from callers. The fixture explicitly supplies its narrow naming,
messaging, catalog and execution policies. No production service is started by
these entries. Public activation still requires the host-admission runtime fix,
protected bootstrap and preservation of host restrictions when scopes are rebuilt.

Ordinary broker, desktop and host policies now restrict `process.host` to
`bee:workers`. Their policy IDs remain unchanged so reconstructed scopes retain
the restriction. The core spawn deny also covers the supervisor host and entry
for spawn, monitored/linked spawn and exec. Native scoped tests exercise those
policies and explicit-deny precedence over an additional broad grant. This does
not replace native host admission or protect an independently published
`default_host` function adapter; protected bootstrap remains required.

### Verified native service startup

The runtime's `process.service` configuration already accepts an `input` array.
Its service owner converts those values to startup payloads and starts the
declared process on the declared host. No extra boot-input hook is needed.
The service's `lifecycle.security` selects its startup actor and policies in
the native supervisor controller. This is the host-composition boundary for
the Hive service; the reusable process need not embed host-specific grants.
Resolution failure prevents the service from starting.
The process host resolves the process entry's `security` configuration before
submitting its Lua execution, and a missing policy fails startup.

Policy resolution adds declared policies to any inherited scope; it does not
automatically replace a broader scope. The startup acceptance must therefore
prove both the expected actor and denied unrelated operations under the actual
service context. Service input is trusted composition, not an enrollment API.
`make hive-supervisor-check` also boots two supervisors through this service
configuration and proves bidirectional telemetry and clean shutdown. Test-only
assertions inserted before the staged supervisor's startup inspect its actual
actor and scope without replacing either. They verify own-name/dispatch access
and deny unrelated names, functions, database access, spawning, host selection
and scope creation. The ordinary client separately proves denied supervisor
spawn, actor-name registration and cancellation. Actor-name registration is not
registry publication. Strict Lua lint, Go vet and race-enabled acceptance pass.
Production service activation and enrollment remain unimplemented.

`make hive-supervisor-check NATIVE_WIPPY=...` boots two real native runtimes
from one frozen snapshot of Hive, its production canonical encoder and a minimal
fixture host, with explicit test enrollment. It verifies
node-qualified discovery without supplied peer PIDs, telemetry in both directions,
resource refusal, sibling-actor denial, a fresh-PID supervisor restart and shutdown.
The fixture also installs a foreign supervisor PID under the local alias using
explicit native registration permission: the client refuses it and recovers
after restoring its own supervisor. This proves the client node check, not
distributed-name collision precedence.
This is supervisor acceptance, not public pairing or workspace selection.

## Peer establishment

The supervisor's candidate listeners use
`process.listen(topic, {message = true, type = T})`. V1 remote payloads remain
maps: the runtime validates the decoded value against the receiver's local
type before delivery, and `message:data()` returns that checked value. No type
identity is transmitted. Domain decoders still enforce exact fields and bounds;
native `message:from()`, the established peer and destination policy determine
authorization. This requires runtime PR #718 and its Go-Lua dependency; the
published Bee runtime pin has not yet been updated.

`bee.hive.supervisor:peers` provides `new`, `begin`, `receive`, `expire`,
`forget`, `current`, `pending`, `active_peers` and `is_configured`. It performs no I/O
and grants no permissions. Its owner supplies authenticated sender PIDs, fresh
random challenges and monotonic milliseconds. Configuration caps enrolled nodes,
active peers and pending exchanges at 64 each; handshake deadlines cannot exceed
60 seconds. Returned peer and pending descriptions are copies. The owner must
call `expire` and handle returned clock errors; active peers are never silently
evicted to free capacity.

Completed transcripts can replay a lost final answer without replacing a peer
or extending a deadline. The recipient consumes duplicate final answers without
replying, preventing an endless exchange. Seventeen native Wippy cases cover
handshake, simultaneous initiation, identity rejection, replacement, expiry,
capacity, copied values, replay recovery and clock/reflection rejection. These
are state-library proofs, not proof of a running admission service.

Discovery supplies a candidate address. Admission first checks the native sender
node against enrolled peer authority and the sender host against the protected
supervisor host. Neither a payload node ID nor a registry name establishes this.
The dedicated-host prerequisite is tracked in
[the host admission review](../runtime/research/PROCESS_HOST_ADMISSION.md).

A challenge exchange then establishes the exact peer PID and incarnation.
Challenge values come from a fresh random source supplied by the owner, not a
counter or the peer. Each outstanding challenge binds its expected node, exact
PID, local incarnation and a bounded deadline. Responses to expired, consumed or
foreign challenges cannot change the active peer.

Keep an active peer and a replacement candidate separate. A discovery update or
an unsolicited hello must not retire a working peer. Only a completed fresh
exchange may replace it. This prevents a delayed hello from an old PID from
rolling back the current peer. Installing a replacement invalidates permissions
bound to the previous incarnation before admitting new requests through it.

The public Hello envelope carries a sender incarnation, its challenge and an
optional response to the recipient's challenge. Both parties must answer a fresh
challenge before either accepts that party's requests. A request may overtake a
hello when separate topic queues are selected; an unestablished peer receives a
bounded unavailable response, never speculative execution. A transport send is
not proof that the destination has installed peer state.

Pending exchanges, established peers, per-peer requests and queued bytes need
explicit caps. Expiry and cancellation release pending state. Duplicate hello
messages may replay the same bounded response; they do not allocate new state or
extend the original deadline. Eviction cannot silently remove an active grant.

## Name scope

The current client resolves a LOCAL `bee.hive.supervisor` alias. Preserve it for
local callers. Native lookup uses a composed registry rather than a local-only
lookup, so the client validates the returned node against its own native node
as well as checking the supervisor host. LOCAL registration alone does not
constrain lookup scope. Any cross-node advertisement must include the native node ID in
its name so different machines cannot compete for one eventual-registry key.
The internal process advertises `bee.hive.supervisor/<native-node-id>` through
the native EVENTUAL registry, then publishes its LOCAL alias after registration
succeeds. Friendly Bee names are display aliases. The client-side node check
rejects a foreign supervisor even if discovery returns its PID under the alias.

## Dispatch

Decode the local Call or remote Request before consuming capacity. Derive the
local principal from the authenticated caller; validate remote assertions
against the installed peer and configured issuer mapping. Resolve the canonical
operation and effective arguments, then enforce the destination exposure ceiling.
A worker executes an admitted operation without blocking the supervisor event
loop. Only the expected worker may supply the correlated result. Deadline expiry
ends waiting; it does not establish cancellation or justify repeating effects.

The first implementation executes only the three reviewed open telemetry
operations. It checks the owner service and rejects resource references, validates
input schema/digest/revision, re-resolves the measured entry before invocation,
and validates output schema and bytes. The function-worker path retains the
caller's restricted scope; metadata cannot grant `funcs.call`. Entry measurement
is not closure pinning, and hot replacement during dispatch is not claimed safe.

Routes are bounded at 64 total, eight per calling actor or remote supervisor,
and eight executing workers. Each forwarded exchange gets a supervisor-owned
ID while retaining the original client's ID in its private route. Pending
identical retries reuse the route; changed input conflicts. Replies must match
the expected peer PID and incarnation. Timeout or replacement abandons a result,
but a worker retains its capacity charge until actual completion. These are
read-only operations; there is no durable command-deduplication receipt here.

## Destination principal mapping and thread operations

The value this path consumes is the `types.Request` that
`admission.accept` returns for a remote sender: the peer session pinned by
hello (exact PID and supervisor incarnation), `caller_node_id` and
`caller_incarnation` equal to that peer, `owner_ref.node_id` this node,
`principal_ref.issuer` the peer node with a `subject_id` in its actor
namespace, the assertion within its lifetime. Nothing in the payload
selects an actor, a scope or a caller node afterwards.

`bee.hive.supervisor:principal_mappings` is the host's typed table:
`{issuer, subject_id, policies}` per admitted principal, each pair once,
subjects inside the issuer's namespace. The destination actor is
`principals.actor_of(issuer, subject)`, `bee.hive.member.` plus a digest
of the pair: the host names no actor, so a table edit can neither retarget
a pair to another actor nor alias two pairs to one actor, no local service
actor can be named, and the identity holds across every table version and
restart; linking two issuers' subjects to one identity is an explicit
future policy, not a table edit. The thread owner grants membership to
that derived actor id. The encoding is `bee.hive.member@1`: sha256 over
the issuer, a newline and the subject (identifiers never carry a newline,
so the pair is unambiguous), the first 128 bits in hex after the prefix;
changing it is an identity migration, never a silent edit. A forwarded
`bee.threads.service:send` or `send_status` first faces the common
operation checks every path faces: the host exposure ceiling
(`hive.expose.policy` on the operation, granted by
`bee:hive_thread_exposure_policy` in this composition), the owner service
with `owner_ref.resource_ref` bound to the payload's `thread_id`, the
operation revision, the exact payload fields, the input digest and the
deadline. It is then admitted only when the authenticated
`(issuer, subject)` is in the table and runs as the derived actor under
exactly the mapping's policies, with `caller_node_id` set from the
ingress (a payload value must match, and actor, scope or principal fields
in the payload refuse the request). Invocation is the principal's own
authority: under the mapped actor and scope the worker asks
`bee.hive.supervisor:invoke_check` whether `hive.invoke` is granted on
the operation, and a mapping whose policies do not carry it (the host
names `bee:hive_thread_invoke_policy` in a mapping for that) is refused
before the owner is called; the worker's exposure grant supplies no
invocation authority. Bounds: an input above `types.MAX_INPUT_BYTES`
never decodes at ingress, a message above the owner's record bound is
refused by the owner without a commit, and a reply above
`types.MAX_OUTPUT_BYTES` is refused with `LIMIT_EXCEEDED` naming
`send_status` as the way to learn what committed. Queued and in-flight
work is bounded by the supervisor's routes (64 in total, 8 per calling
peer supervisor, 8 executing workers), refused `BUSY` before dispatch and
released on completion or failure; a route past its deadline after
dispatch reports `DEADLINE_EXCEEDED` with the outcome unknown, never a
cancellation. The route bounds are exercised only through the
supervisor process, so their proof rides on the two-runtime acceptance. The destination thread owner checks
membership and commits under `(thread, actor, caller node, key)`, so two
subjects of one node never share a commit identity, the identity is stable
across the caller's incarnations, and a table change affects later
admissions only. Local callers never reach this path; the supervisor
routes only accepted remote requests to it.
`tests/lua/hive/principals_test.lua` and `thread_admission_test.lua` prove
unknown issuer and subject denial, same-node subject isolation, identity
stable across incarnations, refusal after a mapping or membership removal,
payload selection refused, and the worker's hive reply.

### Stable subject assertion (interface note)

The subject the originating supervisor asserts today is the calling
process PID, which changes with every process, so a host-configurable
table cannot be written for it. The interface the destination expects,
retained with the forwarding work:

- `principal_ref.subject_id` is the originating runtime's authenticated
  security actor of the caller, qualified by the issuer node; the
  destination maps the exact pair.
- A caller cannot supply or override it in a local Hive Call; the
  forwarding supervisor sets it from what the runtime authenticated.
- The caller PID stays provenance only, never a subject.
- When the forwarding supervisor cannot obtain a trustworthy actor
  identity it refuses to forward; looking up an actor named in the payload
  or treating the sender PID as a stable subject is not a fallback.

Runtime evidence today: a received process message exposes only its
sender PID and payload; message provenance authenticates no actor. A
function invoked through `funcs` runs with the caller's authenticated
actor (`security.actor()` in the callee), so a forwarding supervisor that
takes local Hive Calls through a function entry can read the caller's
actor there; a message-based local call has no authenticated actor, and a
runtime API exposing the sender's actor on a received message does not
exist. Whether the local Hive Call moves to a function entry or the
runtime gains such an API is the forwarding lane's decision.

### Supervisor-process integration test

Driving `main → admission.accept → admit_thread → thread owner` end to
end needs an established peer session, which one runtime cannot host:
`main` requires the protected supervisor host and a native relay node
identity in its PID, and a peer is a sender whose PID carries another
node's identity on that host. The two-runtime harness
(`tests/hive_remote.go`) establishes such peers, but a thread operation
reaches a destination only when the originating supervisor forwards it,
and forwarding today admits open catalog operations only; both are
forwarding-lane changes. Until then the destination boundary is proven at
the worker (`admit_thread`) with requests shaped exactly as
`admission.accept` returns them, with the subject supplied by the test as
a trusted issuer would; that closes neither originating-actor
authentication nor two-runtime acceptance.

Principal assertions currently identify only an actor PID in the originating
node's namespace, with that node as issuer. Foreign issuer/subject claims,
stale incarnations, impossible timestamps, future issuance, expiry and lifetimes
over 30 seconds are refused. Human identity mapping and clock-skew tolerance
remain later work. The normal local-only address marker never crosses the mesh
and does not stand in for durable node identity.

Approval, policy
delegation, cached grants and direct sessions stay unavailable until their own
owner checks and recovery proofs exist. Public activation additionally needs
adversarial in-flight replacement, lost-reply and capacity acceptance, plus
the protected boot checks above.

## Destination admission handoff (harness lane, 2026-09-09)

The final state of destination principal mapping and thread-operation
admission, handed back with forwarding, originating-actor authentication
and two-runtime acceptance still with the supervisor lane.

**Operations and policies.** Admitted thread operations:
`bee.threads.service:send` and `bee.threads.service:send_status`, contract
revision `1`, owner service `bee.threads` with `owner_ref.resource_ref`
bound to the payload's `thread_id`. Host policies: `bee:hive_thread_exposure_policy`
(`hive.expose.policy` on both operations, attached to the worker),
`bee:hive_thread_invoke_policy` (`hive.invoke` and `funcs.call` on both
operations and `bee.hive.supervisor:invoke_check`, named by the host in a
principal mapping, never attached to a worker),
`bee.hive.supervisor:thread_admission_policy` (the worker's `funcs.call`
on the two operations and `registry.get` on the mapping table) and
`bee.hive.supervisor:thread_identity_policy` (the worker acting as the
mapped actor under the mapping's policies). Principal table
`bee.hive.supervisor:principal_mappings` (`meta.type`
`bee.hive.principal_mappings`): `mappings: [{issuer, subject_id,
policies}]`, each pair once, subjects inside the issuer's namespace, no
actor named; the actor is `bee.hive.member@1`, `bee.hive.member.` plus the
first 128 bits of sha256 over issuer, newline, subject.

**Verified ingress consumed.** The `types.Request` that
`admission.accept` returns for a pinned peer session (caller node and
incarnation equal to the peer, owner on this node, principal issuer the
peer with a subject in its namespace, assertion within lifetime). Missing
boundary: the asserted subject is a process PID; the stable subject
interface above is required before a host table can be written for a real
peer, and forwarding refuses without a trustworthy actor identity.

**Proofs passing** (`tests/lua/hive/principals_test.lua`,
`thread_admission_test.lua`, `types_test.lua`, with `tests/lua/threads`):
unknown issuer and subject denied; same-node subject isolation; identity
stable across caller incarnations; refusal after mapping or membership
removal; payload caller node, actor and stray fields refused; revision,
owner service, resource binding and deadline refusals; the principal's
own `hive.invoke` required; oversized input never decoding; a message
above the owner's bound refused without a commit; per-subject status and
unmapped status denied; duplicates creating no record; the worker's hive
reply; the `UNCERTAIN` fault carrying its identity and no other code
carrying one. **Pending with the supervisor process and the two-runtime
harness:** route limits (64 routes, 8 per calling peer supervisor, 8
executing workers, `BUSY` before dispatch), worker capacity release on
completion or failure, peer replacement fencing a pending route,
commit-before-reply loss answered `UNCERTAIN` with the identity for
status or identical replay.

**Files changed in the supervisor lane:** `src/hive/supervisor/main.lua`
(the accepted-request branch to `admit_thread`; route identity fields;
a route expiring after dispatch answers `UNCERTAIN` with its identity
instead of `DEADLINE_EXCEEDED`), `src/hive/supervisor/_index.yaml`
(entries below), `src/hive/types.lua` (`Fault.identity`, `types.uncertain`,
the decoder accepting an identity on `UNCERTAIN` only),
`src/hive/catalog.lua` (`catalog.INVOKE`), `src/_index.yaml` (the two
host policies). New: `src/hive/supervisor/principals.lua`,
`thread_admission.lua`, `admit_thread.lua`, `invoke_check.lua`.

**Commands.** `make test` (pinned runtime, all suites); the destination
suites alone need the thread test support:
`SUITES=hive,threads python3 tests/managed_launch.py` is not the runner
for them, use `make test`. Capability flags: `bee.threads:capabilities`
reports `cross_node_send = false`; no approval or thread capability across
nodes is reported true, and none is enabled by this handoff.

### Native sender identity

Bee uses native `message:from()` to authenticate the sending actor. Remote
supervisors must match the established peer PID and incarnation; naming lookup,
challenge exchange and host-selected admission determine which supervisor is
accepted. A PID supplied inside a payload establishes no identity or authority.
Supervisor replacement retires its pending routes. Replies must match the
selected peer and pending request before their deadline.

The retained-desktop bridge admits only its explicitly configured native client
nodes on the protected client host. It monitors the exact admitted client actor;
native EXIT triggers attachment revocation while applications remain retained.
Receipts remain sender-qualified, deadline-bound and session-fenced. Bee does
not inspect native connection handles or require a Lua `Message:ingress()` API.
Native transport authentication and remote process monitoring remain runtime
responsibilities; process-monitor acceptance is still required.

Receiver-local typed listener filtering is implemented in [runtime PR #718](https://github.com/wippyai/runtime/pull/718), pending review and release:
`process.listen(topic, {message = true, type = T})`. It validates incoming
map payloads before delivery while retaining the native sender. It provides a
data-shape guarantee, independent of operation authorization. The checked body is available through `message:data()`. This option is
not yet supported by Bee's release pin; [Go-Lua PR #44](https://github.com/wippyai/go-lua/pull/44) supplies the required static inference.
Bee source now uses this option for its request, reply and hello listeners with
receiver-local aliases over the existing protocol types. Domain decoders still
check exact fields, limits and protocol revisions. The isolated integration
runtime combines #718 and #717 at `22f444cf2c`, with no runtime patches.
Its production lint passes (302 entries), and the supervisor suites pass 39/39.
This is source integration evidence, not a released runtime or launch claim.

Public desktop admission, auto-attachment and remote Terminal remain separate gates.

### Retained desktop acceptance fixture

`make hive-desktop-admission-check` stages the actual retained desktop owner with
explicit native client-node permissions. The compiled native-client variant uses
`BEE_NATIVE_DESKTOP_CLIENT`; its physical wrapper additionally selects the helper
through `BEE_NATIVE_DESKTOP_PHYSICAL_BINARY`. The physical path has passed shell
input, F12 with the same shell, resize and bounded detach with terminal settings
restored. It requires the candidate runtime's terminal read/control isolation.
It does not activate a public client command or allocate additional desktops.
Desktop calls require a valid, unexpired deadline. The owner caps its pending
work and receipt lifetime at thirty seconds, even when the supplied deadline is
further ahead; it never extends an earlier deadline.

The fixture also accepts an optional remote owner through these test-only settings:

- `BEE_DESKTOP_SSH`: explicit SSH destination, used only for staging and cleanup.
- `BEE_DESKTOP_REMOTE_RUNTIME`: absolute path to the selected executable on that host.
- `BEE_DESKTOP_HOST_ADDRESS` and `BEE_DESKTOP_CLIENT_ADDRESS`: literal bind/advertise IPs.
- `BEE_DESKTOP_REMOTE_STAGE_PARENT`: optional parent for the disposable owner directory.

The remote fixture requires Linux. It uses the same native mesh, ephemeral signing
keys and TLS verification, with both selected IPs in the test certificate. All
application stores stay in the disposable owner directory. Cleanup checks the
process executable, working directory and start time before stopping it, and
preserves the directory on an identity mismatch. No installed runtime or
application database is replaced. The physical path passed against `100.70.10.28` on 2026-09-09 using the
committed dispatcher candidate `944736c999`: owner-only file verification, shell
input, same-shell F12, resize and bounded detach with terminal settings restored.
Evidence: `/tmp/bee-hive-physical-desktop-lan-cap.log` (42.35 seconds). This used
explicit fixture enrollment; public remote enrollment remains unimplemented.

An owner-only file supplies a separate shell-location assertion to the physical
fixture. The separate `BEE_NATIVE_DESKTOP_PHYSICAL_CRASH=1` branch passed on
`100.70.10.28`: SIGKILL without detach, fresh-process rejoin to the retained shell,
and bounded detach with terminal settings restored
(`/tmp/bee-hive-physical-desktop-lan-crash.log`, 41.75 seconds). This proof reused the same client membership and internode ports; automatic-port
rejoin is a separate pending gate. The test driver
restores raw-mode residue after SIGKILL; a killed process cannot restore it itself. Client-process crash/rejoin and remote actor EXIT with a still-live
transport are distinct gates; an explicit detach or a connection-loss proof does
not establish the latter.

The replacement crash fixture now uses a different explicitly enrolled client
identity/key after SIGKILL and native automatic ports on both starts. This passed
against `100.70.10.28` in `/tmp/bee-hive-physical-desktop-lan-crash-fresh.log`
(53.28 seconds). No seed-port arithmetic remains in the compiled helper. The
same-name membership reincarnation failure above remains separate; public dynamic
enrollment and live-transport actor EXIT are still unfinished.

## Local application catalog reads (candidate)

The candidate `bee.desktop:catalog` process operation reads the retained display
identity catalog for this local Bee. Its input is an empty object, addressed to
the `bee.desktop` owner on this node. It uses the existing Hive Call/Reply
correlation and deadlines and the same bounded retained catalog bridge as native
listing. There is no additional database reader or catalog service process.

The protected application admission binding grants `catalog_read` only to Hive
Manager. The broker publishes a complete bounded list of its live admitted app
PIDs through the workspace host and retained supervisor. Each receiver accepts
only its exact owner in this chain; the Hive supervisor additionally requires
PIDs on the retained supervisor’s actual native node. The local-only routing
label `local` is not used for this comparison. This state is private to the current execution and is never
saved or represented as a human identity. Closing the admitted app removes it
from the list. A pending response rechecks permission before releasing data.

The app calls its local supervisor, which derives the workspace and catalog
owner from its own state. The reply contains `owner_execution` and workspace/
display identities only. It carries no mounts, controller identities, credentials,
or attachment grants. The directory validates all nested fields and array bounds;
missing occupancy remains unknown. Authorization failure, malformed output and
unavailability do not appear as an empty catalog.

This operation has no native attachment permission and does not enter the native
client allowlist. Remote catalog reads and connecting from Hive Manager remain
unimplemented. Remote visibility will require destination admission through the
established supervisor relationship. There is no new runtime API, actor
impersonation, persistent PID permission, or metadata-granted authority.

Candidate acceptance: `make native-hive-catalog-check BEE_BINARY=...` exercises
the real manager and two physical clients; the installed pre-catalog build
reproduces the unavailable path. The candidate passed 535 unit tests,
source/pack architecture and app checks, and native catalog, connection,
client and transfer checks. A subsequent local-only PID correction passes
`make hive-reader-check`: an actual actor is admitted from its supervisor’s
native node, a foreign-node snapshot is refused, and revocation fences an
in-flight response without granting native control. Reverting the correction
makes that focused test fail on the legitimate local reader. Rebuilding and
native acceptance of that final correction remain pending; it is not installed.
