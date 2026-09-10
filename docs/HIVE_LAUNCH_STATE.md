# Native launch and local configuration

Design for the next Hive slice. Native listener and launch-hook prerequisites
exist; public setup, host reuse and remote enrollment remain unimplemented.
The rejected SQL setup catalog and its unshipped adapter have been removed.
No workspace database or applied workspace migration was changed.

## Current integration boundary (2026-09-10)

Workspace ownership conflict selects a client node automatically once the public
launcher is wired. The existing owner retains workspace stores and applications;
the new invocation obtains supervisor admission and its own presentation state.
The global binary still reports lock busy today.

The shared `native/client/hive` binding now uses native sender identity and a
protected supervisor lookup, with replacement fencing and no automatic replay.
It does not use an ingress API or connection credential. Its `Done()` channel
means caller-owned actor lifetime only. Historical candidate notes below about
pinned connection evidence describe the superseded implementation and must not
be used as the current API. See [the binding contract](../native/client/hive/README.md).

Remote invitation redemption and live host admission updates remain separate
integration gaps. Same-account rendezvous enrollment does not implement remote
machine enrollment. Neither discovery nor transport membership grants Terminal,
workspace or registry operations.

## Ownership

Each workspace owns its application state, application processes and client
admission. Many workspace hosts may share a runtime and its base registry;
workspace-specific activation remains an owner-scoped design requirement, not
an already isolated registry per host. The journal and client layout retain
their existing separate owners. See [topology](HIVE_TOPOLOGY.md).

Central per-user configuration serves the same kind of purpose as Wippy's
credentials/configuration area. It holds machine identity, the selected Hive,
protected credential references and remembered workspace locations. It does not
need another SQL database, a setup migration ledger or replicated application
state. Configuration references describe where to connect; they grant no access.

Running hosts are discovered through supervisors and native mesh names.
Persisted PIDs and ports are hints at most, never proof of a live owner.
The destination supervisor authenticates clients and chooses their scopes.

## Launch behavior

A fresh installation remains local-only. Enabling Hive once saves the selected
configuration; subsequent ordinary `bee`, `bee codex`, `bee claude` and
`bee agy` launches can reuse it without repeated keys or manually chosen ports.
The caller's literal application arguments remain intact.

A project directory locates its workspace; it is not the workspace's durable
identity. Canonicalize directory aliases for local lookup. Do not silently infer
a Git root or merge intentionally separate nested projects. Moving a workspace
changes its location, not its identity.

A remembered runtime state directory identifies registry/deployment storage,
not a workspace database. Several workspace IDs may point to the same runtime
state directory. Their live hosts still need distinct workspace database
bindings and destination-owned admission. Several project directories may also
select one workspace. Neither relationship requires copying a registry or
starting another runtime. The saved index is a location hint; startup must
verify the requested workspace identity through its owner before attaching.

Explicit `--state-dir` keeps precedence. Preserve the existing default state
directory when introducing project lookup. Remembering that directory in central
configuration must not move, copy or rewrite its registry or application stores.
Corrupt configuration is a visible error, not a reason to recreate identities
or silently launch a blank replacement workspace.

Configuration writes should be bounded, owner-only and atomically replaced.
Serialize read-modify-write operations so concurrent setup commands cannot lose
each other's changes. Secrets stay out of logs and exported workspace definitions.
Use the existing credential conventions where applicable.

### Implemented persistence primitive

`native/internal/privatefile` supplies the protected file mechanics. Its
`ReadModifyWrite` operation validates the current file while holding a stable
companion-file lock, then publishes a bounded replacement atomically. A rejected
transform leaves the document unchanged. Existing insecure or malformed identity
files are not repaired or replaced. The machine identity owner uses this helper
without changing its identity format or `.identity.lock` name.

`native/hive/config` now supplies a versioned machine configuration store over
that primitive. It holds an optional enrollment reference and a bounded index of
workspace IDs, project directories and runtime state directories. Concurrent
updates compare the expected revision under the file lock; stale writers receive
a conflict. Strict decoding rejects malformed documents without replacement.
Several workspaces can share one runtime directory. See the
[store contract](../native/hive/config/README.md).

The public launcher does not consume this store yet. Enrollment credentials,
invitation redemption and public setup commands remain unimplemented. The native
supervisor activation component still receives explicit host-selected
configuration rather than reading a saved machine profile.

Linux race tests and vet cover the helper and identity consumer through
`make -C native check`. `make -C native privatefile-windows-check` compiles the
Windows tests and runs vet; it does not execute Windows tests. Directory sync on
Windows remains unverified. Protection is against other OS users, not other
processes running under the owning account.

### Commit and activation boundary

Saved enrollment and usable connectivity are separate outcomes. Setup must
commit the authoritative enrollment before applying it to a running runtime.
An activation failure must retain that committed decision and report the
incomplete activation, so a retry reconciles it instead of redeeming an invitation
again or manufacturing a new identity.

The native transport trust set and the Lua supervisor's admitted peer set must
both reflect that decision before setup reports the peer usable. The current
supervisor holds a startup snapshot; native `TrustPeer` alone does not update it.
The live application contract still needs implementation and verification.
Connection readiness is a further observed outcome, and grants no workspace or
Terminal authority by itself. Destination-owned admission remains required.

Startup must reconcile the last committed configuration after a crash between
commit and activation. Do not persist an `active` flag as proof of a live peer,
or roll back committed enrollment merely because the peer is temporarily
unreachable. A stale activation result must not override a newer revocation.

## Starting or reusing a host

Current ordinary launches still use the same per-user runtime state directory
regardless of the working directory. A second invocation therefore reports that
the application lock is busy. This is an unfinished reuse path, not a reason to
delete the lock or select another directory to bypass it.

The intended ordinary launch becomes a client node when the selected workspace
owner is already running. On the same machine this is automatic: ordinary `bee`
uses the protected same-account discovery/enrollment path, with no invitation or
new workspace store. Workspace ownership conflict selects this client path; it
does not grant access by itself. Verify the live owner and supervisor admission
before presenting its workspace. A stale hint, update lock or failed admission
must not start a competing writer. Client layout, tabs and reconnect targets have their own
writable store, selected automatically. Attaching a client must not acquire the
host runtime's exclusive state lock. Independent clients must not compete for one
client-store writer either. Explicit profile selection may reuse a saved client
layout only under its own ownership rules. The current fixture-selected client
database binding is not yet that automatic public profile allocation.

### Local physical client boundary under validation

The selected candidate is Wippy's native mesh, not a Bee socket service.
The abandoned `native/client/local`, `native/client/display` and
`native/client/owner` transport experiments and their test targets have been
removed from the source tree. They remain in Git history and were already absent
from the pinned native module. Public launch uses only the native mesh path;
prototype test results are not acceptance evidence for that path.

`native/client/mesh` enrolls an ephemeral physical client in a protected
same-account rendezvous directory, starts native loopback membership and
transport on automatic ports, and discovers the existing supervisor through
Wippy's EVENTUAL names. It uses a real native actor and the shared runtime TTY
surface transport. It opens no workspace database or registry history and does
not acquire the owner's state lock. The thin client holds an enrollment slot
lock; process death permits later reclamation without evicting live clients.
Loopback mesh transport does not enroll the machine into a LAN Hive.

`native/client/physical` renders checked native viewports and sends typed input.
Two separate OS client processes under PTYs pass native mutual-TLS rendering,
input, detach and retained-content rejoin checks. These proofs now use automatic per-execution same-account TLS credentials
and fixture grants. They do not prove Bee supervisor admission,
retained Terminal attachment, automatic first/second `bee`, or LAN operation.
See the [mesh client contract](../native/client/mesh/README.md).

The desktop actor and its layout store remain on the owner runtime. Physical
client exit need not destroy that desktop or its applications. Selecting an
independent desktop/profile, controlling one, and observing one are different
owner-selected operations; a discovery name or authenticated connection grants
none of them. Public profile selection and automatic allocation remain open.

The isolated runtime launch hook calls `LaunchPlan.Attach` only after the real
application-state lock reports busy, before deployment or application stores
are opened. It does not attach on arbitrary startup errors, base recovery,
updates or runtime tooling. Attachment failure is final; it cannot start another
owner or replay uncertain application input. Bee still needs to register its
actual owner/client composition with this hook.

The production gates remain:

- The runtime candidate now preserves authenticated immediate ingress and exact
  connection lifetime into Lua. The supervisor consumes and pins it, and both
  two-runtime TLS fixtures pass. This closes the message-evidence seam; it does
  not implement desktop grants or make an instantaneous live check atomic.
- Bind admission to the owner execution, request, recipient, selected desktop
  and connection. Native client replies now reject unavailable connections
  before enqueue and after queueing; this does not implement grant/session
  fencing or atomicity with disconnect.
- Wire host-owned certificate provisioning into actual owner startup.
  `native/hive/localtls` now provisions one protected, execution-scoped PEM
  bundle and `mesh.SameAccount` loads it automatically before enrollment.
  Actual physical clients use this path. The owner must enforce the returned
  expiry; public startup and renewal are not implemented. No LAN enrollment
  credential or PKI is provided by this local mechanism.
- Prove remote monitor installation and EXIT delivery, then owner cleanup of
  departed controllers. The isolated monitor proof currently fails after an
  accepted monitor and a delivered FIFO barrier.
- Wire first/second `bee`, test concurrent launch and crash/rejoin, then prove
  remote workspace discovery and a usable Bee Terminal on the LAN target.

No new Bee listener, alternate mesh, fake monitor receiver or fixture-issued
production grant can satisfy these gates. Coordinate shared runtime changes
through the [runtime takeover handoff](handoffs/RUNTIME_CLIENT_TAKEOVER.md).

1. Resolve the selected workspace location and query its supervisor.
2. Authenticate the endpoint and verify the destination workspace identity.
   A successful connection or saved PID is insufficient.
3. Reuse the existing host through destination-owned client admission. Discovery
   does not grant application execution, terminal access or registry publication.
4. If a local host must start, serialize startup and acquire the runtime's
   exclusive state lock. Uncertain ownership must not create a second writer.
5. Publish readiness only after the workspace owner and admission endpoint are
   ready. Use a fresh incarnation to reject stale startup and shutdown replies.
6. Release startup serialization once ready or failed. Client detach leaves an
   independently hosted workspace running; explicit host stop uses its shutdown
   protocol.

Use native actor routing after admission. Local rendezvous is discovery/setup
infrastructure, not a second message router. Each runtime host uses one stable
node identity for both `relay.node_name` and `cluster.name`. Hive endpoints bind
automatically before being advertised. The shipped local launcher binds no mesh sockets. The gated attachment candidate
uses native loopback sockets; LAN membership remains opt-in.

## Implementation gates

- The native configuration store passes concurrent-write and malformed-state
  tests. Still connect its caller to existing workspace locations and enrollment
  credentials without changing existing stores.
- Connect the native launch hook and verify actual packaged `bee` arguments,
  explicit-state precedence and local-only startup.
- Prove concurrent host startup/reuse, readiness failure, stale incarnations,
  client detach, host restart and exclusion of competing state writers.
- Prove two actual Bee runtimes and an authorized remote Terminal before exposing
  a workspace switcher or claiming Hive desktop support.

The native launch contracts live in runtime `api/application`. Shared exclusive
state locking lives in `application/statelock`, avoiding a dependency on the CLI.
`make -C native patched-check` tests native code against a clean runtime checkout
and the checksummed manifest patches using temporary module files. It does not
package local changes or install an executable.

Filesystem resources and thread subscriptions can proceed independently.
Their services own resource authorization and journal access; neither should
introduce another workspace identity scheme or host launcher.

### Native rendezvous candidate

`native/hive/rendezvous` publishes protected discovery hints for the native
owner after cluster startup while the application-state lock is held. The
execution ID, node, endpoints and signing key are checked again during client
startup. Hints do not authorize desktop access. The descriptor creates no
listener; native Wippy components own all transport sockets and their cleanup.
See the [rendezvous contract](../native/hive/rendezvous/README.md) and the
[client state](CLIENT_STATE.md) for current evidence and outstanding integration.


### Native Hive call binding and candidate acceptance (2026-09-09)

The isolated native client now uses `client/hive` to speak the existing
`bee.hive@1` Call/Reply contract over `mesh.Actor`. Calls have cancellable
serialization, one send, exact supervisor/request checks and pinned native
connection lifetime. A send without a validated reply returns an unknown outcome
with the operation and idempotency key; it never causes automatic replay.
Result values still require operation-specific desktop admission decoders.
A normally booted process-service fixture exchanges Lua success and denial
records, including empty grants tables. It grants no production desktop access.

The candidate runtime completed Bee's full `make check` sequence after fixing
packed `--host` selection in local runtime commit `699597ef70`. Earlier successful
prerequisites were retained when resuming the remaining targets. Evidence is in
`/tmp/bee-supervisor-native-ingress-repo-check.log`,
`/tmp/bee-runtime-pack-host-headless.log` and
`/tmp/bee-supervisor-native-ingress-repo-resume.log` (successful completion).
This covers the current local source/pack foundation, not the installed binary,
public auto-attachment or the remote Terminal gate.

### Desktop owner bridge under validation

`bee.hive.desktop:owner` is an optional library inside the destination Hive
supervisor. It retains native connection evidence there and asks the existing
local retained-desktop supervisor for recipient-bound mounts. Its pure protocol
uses the existing Hive Call/Reply envelopes for list, attach and detach; it does
not introduce a listener or transport. The bridge depends explicitly on the core
retained-desktop interface and is not an independently portable Hive module.

Only trusted host configuration can select an execution, expiry and allowed
native client nodes. The desktop-host policy is an additional explicit grant;
transport authentication or registry metadata alone does not admit a client.
The native service accepts this optional host configuration; public launch does
not supply it.
The current owner exposes its one selected workspace and desktop. The nested
result retains both identities; it does not equate a workspace with a node or
claim dynamic multi-workspace activation.

Strict production lint and the existing native supervisor/service regressions
pass with this optional bridge disabled. The enabled Lua client-role proof below
also passes. Mount revocation on connection loss, compiled physical-client rejoin
and the LAN Terminal remain required proofs before public activation. Pure decoders in the supervisor fixture do not grant
access to desktop processes or stores.

The architecture check permits only the bridge's two named core interfaces and
walks their complete import closure, requiring value libraries without runtime
modules or security declarations. Ordinary Hive entries retain their existing
closed dependency rule. A pending desktop request retains its original reply
correlation: another correlation with identical input gets `BUSY`, and reuse of
its key with different input gets `CONFLICT`. Neither dispatches another core
operation. Exact duplicates of the original correlation await its completion.
These pending-request cases remain part of enabled bridge acceptance.

Native `service.Config.Desktop` now carries the optional host grant into Lua:
execution, expiry, explicit allowed nodes and optional initial application. It
requires enabled service configuration plus the exact desktop-host policy,
clones the node list before storing or exporting it, and adds `bee:workers` to
native service dependencies. The default remains nil. This is not yet supplied
by public launch. Service configuration tests and actual activation regressions
must pass separately from enabled desktop attachment acceptance.

For fresh same-account clients, the host can now supply the optional unpublished
`Desktop.ClientPolicy`. The service installs it in a forked, sealed supervisor
frame; a boolean `local_clients` selects the corresponding Lua permission check.
The desktop owner passes only the actual native sender to
`security.can("bee.desktop.local_client", sender)`. It still validates operation,
execution, lifetime, workspace, session and viewport grants normally. An empty
static allowlist requires this host-selected policy. Neither activation metadata
nor native mesh membership grants desktop access. This is component wiring;
public startup and a real fresh-client desktop acceptance remain unfinished.

Enabled owner proof (2026-09-09): `TestHiveDesktopAdmission` passes with two
actual native runtimes and disposable TLS/enrollment. The client discovers the
owner's native supervisor name, obtains its qualified workspace/desktop catalog,
attaches a recipient-bound retained desktop mount, executes a Terminal command,
rejects a foreign session, detaches and rejoins the same shell with its variable
intact. The first passing run took 31.616s. This is a Lua client-role process on
`bee.client:native`, not the compiled physical client or public `bee` startup.
`make hive-desktop-admission-check` runs the fixture. The extended stale-mount,
foreign-workspace and observer input checks pass with race checking and vet
(31.010s including the Go race shutdown interval). Connection
loss, crash/rejoin, public local auto-attach and LAN acceptance are still required.

Host configuration decoder failures now include the invalid field's requirement;
for example a local-zone timestamp reports that `expires_at` requires canonical
UTC with milliseconds. The native configuration encoder supplies UTC explicitly.

The bridge also monitors admitted client actors. Native connection liveness alone
cannot retire an actor that exits while its runtime stays connected. Actor EXIT
starts the same revocation path as connection loss; completed cleanup removes the
bridge record and monitor. The retained core continues to own actual mounts.
A new acceptance extension covers client crash, fresh-actor rejoin and more than
64 attached actors exiting without detach, to detect retained-record exhaustion.
Its passing evidence is still pending; the previous explicit-detach proof does
not establish actor-loss recovery.

The actor-loss extension currently fails: a fresh actor is refused because the
old controller remains after a crash. The independent native monitor gate also
fails on the candidate runtime: remote monitor registration succeeds, an ordered
barrier confirms delivery, but actor completion emits no EXIT while transport
stays alive. Runtime monitor delivery must be fixed before claiming crash recovery;
connection liveness or the passing explicit-detach test does not establish it.

A separate compiled Go client-role process now passes the actual owner fixture:
native name discovery, `hive.NewDesktop` list/attach/detach, native viewport input,
actual Terminal output, same-shell rejoin and stale-input denial (31.145s).
The test selects it with `BEE_NATIVE_DESKTOP_CLIENT`; its disposable enrollment
comes from the parent harness. It does not use a Lua client, physical stdin or
the global launcher. A race-instrumented client rerun is in progress. This variant
keeps the failing remote actor-EXIT/crash proof separate rather than claiming
explicit detach establishes it.
