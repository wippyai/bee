# Hive startup

Implementation in progress. Bee's public launch remains local. The native build
manifest now includes a runtime listener patch; pairing, machine discovery,
project-host reuse and remote Bee admission are not implemented. Do not document
the proposed commands below as available commands.

The [Hive boundary proof](HIVE_POC.md) records current trust/topology constraints
and the experiment sequence. The boot test preloads peer keys and the runtime
eagerly connects members; it does not establish dynamic seed enrollment or
on-demand peer connections.

The manifest also includes a native application launch hook. One compiled
component may implement `application.LaunchPreparer` to select state or handle a
setup command before directory creation, environment binding, locking and bundle
seeding. Its request carries the working directory, application/module identity,
operation and copied arguments. Explicit state selection wins; staged update
subprocesses use direct explicit-state runtime execution without preparing again.
Cleanup and registry-history ownership have regression tests. Bee's SQL setup
catalog and unshipped selection adapter were removed in favor of minimal per-user
configuration. A replacement adapter and public setup commands remain absent. This is a
native host API, not an application registry capability. The contracts live in
`api/application`; the executable package retains aliases.
The patch also exposes `application.WithStateLock` for handled native setup:
it shares launch/update exclusion, requires an existing state directory, and
releases the lock when the setup callback fails. It does not validate application
contents or grant an actor access to them.

## Native enrollment integration

The candidate trust controller and its verification are recorded in
[native trust research](../runtime/research/TRUST_OWNER.md). It is not in the
build manifest. Keep the following boundaries when connecting it to Bee:

1. `PrepareLaunch` reads protected machine configuration and selects startup
   configuration before opening registry or application state. It preserves
   literal application arguments and explicit-state precedence. An unconfigured
   machine selects local mode and opens no mesh listener.
2. A compiled Bee component depends on Cluster. During `Load`, it obtains the
   native trust owner and installs the authoritative peer set before `Start`.
   This dependency path has a real discovery test; another boot-hook mechanism
   is unnecessary. No Lua or registry entry receives this native handle.
3. Enrollment redemption commits its own consumed-invitation record and distinct
   machine identity before announcing success. Runtime trust changes are an
   application of that durable decision, not the durable decision themselves.
   After a crash, reload the authoritative set; never infer trust from gossip.
4. Supervisors separately advertise workspace owners and admit operations.
   Transport trust does not confer a role, operation grant or Terminal session.
   Native session traffic keeps its existing recipient-bound capabilities.

The machine owner still needs protected persistence, redemption and local host
discovery implementations. The launch adapter must not become a second registry
store, workspace database, message router or per-workspace runtime allocator.
These steps describe the integration boundary, not available setup commands.

### Remaining native activation seam

The two-runtime service fixture now proves static `process.service.input` and
`lifecycle.security` startup of the actual Hive supervisor. Protected machine
configuration still needs a production path to supply that input. Native
component `Start` runs before registry entries load, so it cannot assume the
Lua process factory, host or policies exist yet.

An isolated native boot proof now verifies a native registry listener that
supplies an in-memory service configuration during the existing registry
transaction. A declarative entry would identify activation intent; the compiled
host would select the actual input and permissions from protected configuration.
Credentials would not become entry data. The normal supervisor would retain
dependency ordering, restart and shutdown ownership. Root booted current Hive
source through the runtime's actual component loader and registry transition:
enabled mode registers the real supervisor on its protected host, disabled mode
registers no activation service or supervisor name, and a foreign activation
entry ID is refused. These checks pass under the race detector with bounded
runtime shutdown. Disabled mode also exposes no native cluster trust controller;
this is not a network-traffic measurement.

The reusable component now lives in
[`native/hive/service`](../native/hive/service/README.md). It copies bounded host
input, requires explicit host-selected policies when enabled, validates empty
activation data and uses native transactional remove/register for replacement.
The native lifecycle requires the process host independently of entry metadata;
otherwise metadata removal allows a race with host startup. Actual boot,
replacement, pending-replacement rollback and strict staged Lua checks run through
`make -C native hive-service-check WIPPY=/path/to/reviewed/wippy`. The build manifest
does not select the component. No production activation entry or public launch
wiring is installed yet.

The component currently supplies a startup snapshot of configured node IDs.
Both the native component and the Lua supervisor retain that snapshot; changing
a protected file does not update a running supervisor. Public enrollment must
apply its committed decision to transport trust and supervisor peer admission
before reporting the peer usable. Dynamic peer configuration therefore remains
an integration requirement. Do not infer it from native `TrustPeer` alone or
replace the allowlist with unverified gossip membership. Opening another
workspace on an existing runtime is separate from enrolling a new runtime node.

### Protected activation and governed changes

The compiled activation boundary must remain outside ordinary runtime edits.
Editable activation intent cannot select trust keys, the supervisor's identity,
its host or its permissions. Protecting the activation entry alone is insufficient:
the selected supervisor code, policy entries and their dependency closure also
belong to the protected maintenance boundary. Otherwise an edit could preserve
the activation ID while replacing the authority it starts.

Future runtime changes must use the governed publication and activation lane in
[registry extensions](REGISTRY_EXTENSION.md), including overlays, tool-driven
edits and self-edit. A decision binds the exact candidate and expected base
revision; changing either requires renewed validation and the applicable
decision. A candidate cannot replace the code enforcing its own admission.
Protected native changes require a separately authorized maintenance/restart
path. This is a design requirement, not a claim that Bee already implements
Keeper's governance or a runtime publication service. Native Terminal still has
OS-user authority; these runtime boundaries do not sandbox that account.

Core components and shared applications may both be registry entries, including
Hub-provided entries. Ordinary application entries remain editable and services
project or execute their admitted revisions. Storage location and package origin
do not determine protection; the authority an entry implements does. Registry
overlay retains its native runtime meaning and participates in the same governed
change boundary, rather than becoming a separate source of permission.

Do not treat a manually signalled registry-ready flag as activation evidence.
Do not allow out-of-transaction service registration merely to avoid the boot
ordering problem: that changes lifecycle and rollback semantics. The earlier
isolated bridge prototype did not start the actual supervisor in its phase test
and does not establish this integration.

Live service reconfiguration also needs an execution-level proof. In the current
candidate runtime, the process-service manager replaces its stored configuration
and emits `ServiceUpdate`, while the supervisor command handler accepts register,
remove, start and stop. Its `ServiceUpdate` emission is a status notification;
there is no matching command case applying new lifecycle settings. The manager
unit test checks event emission only. Do not claim that updating service input
or lifecycle policy reconfigures a running supervisor without proving the actual
replacement, rollback and permission boundary.

The candidate runtime separately supports remove-and-register replacement of
the same service ID within a lifecycle transaction. Its three
`TestSupervisor_SameIDReplacement*` race tests pass: replacement uses a fresh
controller, respects required dependencies, preserves the old controller when
stop fails, and retains the new controller after a failed new start. This is
supervisor-level evidence; it does not prove a Bee native listener, live peer
updates or public launch. It is the replacement mechanism to evaluate before
introducing an out-of-transaction registration API.

Listener validation must not call the main registry's `GetEntry` during a
transition. A real boot review of the reusable draft reproduced a lock cycle:
`LoadState` holds the registry write lock while waiting for the listener, and
the listener's required-resource check waits for that registry's read lock.
Use the native dependency/lifecycle contracts and subsystem-owned resource
resolution instead. A committed snapshot would avoid that lock but would not
describe the candidate being activated, so it is not a substitute for candidate
validation. The failing draft remains isolated; this is not a production change.

## User contract

Enable a Hive once on a machine. After that, ordinary `bee`, `bee codex`,
`bee claude` and `bee agy` launches use the saved Hive selection. The user should
not choose ports, copy long keys for every project, or become familiar with Raft
configuration. A fresh installation stays local until Hive is enabled.

The required public setup is `bee hive init` on the first machine, which prints
an invitation, and `bee hive join <invitation>` on another. `bee hive key` mints
a later invitation. These commands remain unimplemented. The detailed
[topology and launch contract](HIVE_TOPOLOGY.md) distinguishes machine enrollment,
runtime nodes and workspace ownership. Joining records trust and discovery
information. An invitation must be bounded in lifetime and use, and accepting it
must identify the Hive being trusted. LAN discovery finds candidates; it never
authorizes membership. Do not silently join a stranger's Hive on the same LAN.

After setup, opening a project selects its existing workspace host or starts it.
Opening another client must attach to that host instead of starting a competing
writer. Failure to locate the owner is not permission to create a second owner.
The current application-wide startup lock is not sufficient for this contract.
The next slice's configuration, existing-state preservation and host reuse rules are in
[native launch state](HIVE_LAUNCH_STATE.md). These remain proposed until the
packaged-executable acceptance gates pass.

## Ownership

| Owner | Responsibility |
|---|---|
| Native Bee launch | CLI setup, selecting the project and saved Hive, starting or locating the local host before desktop startup |
| Machine rendezvous | Per-user local discovery, host startup serialization and enrollment credentials |
| Native Wippy mesh | Bound listeners, peer transport, membership and native names |
| Workspace host | Workspace identity, app execution, persistence and client admission |
| Desktop client | Its own layout and presentation of admitted workspace views |

The rendezvous must not become an alternative actor router, replicated registry
or owner of workspace data. Direct native mesh routing remains the transport.
Machine pairing grants only the configured membership authority; it does not
implicitly grant application launch, registry edits or terminal control.

### Workspace-owned services (proposed)

A workspace may expose a service such as a Proxmox provisioner. Its supervisor
advertises a bounded description: owning workspace, service identity, supported
contract versions and discoverable operations. This is a discovery projection,
not a grant. Private services need not be visible to every member.

Supervisors use native mesh addressing to contact the owner and negotiate access.
The owner authenticates the requesting actor and applies its own policy to the
requested operation and resources. A caller-supplied workspace or actor ID is
not proof of identity. Any delegated grant must retain its audience, scope,
lifetime and revocation boundary; admission to one service does not authorize
another. Reconnection must not revive an expired grant.

For example, discovering a provisioner allows a caller to request an environment;
the provisioner decides whether that caller may create it and under what limits.
Creating a machine does not automatically enroll it in Hive or authorize its
applications. Enrollment and service access remain separate owner decisions.
Requests need correlation and explicit completion; an uncertain provisioning
result must be queried or retried with owner-supported idempotency, never blindly
repeated. The desktop can display these operations but owns none of their authority.

Implement this through native actors, names and typed contracts. Do not introduce
a second service router or treat replicated registry metadata as authorization.
Service advertisement and negotiation are not implemented by the boot patches.

Keep machine, runtime node, workspace, application instance and client connection
identities distinct. A project path selects a workspace; it is not a portable
workspace identity. Each runtime needs its own registry/deployment state; its
workspace hosts need separate owned workspace storage, not separate runtime
processes. Workspace-specific activation over shared base definitions remains
to be proved. Preserve the existing workspace
and its migration ledger when introducing project selection; do not silently
replace the user's current desktop with a fresh empty database.

The pinned runtime configures relay identity through `relay.node_name` and gossip
identity through `cluster.name`. Native launch must supply the same stable node
identity to both. Setting only the latter leaves Raft using a different relay ID:
membership can converge while bootstrap refuses its voter list. The boot probe
sets both explicitly; this must not become a user-facing pair of settings.

The machine rendezvous may retain its local endpoint and seeds in protected
per-user state. Local clients discover it without manually entered ports. On the
LAN, discovery plus saved seed hints locate an authenticated entry point. An
unavailable discovery mechanism must produce a useful diagnosis and permit an
explicit address fallback. General NAT traversal is outside this first LAN slice.

## Ports and lifecycle

Bind before publishing an endpoint and retain that listener throughout its
lifetime. Port zero means OS allocation. Do not hash project names into ports or
scan, release and later reacquire an apparently free port. Explicit fixed ports
remain available for administrators, with a visible bind failure on conflict.

Wippy membership needs a TCP/UDP gossip endpoint; internode traffic uses its own
TCP endpoint. Native Raft rides internode transport and needs no additional
listener. Only the small selected coordination group runs Raft servers. Ordinary
project nodes use the runtime's client role.

The listener patch changes both boot and standalone stack startup to start the
internode service, publish its actual endpoint, then join membership. Internode
subscribes before joining so initial peer events are observed. Failed membership
startup tears down both services. The service cancels its reconciliation loop on
stop. Explicit port zero now reports the bound port with or without AutoPort;
AutoPort with zero goes directly to OS allocation. An explicit starting port
retains the existing range/fallback behavior. The standalone stack no longer
substitutes 7946 for zero; normal boot's omitted gossip-port default is unchanged.

Graceful restart can retain a node identity at a different endpoint. Abrupt
death and partitions still obey native membership's failure/reclaim semantics;
the current test does not establish immediate recovery from either. Do not erase
those protections to make a demonstration reconnect sooner.

## Acceptance sequence

1. Native listener ownership, concurrent authenticated startup and graceful
   restart at another port. The patch includes a twenty-node loopback test that
   checks live port ownership and all nineteen authenticated peer connections per
   node; it also occupies a stopped node's old internode port before restarting
   that identity. Three consecutive race-enabled runs passed. Failed-join
   acceptance checks release of both TCP listeners and the gossip UDP socket.
   The CLI probe passed with twenty client-role runtime processes from temporary
   fixtures, strict Lua and separate state, checking membership and assigned
   endpoints. `make hive-runtime-check` now passes with twenty processes including
   three Raft servers, growing from one initial server, with a common observed
   leader. A separate simultaneous three-server bootstrap also passes.
   Earlier server runs converged membership but failed
   leadership on both the patched and reference runtimes. Verbose tracing exposed
   mismatched relay/gossip identities in the fixture and a concrete bootstrap
   refusal (`node is not a voter`). Setting both identities resolved those runs. Retain
   the server gates; client-role membership is not a substitute for readiness.
   Neither test is Bee desktop or LAN acceptance.
2. Saved per-machine setup and project selection through the actual packaged
   `bee` executable. Prove concurrent starts select one host per project, state
   isolation, existing-workspace migration and repeated client attachment.
3. Pair a second machine, then launch projects without entering network options.
   Prove trust rejection, expired/reused invitations, host restart and recovery
   when a saved endpoint changes. Keep secrets out of logs and repository files.
4. Admit an actual remote Bee client and open Native Terminal on the destination
   host. Prove denied unauthorized actors, independent local navigation while a
   peer stalls, fresh attachment grants and retained workspace identity.
5. Add Hive Manager and a compact workspace selector over these owner operations.
   Prove both headless and desktop launch paths before calling Hive ready.

Transport success alone must not be presented as completion of steps 2–5.
See [host/client ownership](CLIENT_HOST_SPLIT.md) and
[workspace attachments](WORKSPACE_ATTACHMENTS.md) for the existing admission and
identity boundaries. Runtime naming/Raft review remains a separate workstream.
