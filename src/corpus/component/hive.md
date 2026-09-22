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
route is the current operation seam; it does not provide public enrollment,
headless-node launch or destination package installation.

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
