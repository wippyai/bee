# Hive boundary proof

This is an experimental acceptance plan, not an available Hive launch mode.
Prove these boundaries before extending the desktop or publishing setup commands.
Workspace databases and registry histories remain independently owned. There is
no central SQL catalog. Machine configuration stores trust and location hints.

## Current runtime evidence

Inspected against the pinned runtime plus Bee's manifest patches:

- `boot/components/system/cluster.go` reads a shared membership secret and a
  separate Ed25519 identity for each runtime. It captures `trusted_peer_keys`
  at startup; the peer resolver also checks advertised membership identity.
  A shared seed alone cannot enroll a previously unknown identity into an
  already running host. The existing multi-process fixture preloads every key.
- `cluster/internode/internode.go` connects to existing members at startup and
  to each joining member. This is eager peer connectivity. An on-demand
  transport claim requires another runtime capability and acceptance tests.
- The connection manager accepts a peer-key resolver. A runtime-owned live
  trust provider may be a suitable enrollment seam; boot currently wires a
  static map. Do not trust a public key merely because gossip advertises it
  or the joining node possesses the membership secret.
- Bee's destination host admits exact client executions through its supervisor
  with explicit operation permissions. Mesh membership must not bypass that
  admission or confer native Terminal authority.

The current handshake tests cover matching credentials, wrong shared keys,
forged identities and an explicitly unauthorized peer. They do not prove seed
enrollment, credential revocation, LAN discovery or remote Bee admission.

## Experiment sequence

1. Measure many independent runtimes on one machine. Retain strict Lua,
   automatic bound ports and isolated state. Observe idle process CPU and socket
   descriptors after convergence. Follow with traffic measurements before
   choosing a topology.
2. Prove an unknown node cannot gain actor access from discovery alone. Define
   enrollment against an authenticated owner, then prove a newly authorized
   identity connects without restarting existing workspaces. Test revocation
   separately, including established connections.
3. Advertise workspace identity and owner incarnation through native names and
   actor messages. Establish whether native transport authenticates the source
   node of actor messages before using remote sender PIDs for admission.
4. Connect two actual Bee runtimes: admit one remote client, open the destination
   Terminal, detach/rejoin with fresh grants, and reject an unauthorized client.
   Preserve destination identity through every request, reply and view.
5. Add local rendezvous and LAN candidate discovery around the proven path.
   Saved seed endpoints are a fallback; broad address/port scanning is not the
   default. Candidate discovery carries no authorization. Multiple local Bee
   nodes should share discovery work where native runtime boundaries permit it.

A machine may host multiple Bee nodes and each node may own multiple workspaces.
Do not collapse machine, runtime-node and workspace identity to simplify a demo.
The first fixture may use one workspace per runtime while proving the remote
boundary. Filesystem resources belong to the workspace and can reference several
authorized roots independently of the folder used to launch it.

## Running the measurement

After building the native toolchain from the current manifest:

```sh
GOWORK=off GOTOOLCHAIN=go1.27.0 go run tests/hive_boot.go \
  -runtime .wippy/bin/bee-wippy -nodes 20 -idle 10s
```

`-idle` is an optional Linux-only observation, capped at twenty seconds. It reads
only the fixture's child processes, reports aggregate kernel CPU clock ticks and
socket descriptors, and fails if a child exits during the observation. Socket
descriptors include listeners and UDP, so they are not a peer-connection count.
It does not measure bytes, claim a CPU percentage, or set a performance threshold.
All state and keys are disposable; no installed Bee configuration is changed.

## Initial observations (2026-09-08)

The candidate native toolchain passed five-node and twenty-node boot/convergence
runs, each with three Raft servers and a ten-second idle observation:

| Runtime processes | Aggregate idle CPU ticks | Socket descriptors |
|---|---:|---:|
| 5 | 22 | 40 |
| 20 | 60 | 460 |

These are single observations on the development host, not performance budgets.
The host reports CLK_TCK=100. Descriptor counts are consistent with eager peer
connections plus listeners, but this probe does not classify individual sockets
or measure network traffic. Do not extrapolate a production traffic guarantee.

A focused test at the internode delivery boundary also found that a package whose
Source.Node differs from the authenticated callback peer is delivered. The
reproduction is in the isolated runtime checkout; it is not a shipped fix or an
end-to-end exploit claim. Validate source provenance and any supported forwarding
semantics before relying on remote actor PIDs for supervisor admission. Existing
handshake identity tests passing does not establish message-source provenance.

The original inspected boot callback passes decoded packages to `node.Send`, which rejects
foreign target nodes but does not bind Source.Node to the authenticated transport
peer. The router separately supports registered external peers (for example,
Temporal). A fix must account explicitly for any supported external identity
namespace rather than silently allowing arbitrary source-node claims. Bee does
not require transparent actor impersonation across a supervisor hop: supervisors
send as themselves and establish explicit grants for direct clients.

The selected ingress candidate enforces direct source-node provenance and records
rejected packages without rewriting their source. In-process external-peer
routing is unchanged. Forwarding a virtual source identity across a different
native transport node has no authenticated delegation in the current path; it
must not remain implicitly trusted. Supporting that case requires explicit native
source authority and a dedicated acceptance test. No generic metadata-based
exception is part of the candidate. `runtime/patches/actor-provenance.patch` is
included in the native build manifest. The full internode race suite, clean
toolchain build and twenty-runtime boot with three Raft servers pass with it.
The two-runtime Bee fixture below passes with this candidate; the installed
executable has not been replaced by it.

## Bee remote Terminal boundary

### Live trust prerequisite

The native manager already calls `ResolvePeerKey` and `AuthorizePeer` at
authentication, but boot closes those callbacks over a startup-only key map.
A race-enabled two-manager probe additionally verifies that changing both
callbacks to deny a peer does **not** stop messages on an established connection.
The reproducer is `runtime/research/live_trust_probe_test.go`; copy it into
`cluster/internode` in an isolated patched runtime checkout and run
`go test -race ./cluster/internode -run TestBeeProbeExistingConnectionAfterTrustWithdrawal -v`.
Its passing result characterizes the gap, not successful revocation.

The next native seam must retain exact node/key authentication, permit an
explicit host-owned trust provider, and define how withdrawing trust fences
existing connections. The manager's asynchronous `DisconnectFromNode` has no
completion receipt; it alone is not proof that no message can still be delivered.
All traffic classes must honor the same fence. Enrollment credentials and
workspace operation grants remain separate; neither registry metadata nor gossip
may populate trust implicitly.

A transport fence is local: its receipt can establish that old receive callbacks
have drained and no new ones can begin. It cannot recall messages already handed
to an actor inbox or undo remote effects. Machine revocation must also retire
supervisor admissions and recipient-bound view grants. The application owner
still decides whether previously accepted work completes or is canceled. Those
owner operations need their own receipts before reporting an overall revocation
complete; a socket closing alone is insufficient.

Acceptance must cover enrollment while both runtimes remain alive, wrong-key
denial, withdrawal during active traffic, re-admission with fresh authority,
and unchanged static-pin behavior without a provider. Until those gates pass,
the fixture below continues to use explicit test pins and proves no public
invitation or machine-revocation API.

The source fixture uses two independent native runtimes with disposable,
pre-pinned test credentials. Node A runs the real workspace host and bundled
Terminal; an actor on node B receives supervisor-selected client admission and
a recipient-bound native viewport mount. It checks:

- A request before admission creates no application; catalog and operation
  replies retain the destination workspace identity.
- Commands read a nonce file present only in node A's working directory.
- Input executes in Bash and native resize is observed through `stty size`.
- Fabricated connection IDs and stale renderer generations are refused.
- Detach invalidates the cached remote view and denies input and resize.
- Fresh admission and a fresh mount retain the same application, Bash PID and
  a shell variable. Requests using the old connection create no extra app.
- A request naming another workspace is rejected without opening locally.

Build the current manifest toolchain, then run:

```sh
make native-tools NATIVE_WIPPY=.wippy/bin/bee-wippy-hive
make hive-remote-check NATIVE_WIPPY=.wippy/bin/bee-wippy-hive
make hive-presenter-check NATIVE_WIPPY=.wippy/bin/bee-wippy-hive
make hive-desktop-check NATIVE_WIPPY=.wippy/bin/bee-wippy-hive
```

The presenter gate runs the actual `bee.terminal:main` against the remote host.
It pauses the destination runtime only as fault injection, then verifies Start
within one second, visible input queue overflow, and F12 request plus clean
presenter exit within one second each. Fresh renderer admission retains the
original Bash PID and shell variable. The pre-delivery presenter fails at the
Start deadline. This does not implement an application pause operation.

Delivery is actor-local and bounded to 128 live attachments, 256 live-plus-retired
entries, 256 pending operations per view, 1 MiB queued payload per view and 4 MiB
aggregate payload. In-flight retired work remains charged until completion.
Only adjacent unsent resizes coalesce; input stays ordered and is never blindly
retried after an uncertain result. Failed snapshots retain the last content and
hide its cursor. These bounds do not account for the native transport's own
buffers or establish a dormant-network traffic budget.
The ordinary Lua suite also fills the 128-entry live limit with failed native
attachments for three rounds, closes them, and verifies that capacity is reusable
and retired failure notifications are suppressed. It does not simulate remote
in-flight memory pressure; that remains a separate acceptance case.

The desktop gate uses the real `bee.client:main` on node B, with its own client
store and display, against the real workspace host on node A. Its initial
application opens through production client/session routing; the fixture does
not fabricate the desktop scene. It verifies the destination-only nonce, Bash
PID, remote `stty` size, F12, then a fresh client using the same local store and
retaining the same remote shell and variable. Root independently reproduced this
gate with two local runtime processes. After renderer admission the fixture waits
for the new presenter's test-only identity marker and retained shell output in
the same physical frame before sending input once. Remote geometry convergence
is checked with a bounded destination-side wait. This does not prove lossless
input during the handoff or public remote discovery and enrollment.
The same full-desktop gate also passed across two machines using native mesh
transport, including fresh-client reattachment. Destination cleanup was checked
afterward: its private test directory was removed and the staged runtime retained.

This is source-fixture evidence for native transport and Bee host admission,
not public enrollment or a remote desktop selector. The baseline runs on one
machine. The `hive-remote-check` target also pauses the destination OS process and verifies
that a pending remote viewport resize in a coroutine does not block a local
timer and progress message in the same client actor. It resumes the destination
and finishes the Terminal checks. This Unix-only stall probe preserves the native
mount's recipient identity; it does not change the production presenter.
That generic coroutine check does not establish desktop responsiveness; the
separate presenter gate above covers stalled-peer navigation. Neither establishes
transport-loss recovery or human approval persistence.
Detach/re-admission deliberately keeps both runtimes alive. Cache invalidation
travels asynchronously from the owner's detach reply and is checked with a
bounded wait. Shell processes are not restored after a runtime restart.

## Two-machine acceptance

The reviewed fixture also passed from the development machine to a destination
on the user's network. The destination ran the real Bee host and Terminal;
the client read the destination-only nonce, resized the PTY, lost control on
detach and rejoined the same Bash process with its variable intact. Both native
runtimes used the same manifest toolchain, including actor source provenance.

The opt-in LAN target requires explicit SSH and network coordinates:

```sh
make hive-lan-check NATIVE_WIPPY=.wippy/bin/bee-wippy-hive \
  HIVE_SSH=user@destination \
  HIVE_REMOTE_RUNTIME=/absolute/owned/stage/wippy \
  HIVE_HOST_ADDRESS=DESTINATION_IP HIVE_CLIENT_ADDRESS=CLIENT_IP
```

Stage the matching toolchain binary first in an owner-controlled directory on
the destination. This Linux-destination fixture creates a private temporary
directory beside that binary and removes only its test directory after verified
cleanup. It retains uncertain cleanup state and returns an error. The binary
and other existing data are preserved. The harness checks exact executable,
working directory and process start identity before signaling a remote PID;
shell quoting, bounded logs and archive errors have focused Go/race checks.

SSH stages and launches the fixture; it does not tunnel actor or TTY traffic.
Native membership and internode listeners bind actual addresses with automatic
ports. Credentials are disposable and pre-pinned, not an invitation protocol.
No global `bee` executable is installed or updated by this target. A successful
LAN fixture is still short of the user-facing target: normal `bee` launch,
supervisor discovery, workspace selection and a responsive remote desktop view.

## Fixture coordination and terminal reads

The first actual Bee remote fixture admitted its client but Terminal startup
failed. A disposable diagnostic copy exposed `process terminated`; a local open
before entering the supervisor's input loop succeeded. Inspection found the
fixture's pending `io.readline()` occupies the default single worker in
`service/terminal/tty/dispatcher.go`, which also dispatches `StartInput`.
Continuous stdout draining did not resolve that coupling.

Use actor inbox messages to coordinate active application phases; do not leave
an unrelated terminal line read pending while proving viewport startup. Production
supervisors are actor services, not stdin command interpreters. Reader/control
isolation remains a native runtime issue to verify separately; do not increase
Bee's three-second application readiness deadline to conceal it. The fixture's
stdin bootstrap is test-only and is not a proposed Hive protocol.
