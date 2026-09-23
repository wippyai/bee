# bee.hive

The cross-node protocol of Bee, as defined by the runtime Hive owner. Six
terms: Principal, Owner, Operation, Request, Grant, Session. Every call passes
the caller's supervisor and, when remote, the destination supervisor; the owner
decides; a grant may open a direct session.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.hive` | `bounds` (identifiers, objects, lists, timestamps), `types` (envelopes and decoders), `client`, and the supervisor-host provenance resource |
| `bee.hive.registry` | `catalog`, the registry read model for operation exposure and interfaces |
| `bee.hive.telemetry` | The first open operations: `presence`, `stats`, `catalog_list` |
| `bee.hive.supervisor` | The root-owned supervisor: hello, admission, forwarding, guarded dispatch, epochs (Astra's lane) |
| `bee.hive.desktop` and `bee.hive.host` | Root-owned desktop integration and host-selected default service composition |

## Host composition

`bee.hive.host:supervisor_service` is the default `process.service`. It starts
`bee.hive.supervisor:main` on `bee.hive:supervisor_host` with an empty
`configured_nodes` list, so a fresh Bee can route local calls while remaining
portable and offline. Its lifecycle actor and policies are selected by the
host composition, not by an ordinary application.

The `bee/hive` component supplies portable protocol values, the catalog read
model, client, telemetry operations, and the protected supervisor-host resource.
It does not select or start a supervisor, desktop, or host policy; the Bee root
keeps those integration and authority decisions.

An admitted host overlay may replace that service input with peer node IDs and
an optional validated desktop configuration. TLS, seeds, ports and native
membership settings remain outside the registry; they are not service input.

## Exposure

An operation is a `function.lua` entry with `meta.hive: open | approval |
policy` and a `meta.hive_operation` block (revision, title, bounded input and
output schemas, limits). The host ceiling is an ordinary security policy with
actions `hive.expose.<mode>` over entry ids; the catalog includes an operation
only when the ceiling admits its mode, and the supervisor resolves it again at
admission. Interfaces are `registry.entry` entries with `meta.type:
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
policies or destination, and metadata cannot grant them. This generic policy
route is the current operation seam; it does not provide headless-node launch
or destination package installation.

## Joining a hive

A node joins another node's hive with one invite; no address, port or key file
is typed. The operations, all implemented by the Bee root's supervisor
(`src/hive/supervisor/invites.lua`) and native launch (`native/launch`):

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
`bee:hive_invite_policy` (action `hive.invite`); without it every invite
operation is refused. Invites live in the supervisor process, so an owner
restart voids every outstanding invite and an unknown invite is refused.

The invite line is `bee-hive://ID:SECRET@HOST:PORT/NODE?key=FINGERPRINT`:
the owner's join listener (bound on the mesh advertise address with an
automatically selected port), its node and the sha256 of its internode identity
key. The joining node dials the listener over TLS 1.3, accepts it only when its
certificate key matches FINGERPRINT, proves its own identity key with its client
certificate, and only then sends the secret. The hive node redeems through its
supervisor, pins the joiner's identity key, certifies the joiner's mesh TLS key
under its own authority and returns its gossip address, the mesh secret and its
authority pool. The joiner pins the hive node and records the hive; its owner
then boots with the hive's secret, the hive node's gossip address as a seed, the
certified leaf and the hive's authorities beside its own.

Both nodes admit each other through the host enrollment: the owner writes
`bee.hive.supervisor:enrollment_nodes` as `{nodes, peers}` from its local client
keys and its pinned peers, and resolves the same keys for the runtime's
`internode.peer_key_source`. Peers are configured and discovered, so their
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
join, because one mesh has one secret. The owner binds and advertises loopback,
so a hive spans the state directories of one host; selecting a host address
for a hive across machines is a proposal.

## Client

`client.open()` returns a client whose `call(owner_ref, target, input,
options)` sends a Call to this node's supervisor, found by the LOCAL name
`bee.hive.supervisor` and trusted only when its PID runs on
`bee.hive:supervisor_host` on the client's own native node. A name that resolves
to a foreign supervisor is refused. Replies are accepted only from that PID with the
matching request id; a timeout returns `DEADLINE_EXCEEDED` and never cancels
owner execution.

## Testing

`make test` runs `tests/lua/hive`: envelope decoders and digests, catalog
ceilings under narrowed scopes, malformed declarations, interface narrowing
from one snapshot, telemetry output bounds, and the client against a real
fake-supervisor process on the supervisor host (absent supervisor, wrong
host, stale and impostor replies, malformed replies, deadlines). Support
entries carry `meta.type: test_support`.

Do not name a variable `interface`: it is a reserved word of the typed Lua
grammar, and until the runtime pin carries runtime PR 691 the parse error is
only visible in the lint summary count.
