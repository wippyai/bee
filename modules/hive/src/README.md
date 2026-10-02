# bee.hive

The cross-node protocol of Bee, as defined by the runtime Hive owner. Six
terms: Principal, Owner, Operation, Request, Grant, Session. Every call passes
the caller's supervisor and, when remote, the destination supervisor; the owner
decides; a grant may open a direct session.

Cluster telemetry lives in the optional `bee/hive-telemetry` package
(`bee.hive.telemetry`); this module keeps the protocol itself lean.

## Ownership

| Namespace | Responsibility |
|---|---|
| `bee.hive` | Protocol envelopes and shared types; dependency and host requirement declarations |
| `bee.hive.types` | Peer/enrollment/invite values, route selection, workspace queries and page decoding |
| `bee.hive.binding` | Client, authenticated dispatch, policy admission, workspace operations and feature senders |
| `bee.hive.exposure` | Operation exposure and interface catalog |
| `bee.hive.security` | Principal identity and workspace-call policy template |
| `bee.hive.service` | Supervisor, display command and remote viewer processes |
| `bee.hive.desktop` | Desktop bridge, catalog, grant/session handling and presentation helpers |

Hive workspace listing and desktop `list` share
`bee.hive.types:workspace_query` for label, cursor and page-size validation.
The listing handler validates a dense, bounded catalog page and requires the
local node identity before returning results.

## Host composition

The root selects `bee.hive.service:supervisor_service`, which starts
`bee.hive.service:supervisor` on the native-known
`bee.hive.service:supervisor_host` with an empty `configured_nodes` list.
Its lifecycle actor remains `bee.hive.supervisor`. A fresh Bee routes local
calls without transport credentials or network settings in the registry.
The host selects the implementation's private protocol imports and function
grants through `bee.deps:hive` parameters; package metadata grants no authority.

The root retains native process hosts, supervisor service selection, protected
principal mappings and adapter/audience tables. An admitted host overlay may
replace service input with peer node IDs and a validated desktop configuration.
TLS, seeds, ports, native membership, pinned identities and invites remain
outside the registry; they are not service input.

Moving the three process definitions appends exact-reference conversions to the
Placement, Sync, Gateway, Resources and Credentials ledgers. Existing migration
SQL, app IDs, native hosts, enrollment, mapping IDs, topics and schemas remain
unchanged. Workspace operation requests use owner service `bee.hive.binding`;
owner migrations convert that field only inside structured `owner_ref` values.
Apply this source move through a full node restart. Hive supervisor handoff and
service generation rollback remain proposals.

## Exposure

An operation is a `function.lua` entry with `meta.hive: open | approval |
policy` and a `meta.hive_operation` block (revision, title, bounded input and
output schemas, limits). The host ceiling is an ordinary security policy with
actions `hive.expose.<mode>` over entry ids; the catalog includes an operation
only when the ceiling admits its mode, and the supervisor resolves it again at
admission. A package exposes its operations through the `hive.expose`
capability instead: its request names the operations, a mode and audiences,
and the install grant writes a policy over exactly those operation ids into
the `bee.security.hive:hive_exposure_scope` group the supervisor loads. Open
dispatch additionally admits only the peers in the host's
`bee.hive.supervisor:exposure_audiences` table for a listed operation.
Interfaces are `registry.entry` entries with `meta.type:
hive.interface` naming `operation_ref`, fixed arguments and allowed arguments;
they narrow and never widen.

Policy operations use the same generic route with an additional destination
authorization check. The host exposes an exact operation through
`hive.expose.policy`; the destination supervisor then resolves its configured
`bee.hive.supervisor:principal_mappings` entry, maps the authenticated issuer
and subject pair to its derived member actor and configured policy IDs, and
checks that mapped actor's scope grants `hive.invoke` for the operation. Only
after those checks does it call the owner function, rechecking the operation
revision, input digest and output contract. A request cannot choose its actor,
policies or destination, and metadata cannot grant them.

A feature-owned operation whose admission is domain-specific (a thread send, a
replica receipt) routes through the same generic supervisor. The host selects a
`bee.hive.supervisor:operation_adapters` row mapping the operation reference to
the admission worker in the package that owns the feature; the supervisor
authenticates the peer and dispatch, and the worker still runs under the
policies its package declares. The supervisor itself keeps only authenticated
routing and the host-selected grant table, not the per-feature adapter code.

## Joining a hive

A node joins another node's hive with one invite; no address, port or key file
is typed. The operations, all implemented by the Hive supervisor
(`service/main.lua` and `types/invites.lua`) and native launch (`native/launch`):

| Operation | Principal and route | Effect |
|---|---|---|
| `bee.hive.join:invite` (`bee hive invite`) | enrolled local client of the owner | mints a single-use invite that lives 15 minutes; the supervisor keeps only the secret's digest |
| `bee.hive.join:invites` (`bee hive invites`) | enrolled local client | lists recorded invites as pending, used, revoked or expired |
| `bee.hive.join:revoke` (`bee hive revoke INVITE_ID`) | enrolled local client | settles a pending invite so it is never redeemed |
| `bee.hive.join:peers` (`bee hive peers`) | enrolled local client | lists the Hive peers and whether each holds an established Session |
| `bee.hive.join:redeem` | the owner's native join listener, host `bee.hive:join_host` on the same node | consumes a pending invite for the joining node |
| `bee hive join INVITE` | the joining node's operator, while its owner is stopped | redeems the invite and starts the owner in the hive |
| `bee hive leave NODE` | the node's operator | retires the peer's pin; the Session ends |

Every supervisor operation also requires the host policy
`bee.security.hive:hive_invite_policy` (action `hive.invite`); without it every invite
operation is refused. Invites live in the supervisor process, so an owner
restart voids every outstanding invite and an unknown invite is refused.

The invite line is `bee-hive://ID:SECRET@HOST:PORT/NODE?key=FINGERPRINT`
with up to eight URL-escaped `&c=KIND,SCOPE,ENDPOINT` hints:
the owner's join listener (bound on the mesh advertise address with an
automatically selected port), its node and the sha256 of its internode identity
key. The joining node dials the listener over TLS 1.3, accepts it only when its
certificate key matches FINGERPRINT, proves its own identity key with its client
certificate, and only then sends the secret. The joiner races candidate TLS
handshakes and sends the single-use secret over the first verified path. If no
path verifies, the error names each candidate and failure. The hive node
redeems through its
supervisor, pins the joiner's identity key, certifies the joiner's mesh TLS key
under its own authority and returns its gossip address, the mesh secret and its
authority pool. The joiner pins the hive node and records the hive; its owner
then boots with the hive's secret, the verified path's IP and hive node's gossip
port as a seed, the certified leaf and the hive's authorities beside its own.

Both nodes admit each other through the host enrollment: the owner writes
`bee.hive.host:enrollment` as `{nodes, peers}` from its local client
keys and its pinned peers, and resolves the same keys for the runtime's
`internode.peer_key_source`. This entry belongs to the native owner's process-local
registry overlay, created after the supervisor publishes readiness; it is not
package content or durable registry history. A package update cannot replace
live enrollment with an empty default. Client departure and pin retirement still
update the same enrollment and revoke mounts through the existing supervisor.
Peers are configured and discovered, so their
supervisors complete the hello exchange and hold a Session; local clients reach
the desktop bridge and the invite operations only. Exposure levels are
unchanged: a peer reaches the operations the catalog exposes, as any configured
node does. Every owner runs its mesh over internode TLS, keeps its gossip port
across boots and seeds each pinned peer's last gossip address, so either node
can restart and rejoin without a new invite. `make hive-join-check` boots two
nodes from their own state directories and proves the join, both sessions,
restarts of both nodes, refused used and revoked invites and a refused retired
peer. A node that stops without leaving the mesh (a crash) can lose its
supervisor name to its own previous incarnation in the runtime's eventual name
registry, and its peers then address a process that no longer exists; that
recovery depends on a runtime fix. Retiring a pin refuses new
internode connections and ends the Session; the runtime does not fence an
established connection.

A node that already joined a hive, or that other nodes joined, refuses to
join, because one mesh has one secret. The owner picks the address it
advertises to the mesh itself: a Tailscale address when one is present,
otherwise the first non-virtual LAN interface address, otherwise loopback when
the node is alone. It persists the pick in `hive/advertise` and reads it back on
the next boot, repicking when the stored address is no longer assigned locally,
so a DHCP lease change or a Tailscale toggle never advertises a stale address.
The local descriptor still uses loopback aliases for same-machine clients. Both
sides of a join keep the path it proved: the joiner adopts the IP the inviter
observed on the authenticated join TCP when this host owns it, and otherwise
records itself in `hive/nat` and publishes `internode_dial=out`; the join
listener records the local address a remote peer's join arrived on in
`hive/reached` and advertises it in preference to the automatic pick, so a peer
that reached the LAN address keeps using it when the pick is a Tailscale
address. A member is dialed at its membership address, so the pick is also the
internode endpoint the runtime dials. A running owner republishes the dial
direction through the runtime's membership metadata when its address changes
and rewrites each pinned peer's `.addr` seed from cluster `NodeJoined`,
`NodeLeft` and `NodeUpdated` events. The runtime carries a copy of memberlist
gossip over connected internode links, so a peer reached in only one direction
keeps its link. The
[reachability guide](../../../docs/operations/hive-reachability.md) describes
the remaining runtime work.
Peer membership also grants desktop access: every pinned peer may reach this
node's desktop in Hive Manager, still subject to that peer's live host
enrollment. `bee hive leave NODE` revokes the grant by retiring the pin. A
statically configured node (`desktop.allowed_nodes`) remains separate from
these revocable peer grants.

## Client

`client.open()` returns a client whose `call(owner_ref, target, input,
options)` sends a Call to this node's supervisor, found by the LOCAL name
`bee.hive.supervisor` and trusted only when its PID runs on
`bee.hive.service:supervisor_host` on the client's own native node. A name that resolves
to a foreign supervisor is refused. Replies are accepted only from that PID with the
matching request id; a timeout returns `DEADLINE_EXCEEDED` and never cancels
owner execution.

## Testing

`make test` runs `tests/lua/hive`: envelope decoders and digests, catalog
ceilings under narrowed scopes, malformed declarations, interface narrowing
from one snapshot, and the client against a real
fake-supervisor process on the supervisor host (absent supervisor, wrong
host, stale and impostor replies, malformed replies, deadlines). Support
entries carry `meta.type: test_support`.

Do not name a variable `interface`: it is a reserved word of the typed Lua
grammar, and until the runtime pin carries runtime PR 691 the parse error is
only visible in the lint summary count.
