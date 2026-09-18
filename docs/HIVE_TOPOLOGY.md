# Hive topology and launch contract

Design under validation; these commands are not implemented. The first proof is
[the Hive POC](HIVE_POC.md). No central database is part of this design.

## User flow

| Invocation | Intended behavior |
|---|---|
| `bee` | Resolve this project's workspace, start or reuse its host, attach a desktop client. |
| `bee codex` | The same operation, opening the registered handler fullscreen with literal arguments. |
| `bee start` | Start or reuse this workspace's headless host; remain in the foreground so a service manager or `&` controls background execution. |
| `bee hive init` | Explicitly create the first Hive and enroll this machine. |
| `bee hive key` | Mint an invitation using this machine's enrollment permission and reachable seed endpoints. |
| `bee init <invitation>` | Enroll a new machine once; subsequent ordinary launches use saved configuration. |

Fresh installations remain local-only. Starting another workspace on an enrolled
machine requires no copied keys, fixed ports or separate enrollment ceremony.
A repeated start must resolve the existing owner, not open its SQLite files again.
A desktop client detaches independently of a headless host. The current local
coordinated quit behavior needs an explicit compatibility decision during this
launch migration; do not silently change existing workspace shutdown semantics.

## Identities and owners

A Hive identifies a trust domain. A machine enrollment owns a protected local
identity and its permitted participation. Each native runtime has a distinct
node identity. Each workspace has an independent durable identity and an exact
live owner/incarnation. Each client connection has its own admission and layout.

Nodes may have friendly names such as `forge` or `laptop`. These are display and
selection aliases, not authentication identities or workspace IDs. Renaming a node
must not change workspace identity or invalidate saved application references.
Ambiguous names require qualification; install order or discovery order must
never silently choose a destination.

For one workspace on a node, the UI may present one compact label. With multiple
workspaces it expands to node then workspace. This is presentation shorthand,
not a merged ownership model: every application target still retains both its
workspace identity and its current admitted destination.

A machine can run many runtime nodes. A runtime must support many workspaces
with explicit separate database bindings and owners. One workspace must not
require another runtime, mesh membership, listener set or native toolchain copy.
An isolated runtime per workspace is an optional deployment choice, not the
default topology contract.

Workspace is an isolation/persistence boundary, not a synonym for project folder.
One workspace may cover many folders, and users need not create a workspace for
every repository. Dormant workspace records must not require a running broker,
open database connection or per-workspace polling timer. Starting a host activates
that workspace; services with background work explicitly keep it active.

Current code can select a host's application database resource, but catalog
admission uses the shared `bee:application_admission` entry. Multiple application
databases therefore do not establish independent registry configuration. Native
registry contexts exist; separately scoped resolution/publication must be proved
before claiming independent same-ID application versions in one runtime. Shared
base definitions may be reused, while workspace-specific activation remains an
owner-controlled operation. Do not duplicate an entire runtime merely to avoid
designing this boundary.

Acceptance must include two workspace hosts in one runtime with separate stores,
cross-workspace operation denial and independent client targets, followed by a
dormant-workspace resource measurement. A two-runtime Terminal proof alone does
not satisfy this many-workspace requirement.

One small per-user machine service is the proposed local rendezvous and enrollment
owner. It locates/starts local hosts and shares discovery work. It does not own
workspace SQL, application definitions, filesystem roots or application state.
It is not a second actor-message router. Its crash must not imply that every
running workspace has stopped; reconstitution must authenticate surviving owners.
Whether it embeds a native runtime or attaches through a native component remains
to be established by the POC, rather than hidden behind a new transport.

Local configuration records enrollment and remembered locations atomically in
protected files. Live presence is discovered/reconciled, not a durable SQL catalog.
A project's launch directory selects a workspace; additional authorized filesystem
roots and provider entry points remain workspace-owned resources.

## Two credential levels

An invitation is a bootstrap credential, not the permanent identity of every
node. It contains a version, Hive identity, authenticated issuer identity, expiry,
join capability and candidate seed endpoints. Redemption authenticates the issuer
and provisions a distinct machine credential. Nodes use distinct identities under
that enrollment; copying one node's private key to every project is not enrollment.

Only a machine granted enrollment authority may mint invitations. A single-use
invitation needs an authoritative redemption owner and a durable consumed record;
a stateless signed token alone cannot guarantee single use. The simplest initial
option pins redemption to its issuer and fails visibly if that issuer is offline.
Do not introduce consensus storage merely to make invitation redemption available
from every node. Revocation and established-connection fencing require their own
native acceptance checks before claiming per-machine revocation.

Single use means one admitted machine identity, not one request or network
connection. Before attempting redemption, the joining machine persists its own
identity. Redemption proves possession of that key and binds the consumed
invitation to it in the issuer's durable record. An identical retry by that
machine returns the same enrollment result; a different machine is refused.
Losing the reply must not create a second identity or require minting a new
invitation. The issuer commits before replying. After joining, the machine
commits its enrollment before reporting setup complete or starting workspace
traffic. Expiry, revocation and permission changes still apply when replaying a
receipt; replay is not a way to recover revoked authority.

The current runtime requires shared membership authentication plus startup-pinned
peer identity keys. Seed enrollment requires a native trust integration seam;
metadata is not a replacement for it. Membership does not authorize workspace
inspection, application execution, filesystem access or registry publication.
Destination supervisors select those permissions separately.

## Addresses and topology

Invitation minting records endpoints of listeners that are already bound. It must
not allocate a port, close it and promise to reopen it later. Endpoints identify
transport, host and actual port; IPv6 addresses use proper host/port formatting.
They are hints, separate from the authenticated node identity.

Local rendezvous uses an owner-protected local endpoint. An exported invitation
must not use loopback as its only endpoint. LAN addresses, routable overlay-network
addresses and explicitly configured DNS names can be candidates. Do not assume
an RFC1918 address is reachable from the recipient, or exclude overlay addresses
merely because they are outside RFC1918. Link-local IPv6 scope identifiers are
machine-local and cannot be copied blindly into an invitation.

A multi-homed host may offer several candidates. Joining attempts them with bounded
concurrency/timeouts and verifies the expected identity at the chosen endpoint.
LAN discovery supplies additional candidates, never trust. Saved seeds can be
refreshed after authenticated contact. A remotely observed source IP is not proof
that unsolicited inbound connections reach an advertised port. General NAT
traversal and an Internet relay are separate future capabilities.

Native Wippy currently eagerly connects members. Sharing LAN discovery on one
machine will not by itself remove those connections. Measure CPU, sockets, traffic
and reconnection behavior before choosing between existing full mesh, on-demand
native links or fewer runtime hosts with multiple isolated workspace owners.
Do not introduce a Bee proxy mesh to hide a runtime limitation.

Workspace presence should publish changes and reconcile after reconnect. Include
owner incarnation and revision so delayed advertisements cannot revive old owners.
A lost connection means unavailable or uncertain, not deleted, and cannot cause a
client to launch a replacement remote workspace locally. The UI can project many
workspaces while preserving workspace identity on every application/tab target.

## Operation admission and direct sessions

Cross-machine operation establishment passes through the caller's supervisor and
the destination supervisor to the owning service. After admission, the service
may return an exact actor PID and an owner-issued session grant, or native stream
capabilities. High-rate traffic then uses native routing directly. Supervisors
need not relay every message or TTY frame.

A PID is an address, not a bearer credential. Keeping it undisclosed is not the
security boundary. Receivers authenticate the actual sender and enforce the
admitted audience, operation/resource scope and session lifetime. A session is
bound to the current owner incarnation; reconnecting requires revalidation and
must not revive revoked authority. Native viewport grants retain their existing
recipient binding and rights rather than being wrapped in a parallel TTY token.

Use existing registry contracts and typed consumer libraries for callable
operations where their semantics fit. Registry metadata may advertise the
operation's contract/version, owning service and presentation description.
Protected host bindings choose which implementations may be advertised and which
permissions they may request. Metadata and caller-supplied policy names cannot
authorize execution. Do not add a universal remote-capability entry kind before
proving that current contracts and metadata cannot express the needed boundary.

Traits, CLI handlers and eventual dynamic MCP tools adapt the same owner operation.
Enabling an adapter exposes a function; it does not grant permission to execute it.
A bound contract function may run under a separate execution PID in W1, so a
claimed original PID must never substitute for verified delegation or runtime
security context. The remote actor provenance gate remains required.

First-use approval identifies the verified requester, destination workspace,
operation and resource scope. Only an authorized approval recipient may answer.
An owner can allow once, for a session or under a remembered scoped policy.
Headless owners apply configured policy or return pending/denied; absence of a
UI is not consent. Correlated pending/allowed/denied/expired results return to the
requesting client. Repeated matching requests reuse valid grants without prompts;
expanded scopes require another decision. This is a proposed admission protocol,
not an implemented MCP or trait API.

The durable [approval subsystem](APPROVALS.md) defines owner-side decision storage,
concurrent-answer handling, deadline checks and recovery delivery. Existing live
application dialogs are not yet that authorization subsystem.

The next executable gate is a remote Terminal session established through that
boundary, followed by direct native viewport traffic, denied unadmitted access,
revocation and fresh admission after reconnect. It should establish the common
contract before adding more remote services or a new registry abstraction.

## Responsive client attachment boundary

Current remote viewport snapshots are cached, but attach, input and resize can
wait for a network reply. Native Lua yields during those operations; that does
not let the same presenter event loop process another tab or quit action.
`src/core/terminal/main.lua` currently invokes these operations directly.

Before production remote views, isolate network-waiting attachment operations
from presentation. The attachment execution must be the actual recipient selected
by the destination owner; do not pass a mount to a worker that lacks its audience
binding. Preserve renderer generation fencing and existing F12 revocation.
Choose the smallest actor split that proves local navigation stays responsive
while a remote operation stalls; do not assume a new asynchronous primitive is
necessary until existing actor/coroutine semantics are checked.

Input retains ordering and bounded capacity. Overflow is visible, never silent
keystroke loss. An uncertain remote input outcome is not retried automatically.
Resize may coalesce pending dimensions but reports failure, and snapshots may
coalesce intermediate frames. Connection loss preserves qualified tab identity
and last-known content with an unavailable state; it does not change destination
or make the frozen contents look live. Reattachment obtains fresh authority.

The native Lua engine already schedules coroutines with independent external
yields and channel selection (`TestProcessExternalYieldWithChannelSelect`,
`TestProcessConcurrentYieldsFromCoroutines`). A bounded per-view coroutine queue
inside the existing presenter is therefore the first candidate: it keeps
recipient identity unchanged and may avoid another actor/grant handoff. An
isolated strict-Lua two-runtime probe now stops the destination OS process after
mounting a real remote viewport. Resize remains pending in a coroutine while
the same recipient actor runs a timer and reports progress; resuming the host
completes resize and the existing Terminal checks. This establishes native TTY
yield isolation, not production presenter responsiveness. Prove continued local
input, queue overflow reporting, ordered delivery, stale completion fencing and
cleanup during F12 before choosing it for production.
