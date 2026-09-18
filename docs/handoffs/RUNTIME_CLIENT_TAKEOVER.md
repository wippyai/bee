# Runtime client integration takeover

On 2026-09-09 the user authorized Astra to take over the missing runtime client
integration and locate the existing PRs in `~/wippy/wippy`. The earlier wait for
another runtime owner is superseded. Preserve that owner's research and PRs;
this does not authorize enabling an unreviewed transport candidate.

## Verified starting points

- Runtime [#653](https://github.com/wippyai/runtime/pull/653) is merged. It
  supplies native mesh viewport mounts with exact recipient grants, independent
  observation/input/resize rights, bounded delivery and revocation. Its scope
  explicitly excludes remote process startup and physical-client discovery.
- Runtime [#668](https://github.com/wippyai/runtime/pull/668) is merged. It owns
  standalone application deployment and the application-state lock. At takeover, upstream
  `application.Run` returned the lock error on a second invocation; it had
  no attachment callback. Attaching must not open the owner's registry or
  workspace databases.
- Runtime #664, #674, #675, #676 and #685 remain open at this audit. These cover
  naming consistency, PID comparison, connection shutdown, lookup errors and
  monitor lifetime. They are not a completed physical-client API.
- Bee checkpoint `26594cd` owns the retained desktop supervisor and has passing
  source/pack and standalone acceptance. It is the consumer integration base.

Fetched runtime `origin/main` is `fdad09cef2b766e17b95c52c0aa01183601a9243`.
The primary `~/wippy/wippy` checkout and `/tmp/wippy-cluster-hardening` are dirty;
neither is the integration baseline. Runtime work starts in isolated branch
`feat/terminal-event-input`, worktree
`/tmp/wippy-bee-client-runtime-20260909`.

## Implementation sequence

1. Review the existing `runtime/research/physical-input.patch` as a runtime-owned
   event-input API. Preserve the actor input adapter. Prove terminal restoration,
   EOF, cancellation and restart, then run the Bee physical-client consumer test.
2. Extend runtime application startup with explicit owner/attachment selection
   under its existing lock lifecycle. Read discovery data without treating its
   presence as liveness or authorization. Updates must retain exclusive access.
3. Compose admitted clients through native mesh viewport grants and the retained
   Bee supervisor. The destination selects the desktop and rights. A physical
   close detaches; it does not close the desktop, shell or node. Do not activate
   `native/client/local` as an alternative network listener.
4. Prove two separate local OS clients, then destination Terminal execution on
   `100.70.10.28`, including client crash/rejoin and denied stale control. Only
   after those checks change public launch defaults and readiness claims.

The input API extraction alone does not establish public attachment. Node
enrollment, authenticated admission, discovery and runtime boot composition still
need implementation/acceptance. Strict Lua boundaries and existing database
ownership remain unchanged.

## First runtime checkpoint

Local commit `5c24317b5a` extracts the event-input API and preserves the existing
actor adapter. Its failed-start check uses a real PTY, fails after raw-mode
acquisition and proves the same reader can restart. Terminal service race tests
and `go vet` pass; Bee's `make -C native physical-client-check` passed against
the extraction. Logs: `/tmp/bee-runtime-input-final.log`,
`/tmp/bee-runtime-input-vet.log`, `/tmp/bee-runtime-input-consumer.log`.

The broader Lua TTY suite fails `TestSurfacePresentClearsRemovedRows` identically
on untouched upstream main: expected two changed rows, got three. Baseline log:
`/tmp/bee-runtime-input-baseline.log`. No full-runtime pass is claimed. The commit
is local; no PR, merge, global install or public attachment activation occurred.

## Application startup boundary

Local runtime commit `85736d0524` rebases the existing Bee launch-preparation
patch onto upstream main, including the shared application state-lock package.
Commit `e3aee1a13c` adds `LaunchPlan.Attach`: a compiled preparer
may supply this handler for an ordinary application launch. Runtime invokes it
only after the selected lock reports `statelock.ErrBusy`, before owner data
environment binding, deployment selection or database access. The callback must
authenticate the live owner and obtain admission; lock contention may instead
be an update, so it is not evidence of an attachable owner.

Attachment errors return without replay or fallback startup. Other lock errors,
base recovery, runtime tooling and updates do not take this path. Preparation
cleanup runs after attachment returns. No discovery implementation or listener
is introduced by this hook.

`make test-application`, the application package race suite and vet pass. New
checks cover a busy owner with deliberately invalid activation/bindings, retained
owner exclusion, failure without retry, free/erroring locks, reserved operations
and cancellation. Logs: `/tmp/bee-runtime-attachment-check.log`,
`/tmp/bee-runtime-attachment-race.log`, `/tmp/bee-runtime-attachment-vet.log`.
The next step is the native-mesh client handler and owner rendezvous, then Bee
retained-supervisor composition. Public launch remains unchanged.

## Retained native mesh listeners

Local runtime commit `31e4345e10` rebases Bee's existing cluster-listeners patch
and adds a direct boot-component lifecycle proof. Port zero asks the OS for an
available port. The actual internode listener stays bound while its endpoint is
published; load no longer opens and closes a probe socket. The existing native
mesh remains the transport.

The boot proof exposed repeated membership cleanup panicking after shutdown.
Component-owned lifecycle flags now prevent repeated cleanup, including a failed
join followed by loader shutdown. The test uses a bounded startup context because
membership deliberately retries joining until cancellation.

Race tests pass for internode, cluster assembly and the system boot components.
The assembly check starts 20 authenticated stacks concurrently, verifies distinct
retained ports and all peer connections, then rejoins an identity while its old
port is occupied. Boot checks cover unpublished endpoints during load, reservation
after start, socket release and failed-start cleanup. Vet passes. Evidence:
`/tmp/bee-runtime-listeners-lifecycle.log` and
`/tmp/bee-runtime-listeners-boot-final.log`. Earlier fixture failures are retained
in `/tmp/bee-runtime-live-listener-boot*.log` and
`/tmp/bee-runtime-listeners-boot-failure.log`.

Remaining integration: live endpoint publication for owner rendezvous, admitting
fresh client identities without trusting gossip metadata, the mesh client process
and retained Bee supervisor, then real OS-client/LAN acceptance. No public Bee
manifest or global executable has been changed by these local runtime commits.

## Host-approved fresh transport identities

The runtime now accepts a typed `cluster.PeerKeySource` selected by a compiled
host: `StackConfig.InternodePeerKeySource` for direct assembly or native boot
config `cluster.internode.peer_key_source`. A shared resolver enforces static
pin precedence and matching membership advertisements before the existing signed
handshake. The local identity still needs a matching static pin. YAML values and
nil callbacks are rejected. No new listener or trust-by-gossip path is introduced.

The real two-stack test first observes an authorization denial, then approves
the client's key and establishes the authenticated connection without restarting
the owner. Race checks for cluster/internode/boot and vet pass. Boot tests verify
typed-source acceptance and invalid-source refusal. Logs:
`/tmp/bee-runtime-peer-source.log`, `/tmp/bee-runtime-peer-source-boot.log`,
`/tmp/bee-runtime-peer-source-vet.log`.

This source controls new handshakes. Removing a key does not retire established
connections or application grants; their owners must do that separately. The
host-owned enrollment store, live rendezvous publication and Bee desktop
admission remain to be composed. Runtime API documentation is
`api/cluster/PEER_KEYS.md` in the isolated checkout.

## Bee rendezvous component

Bee commit `d2b02bd` adds `native/hive/rendezvous` and brings the existing
private-file helper into the isolated checkpoint. The unregistered publisher
depends on the standard `cluster` boot component and captures only the local
native membership/transport endpoints after startup. The descriptor contains no
secret or permission grant. Reads never create state; shutdown never unlinks a
replacement owner's discovery file. Literal IP endpoints are required for this
first implementation.

The isolated worktree is `/tmp/bee-mesh-rendezvous-20260909`, based on `26594cd`.
`make -C native check` passes against the declared runtime dependency, and
`make -C native rendezvous-check RENDEZVOUS_RUNTIME=/tmp/wippy-bee-client-runtime-20260909`
passes against the runtime integration candidate. The latter includes a real
mesh stack and runtime application lock, retained listener and client read checks.
Logs: `/tmp/bee-rendezvous-isolated-native-check.log` and
`/tmp/bee-rendezvous-isolated-final.log`. No full desktop-suite rerun is claimed:
production entry selection and Lua sources are unchanged. The `x/sys` version
is unchanged; it becomes a direct dependency of the reused private-file helper.

Public launch still needs the host enrollment store, discovery-to-handshake
binding and a physical client admitted through the retained supervisor. Do not
equate a readable descriptor with a live or authorized desktop.

## Local bootstrap enrollment store

The rendezvous package now also owns `local-enrollment.json`, separate from its
public descriptor. Owner initialization requires the application-state lock and
a fresh execution ID/gossip key. Same-execution retry preserves registrations;
conflicting bootstrap keys are refused. Same-OS-user clients register fresh node
IDs and public signing keys. Private signing keys never enter the store.

Registration and removal check the exact owner execution; conflicting client
keys fail. Concurrent registrations preserve every key. The 128-client bound is
explicit; there is no silent eviction. Snapshot formatting redacts the secret.
The key source re-reads the bounded protected file at handshake time so missed
filesystem notifications cannot preserve a stale approval. No watcher, idle
poller or per-packet file I/O is introduced.

Both isolated native checks and live mesh integration pass. A client knowing the
gossip secret is rejected before registration, then authenticated after its key
is registered, without owner restart. Removal denies subsequent lookup, not an
already established session. Logs: `/tmp/bee-local-enrollment-isolated-native.log`
and `/tmp/bee-local-enrollment-isolated-live.log`.

Remaining activation gates include client crash cleanup, descriptor/execution
handshake binding, physical display admission and actual CLI composition. Remote
machine invitations are not implemented by this same-account local mechanism.

## Physical terminal consumes native viewports

The gated `native/client/physical` adapter now accepts the runtime's checked,
cancellable viewport directly. It has no import of the experimental Bee display
transport. The caller supplies the recipient frame and selected rights; native
checks run before terminal mode changes and on subsequent operations. Observation,
input and resize remain independent. Ctrl+] cancels pending native operations and
detaches; it does not terminate the producer. Coalesced updates read the cached
snapshot. No input is replayed after cancellation or delivery failure.

`make -C native physical-client-check` passes race tests and vet against the
isolated runtime candidate. Real PTYs cover stalled delivery, restore, observer
input suppression and denied control. A runtime viewport over an in-memory test
mesh proves foreign-recipient denial, expired mounts after detach and reattachment
to retained content. Log: `/tmp/bee-native-viewport-physical.log`.

This adapter is still unregistered. Actual process admission, owner/client startup
composition, enrollment crash reclamation and separate OS-process/LAN proofs remain
unfinished. No public `bee` behavior changes in this checkpoint.

## Separate local client process starts through native mesh

Bee checkpoint `b9a2e7b` adds gated `native/client/mesh.Local`. The function reads
existing protected rendezvous data, enrolls a fresh random node/signing identity,
starts the native Wippy stack on automatic loopback ports, authenticates the pinned
owner and rechecks endpoints and on-disk execution before its callback. It opens
no application database and never acquires the owner's application lock. The
callback still owes supervisor admission and authenticated execution binding.

A startup deadline originally risked ending healthy connections because Wippy
retains the context supplied to `Stack.Start`. The client now disarms its startup
abort after connection and keeps caller cancellation for the transport lifetime.
On return it stops the stack before exact-key enrollment cleanup, using a separate
bounded cleanup context. Cleanup failure remains visible; crashes still need
reclamation before activation.

`make -C native mesh-client-check MESH_RUNTIME=/absolute/runtime/checkout` passes
race tests and vet in the shared and isolated Bee checkouts. A separate OS-process
acceptance helper generates its own key, authenticates, exits and leaves no client
enrollment while owner lock exclusion remains intact. Additional checks cover
missing discovery without state creation, stale endpoints, callback failure and
transport survival beyond the startup deadline. Logs:
`/tmp/bee-mesh-client-check.log`, `/tmp/bee-mesh-client-isolated.log`.

Next composition uses the existing runtime `service/host` actor host, `core.PIDGen`
and topology/TTY lifecycle; the client needs a real monitored process frame before
requesting a recipient-bound mount. Avoid fabricated PIDs, loading the whole Bee
pack into the thin client, or importing the alternate display transport. Reuse or
extend runtime mesh composition for TTY wiring instead of creating a Bee listener.
Public `bee`, retained-desktop admission, crash cleanup and LAN proof remain open.

## Runtime coordination refresh

Wolfden seq 243 separates the active lanes; seq 246 acknowledges it. Runtime
primary owns cluster/naming correctness, acquisition/retirement/recovery,
connection lifecycle, leader/session observation and network/load verification.
This client lane retains startup/host-approved-key integration, application-lock
attachment, rendezvous/enrollment, desktop admission/presentation and OS-client
acceptance. The local-client checkpoint edits no shared runtime files. Identify
any future overlapping transport-file changes in the journal before editing;
there is no renewed exclusive-owner wait and no Bee TLS sidecar.

## Native actor and physical OS-client checkpoint

Bee `f31199f` composes the real runtime process host, PID generator, topology
registration, sealed frame and an explicit empty permission scope. The native
control inbox retains bounded owned JSON with relay sender identity separate from
payload fields. Its process lifetime cancels the consumer and retires native TTY
handles before frame release. `actor.go`, `host.go` and `process.go` separate message
I/O, assembly and scheduler adaptation. This is a gated API, not public launch.

`Local -> WithActor -> physical.Run` now passes a two-client OS-process/PTY proof
against the same retained owner viewport. Each client has a fresh key/node/PID,
paints content, sends a typed key and detaches through native sockets. A fresh
client reattaches to surviving content. The fixture selects recipient-bound grants
through test files; these files are not a production admission protocol. The proof
covers the native viewer, not a public Bee Terminal or supervisor launch.

`make -C native mesh-client-check` passes race tests and vet in the shared and
isolated Bee checkouts. Logs: `/tmp/bee-physical-process-mesh.log` and
`/tmp/bee-native-actor-isolated.log`. `mesh-monitor-check` is a separate, explicitly
unresolved integration gate. It fails `/tmp/bee-native-monitor-gate.log`: the runtime
accepts a remote monitor, a FIFO barrier confirms subsequent delivery, and the
client actor finishes while its transport stays alive, but no EXIT reaches the
watcher. See Wolfden seq 247–248 and 253. Runtime primary owns monitor ingress and
the cancellable router/internode send extraction. `Actor.Send` refuses a router
without cancellable delivery; it never wraps legacy Send in a goroutine.

Runtime candidate additions, all local on `feat/terminal-event-input`:

- `1b81a3d817`: existing PR #690 cherry-picked unchanged after the consumer exposed
  the metrics channel send/close race. Metrics race tests pass.
- `7334244f75`: standard boot and thin clients share
  `internode.NewSurfaceTransport`. This extracts the existing adapter, opens no
  listener and changes no connection lifecycle. Internode/boot race tests and vet
  pass; protocol compatibility tests moved with the adapter.
- `7c999b9659`: fixes the stale Lua wrapper shrink assertion from runtime handoff
  254. Clearing removed rows must precede repaint of the surviving row. The
  wrapper test now asserts all three touched rows and that order. Native terminal
  and Lua TTY race suites pass. No production rendering change or CI edit.

Evidence: `/tmp/bee-runtime-metrics-consumer-fix.log`,
`/tmp/bee-runtime-surface-adapter.log`, `/tmp/bee-runtime-surface-metrics-vet.log`,
`/tmp/bee-runtime-surface-shrink-wrapper.log`. No full-runtime pass is claimed.
Runtime PR/main/global executables remain untouched.

Next: destination supervisor admission and execution binding, owner/client launch
composition, crash enrollment/grant reclamation, public second-bee acceptance and
LAN acceptance. The first two runtime dependency gates above must not be hidden
behind fixture grants or treated as already solved by PR #685, which covers local
bookkeeping only. There is no user-permission blocker.

### Follow-up: held local enrollment slots

Local clients now use `RegisterHeld`: bounded stable OS locks protect live
holders, and the next holder reclaims only its slot's stale enrollment row.
Version 2 adds explicit slot metadata within a 64 KiB bound; version 1 remains
readable and upgrades on mutation without dropping unmanaged peers. Actual
subprocess kill/reclaim, canceled cleanup and legacy preservation tests pass
under the native race suite. Shared native vet and Windows cross-compilation
also pass. This supersedes the enrollment-row reclamation gap above; it does
not resolve application-grant retirement, remote monitor ingress, production
supervisor admission or the public second-bee/LAN gates.

### Follow-up: native control sends

Runtime candidate commit `8c2b982548` extracts cancellable router/internode queue
admission from the primary runtime lane, preserving the candidate's surface
transport. It includes queue-lock cancellation, explicit unknown-peer refusal,
caller package ownership on rejection, and a cancellable wait for discovered
peer registration. Runtime relay/internode race suites and vet pass. Bee's
mesh/physical suite now proves a native actor request/reply with sender/payload
preservation and canceled-request non-delivery. No primary research files or
public runtime installation changed. Remote monitor ingress remains an
unenabled protocol; production admission and automatic public attachment are
still required.

### Follow-up: transport provenance before admission

Runtime candidate `3982711303` extracts the primary lane's ingress identity and
connection-lifetime observations. `Package.Source` retains transitive routing
semantics; `Package.Ingress` is overwritten by native transport, excluded from
wire encoding, and cleared on pool release. It includes immediate peer identity,
handshake authentication, independent payload-integrity status, and the exact
local connection closure signal. The connection also rejects Run after Close.
Relay/internode/host race checks and vet pass. The Bee actor now requires matching
authenticated owner ingress and passes the provenance to the admission consumer.

The current local fixture uses authenticated plaintext, which correctly reports
`IntegrityProtected=false`. It proves provenance plumbing, not LAN authorization.
Production admission must require its selected transport protection and exact
supervisor/execution binding; do not treat Source or handshake alone as that
proof. Public launch remains unchanged, and the installed `bee` continues to
provide the existing local desktop.

### Follow-up: existing supervisor name discovery

Bee `9305a22` loads the standard Wippy EVENTUAL name component before mesh
membership starts and stops it before mesh shutdown. Actor.OwnerSupervisor
resolves the existing bee.hive.supervisor/<node> name, checks its owner node,
protected host and nonempty process identity, and refuses canceled/retired
callers. A real two-stack initial name exchange test passes. Full isolated
mesh/physical race and vet checks pass in /tmp/bee-native-discovery-isolated.log.
The name is an address, never an admission grant. This uses the native name
registry, not an application registry database or a new discovery protocol.

### Follow-up: review fixes and native TLS selection

Luna's independent review found that the native actor failed to release consumed
relay packages. Bee `fd135b5` fixes the entire drained batch, including rejected
messages and the unvisited tail after overflow. Counted retention-lease tests
and the full isolated mesh/physical race and vet checks pass.

Agy implemented native stack TLS selection; root reviewed it down to one
StackConfig.InternodeTLS field wired to the existing manager configuration.
The two-stack test now verifies actual relay delivery with authenticated,
integrity-protected ingress. Runtime cluster race tests and vet pass in
/tmp/bee-stack-native-tls-reviewed.log. This adds no TLS listener implementation,
certificate provisioning or automatic Bee attachment. Closed ingress remains
metadata to pin and check in production admission; specialized class receivers
are not covered by the default relay ingress envelope.

### Follow-up: physical client TLS and shared shutdown consumption

`Local` now accepts a typed `LocalConfig` with the discovery directory and
host-selected runtime TLS configuration. Separate physical OS clients now use
mutual TLS, verify protected relay ingress, paint retained content, send input,
detach and reattach. Invalid certificates and plaintext-owner mismatch never
enter the callback and leave enrollment unchanged. Full isolated client race
and vet pass in /tmp/bee-client-tls-policy-isolated.log.

Primary's idle TLS peer tests failed on the candidate before the fix
(/tmp/bee-runtime-tls-close-baseline.log). Candidate `ef22d02d4e` consumes primary's
existing abortConnection helper and its NodeConnection.Close/handshake call sites.
Runtime internode/cluster race and vet then pass
(/tmp/bee-runtime-tls-abort-consumer.log). This is reuse of the shared runtime
shutdown implementation, not a Bee listener or wrapper. Certificate provisioning,
production admission, public attachment and LAN acceptance remain required.

### Normal owner boot TLS selection (2026-09-09)

The isolated runtime now passes strict `cluster.internode.tls` configuration
(`enabled`, `cert_file`, `key_file`, `ca_file`) into the existing connection
manager. This closes a gap between `AssembleStack` and normal `Cluster` boot;
it changes no TLS loader, listener or connection lifecycle. Unknown/malformed
settings and credential paths without explicit TLS selection fail closed.
A real normal-boot listener completes a verified TLS handshake, invalid selected
credentials prevent endpoint publication, and shutdown releases its socket.
Full boot-system race tests and vet pass; evidence is
`/tmp/bee-runtime-boot-tls-full.log` and `/tmp/bee-runtime-boot-tls-vet.log`.
The primary runtime worktree was not modified; this isolated extension was
announced at Wolfden seq 276 before implementation and checked at seq 277.

Owner startup still needs a lock-held preparation point before cluster Load.
`PrepareLaunch` runs before the application lock, so it cannot safely provision
owner credentials/enrollment there. Avoid side-effecting config getters or
component-order assumptions to bypass this ordering. Remote Lua ingress and
acknowledged monitor installation remain separate runtime prerequisites.

The isolated launch API now implements that ordering through
`LaunchPlan.PrepareOwner(ctx, request) -> (OwnerPlan, error)`. It runs only for
ordinary owner startup after lock acquisition, before data environment or
selected-deployment access. A nonnil `OwnerPlan.Config` replaces the preparer's
complete override set; registry history remains runner-owned. `OwnerPlan.Close`
is registered even on preparation failure and runs before releasing the lock,
then outer `LaunchPlan.Close` runs. Busy-lock attachment never calls owner setup.
Base recovery, updates, tooling and handled launches cannot select this callback.
`OwnerPlan.Deadline` bounds remaining startup/runtime lifetime; expired deadlines
fail before store access. Bee can return its credential's actual `ExpiresAt` here.

Full application race tests and vet pass. Real state-lock tests cover exclusion
during preparation/cleanup, ordering on failure, reserved-operation denial,
attachment without owner setup, cancellation and expired deadlines. Evidence:
`/tmp/bee-runtime-owner-preparation-final.log` and
`/tmp/bee-runtime-owner-preparation-vet.log`. The Bee preparer/composition still
needs to consume this API; it does not itself create or admit a retained desktop.

### Execution cancellation during owner drain (2026-09-09)

The real normal-owner acceptance exposed two additional runtime gaps. Bootstrap
replaced the caller context with Background, and the CLI waited only for signals
and skipped cleanup on several error paths. The isolated candidate now preserves
parent lifetime and owns cleanup across normal and pack execution. Review also
covers failures between pack bootstrap and entry launch.

Once the deadline reached components, a slow Lua process still delayed native
listener closure because reverse loader shutdown reaches the supervisor before
cluster. The isolated cluster component now serializes cancellation with its
lifecycle, closes existing native services for the exact execution, and joins an
already scheduled callback during Stop. It adds no listener or TLS wrapper.

`/tmp/bee-owner-context-network-stop.log` proves actual `application.Run` with
8-second credentials and a sleeping Lua process: a native client authenticates,
the mesh listener closes by expiry plus 2 seconds, the application lock remains
held during drain, and bounded process exit releases it. Full boot-system race
checks pass, including cancellation before explicit Stop and concurrent Stop.
Wolfden seq 282–283 records scope and evidence. Public launch remains unwired;
these checks establish owner transport lifetime, not workspace admission.

Committed checkpoints: Bee `467a060` (normal fast-forward to
`origin/feat/independent-view-bindings`), runtime `9663ea8263` (cluster execution
cancellation) and `819c859f15` (parent lifetime and runner cleanup). Runtime
commits remain local for primary integration review. The injected partial-Load
failure check passes; full boot, command and application race suites and vet
pass. The later seq 284 ownership handoff explicitly preserves this isolated
client boot lane; seq 286 acknowledges it and provides exact files/commits.

### Lua delivery provenance (2026-09-09, isolated candidate)

The Lua engine now copies `relay.IngressIdentity` into its queued message before
releasing the pooled relay package. Each `TopicHandler` call receives a fresh
context with a private engine key; `engine.TopicIngress(ctx)` reads that delivery's
identity. Callback signatures remain unchanged. The process/application context
is never modified, and local delivery explicitly replaces inherited provenance
with zero rather than inheriting a remote identity.

`process.Message:ingress()` returns `process.Ingress?`. The native handle provides
`node()`, `authenticated()`, `integrity_protected()`, `live()` and
`same_connection(other)`. A zero/local identity returns nil. A missing native
connection lifetime is never live. Connection equality neither checks liveness
nor renews authority; callers must check liveness again when consuming a pending
result. Node and authentication describe the immediate transport peer, not the
origin of a forwarded PID or payload. These are typed read-only native values,
not serialized grants or a Lua constructor.

Destination admission must require the expected peer, authentication, transport
protection and a live connection, then apply host-selected authorization. Pin the
connection for the exchange and reject a replacement. Retain request correlation,
execution identity and principal checks; this API does not replace any of them.
Do not infer that every authenticated peer has local-account or application
rights. The Lua Hive supervisor has not yet been changed to consume this API.

Focused race tests cover queued delivery after connection closure, local
provenance clearing, forged handles and replacement connections. Strict type
checking and a scheduled Lua inbox test pass. Full engine/process race checks and vet pass. These tests inject native provenance
and do not by themselves prove a two-node supervisor admission exchange.

The separate normal-owner fixture now also passes a real native-to-Lua exchange:
`/tmp/bee-native-lua-ingress-verified.log` (19.511s), followed by the same expiry and
lock-drain checks. Full native mesh/physical/local-TLS race and vet pass in
`/tmp/bee-native-ingress-client-full.log`. The native adapter consumes Wippy's
normalized Go representation of ordinary Lua reply tables under explicit depth,
raw-value and final JSON-byte limits; Lua code need not wrap its replies in a
special payload. Bounded outgoing requests require an exact-topic Lua listener.
Compare PIDs by node/host/process identity, not Go struct equality, which also
compares the internal cached string. Wolfden seq 290 records the evidence.
Production supervisor authorization and public attachment remain required.

The ingress API is committed locally as runtime `14ae99cebe`. Bee's tested
consumer/proof is `d3add5d`, synced to the integration branch. Lua supervisor
consumption is the next required step; do not claim that the fixture issues
production desktop grants. The separate shared remote-monitor correctness gate
remains owned by the runtime primary.


### Native ingress consumer checkpoint (2026-09-09)

Wolfden Bee Harness seq 295 records the implemented supervisor consumer. Typed
message subscriptions pass strict lint; remote admission pins authenticated,
protected native connection evidence. Both actual-supervisor and native-service
TLS acceptance pass (`/tmp/bee-supervisor-native-ingress-acceptance3.log`, 26.603s).
Disposable transport certificates remain separate from native signing keys.
The shared Hive source is preserved unstaged because it belongs to the combined
lanes; do not blanket-stage it. Luna max is reviewing connection lifetime.

Isolated Bee commit `02cb03d` requires object roots in native control replies and
qualifies userdata export behavior. Focused race tests and vet pass in
`/tmp/bee-native-object-root-focused.log`; the broad run was unable to start its
PTY subprocess (`operation not permitted`), so fresh physical acceptance is not
claimed. Public `bee` auto-attach, retained production desktop grants and the
100.70.10.28 Terminal proof remain outstanding. The runtime primary owns the
terminal lifecycle forwarding gap recorded at journal seq 294.


### Packed command host correction

Runtime local commit `699597ef70` forwards the operator's `--host` through both
pack launch routes. Full Bee validation exposed this gap: source headless passed,
but the pack silently selected the terminal host instead of `bee:workers`.
`make headless-check` now passes source and pack against the rebuilt candidate;
selected command tests and vet also pass. This does not touch the primary's
terminal service lifecycle composition. Remaining repository checks were resumed
in `/tmp/bee-supervisor-native-ingress-repo-resume.log` after the proven prerequisites.

The Lua consumer's 379 native Wippy tests and final two-runtime TLS acceptance
pass (`/tmp/bee-supervisor-native-ingress-final.log`, 27.247s). Luna's independent
review ended in a provider high-demand error; it is not review approval.


### Completed candidate repository acceptance

The resumed `make check` completed successfully against the raw candidate with
runtime packed-host fix `699597ef70`. Source/pack checks include multiple workspace
hosts, storage/migration integrity, journal ownership, window/Terminal behavior,
independent/retained client views, recovery and Test Status background replay.
Logs: `/tmp/bee-supervisor-native-ingress-repo-check.log` (passed prerequisites and
original packed-host failure), `/tmp/bee-runtime-pack-host-headless.log` (fixed
source/pack host proof), `/tmp/bee-supervisor-native-ingress-repo-resume.log`
(successful remainder). No installed-launcher or LAN claim follows from this.

The new isolated `native/client/hive` binds the existing Hive protocol to the
native physical actor, serializes calls, pins verified connection lifetime and
returns unknown outcomes without replay after a send. Focused race/vet and real
Lua wire exchange pass. Independent bounded review found no issues in client.go
and reply.go after Luna provider failures. Destination desktop authorization is
still required; it must use this same Hive surface and host-selected authority.


Native Hive binding commit: `6df7d0d` in the isolated Bee integration branch.
Final normal-boot wire/expiry/drain proof: 19.368s in
`/tmp/bee-native-hive-lua-wire-final.log`; focused race/vet in
`/tmp/bee-native-hive-client4.log`. Independent review found no concrete issue.
Wolfden seq 309 records full local candidate acceptance. Seq 308 asks the runtime
primary for authenticated credential evidence (or an existing equivalent) so
shared-transport desktop admission can distinguish local-client enrollment from
LAN supervisor trust. Node names or caller payload flags must not grant local
account rights. Root owns the Bee admission consumer; primary owns the runtime
identity/transport seam. Public launch remains unchanged.
