# bee.hive

The cross-node protocol of Bee, as agreed in `docs/HIVE_PROTOCOL.md`. Six
terms: Principal, Owner, Operation, Request, Grant, Session. Every call passes
the caller's supervisor and, when remote, the destination supervisor; the owner
decides; a grant may open a direct session.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.hive` | `bounds` (identifiers, objects, lists, timestamps), `types` (envelopes and decoders), `catalog` (exposure and interfaces), `client`, and the supervisor host |
| `bee.hive.telemetry` | The first open operations: `presence`, `stats`, `catalog_list` |
| `bee.hive.supervisor` | The supervisor: hello, admission, forwarding, guarded dispatch, epochs (Astra's lane) |

## Exposure

An operation is a `function.lua` entry with `meta.hive: open | approval |
policy` and a `meta.hive_operation` block (revision, title, bounded input and
output schemas, limits). The host ceiling is an ordinary security policy with
actions `hive.expose.<mode>` over entry ids; the catalog includes an operation
only when the ceiling admits its mode, and the supervisor resolves it again at
admission. Interfaces are `registry.entry` entries with `meta.type:
hive.interface` naming `operation_ref`, fixed arguments and allowed arguments;
they narrow and never widen.

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
