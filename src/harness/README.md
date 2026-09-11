# bee.harness

Execution contracts for admitted work: the catalog that discovers driver
bindings, and the carrier that composes a driver, the stream-json transport,
a placement and the thread contracts into one attempt.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.harness` | Module root |
| `bee.harness.carrier` | `provenance`, `checkpoint`, `settle`: the pure rules of [the carrier contract](../../docs/CARRIER.md); `policy`: the host-selected launch policy with executable bindings and required capabilities; `machine`: one attempt from plan to receipt over an injected IO; `process`: the production carrier process, no fault hooks (a test-only entry wraps the same run with barriers); `capabilities`: bounds and the takeover rule |
| `bee.harness.launch` | `definitions`: exact decoding and digest of `bee.launch_definition` entries; `admission`: `resolve` (a measured plan pinning definition, binding, profile, policy and catalog generation, no effects), `admit` (for the authenticated requester: thread by policy, an attempt-bound resource grant and credential projections obtained in the requester's own authority, all keyed on the request id so a retry replays), `start` (spawns the carrier as the requester, resumes when a checkpoint exists, refuses a settled request). Public `launch.resolve`/`launch.start` wiring lives in the core launch lane |
| `bee.harness.permission` | `adapter`: the pure permission exchange rules (request identity, proposal, qualified keys, response encoding, pending ambiguity, transcript consistency); `acceptance`: the host acceptance record binding driver, profile, adapter and fixture measurements. A profile is eligible with `permission_exchange: {mode: adapter, adapter_ref, adapter_digest}` pinning a `harness.permission_adapter` entry the catalog measures from the same snapshot; enabling needs a matching acceptance record proven by the live fixture runner in `tests/lua/harness/acceptance_test.lua` and, for Claude, by the real executable in `claude_acceptance_test.lua` and `claude_control_test.lua`. Request fields and response fields are dotted paths, a request may name a separate acknowledgment id (Claude echoes `tool_use_id`, not `request_id`), and a terminal denial may be correlated. Both Claude profiles pin `bee.driver.claude:permission_adapter`; the acceptance record (`bee.permission-acceptance@2`) also carries placement's `executable_digest`, compared at plan time; shipped launch policies enable no exchange, so a terminal permission-denied result remains terminal |
| `bee.harness.catalog` | `classify`: pure classification of a driver binding with its resolved profiles and methods; `catalog`: one immutable registry snapshot (`registry.snapshot()`), every `harness.driver` binding, declaration, method target and the host's `bee:harness_activation` entry read from that same snapshot, classified and marked activated |
| `bee.harness.window` | Private broker-launched native-window actor. It decodes one bounded launch envelope, admits it as the broker-authenticated application actor, shares planning and attempt preparation with the carrier, then consumes the broker's sole terminal grant to own one native PTY. It records only `uncertain` completion unless the application explicitly closes, which records `cancelled`. It has no command metadata or public catalog binding. |

## Rules

A binding is compatible when it implements `bee.driver:driver` with three
bound functions, its `profiles_ref` names a `harness.profile` entry that
points back at it, the declaration decodes under `bee.driver:profile`, and
at least one profile (the default among them) uses a supported protocol. Two
compatible bindings with one `driver_id` are both marked ambiguous. Digests
measure the entry and the declaration only and say so; executable closures
are measured at admission. Compatible is not activated, and activated is not
admitted: the host lists activated bindings in `bee:harness_activation`, and
launch admission decides per request. That entry is a strict
`bee.harness-activation@1` declaration containing only distinct `bindings`.
A missing or malformed declaration activates nothing and adds a catalog
diagnostic; it cannot publish, admit or authorize execution. A read capped below the number of
bindings is `complete: false`: an unseen binding could share a `driver_id`
with a visible one, so `usable` resolves nothing from it.

Catalog compatibility matches the implemented execution paths: `stream-json`
for batch/session profiles, and `pty` for window profiles. Fixture metadata does
not change compatibility. Host activation and protected launch admission remain
required; compatibility alone does not publish a launch route or authorize it.

Launch resolution and admission read the definition, catalog and policy from
one registry snapshot. The library's `admission.read(snapshot, ref, mode)` lets
a composing host reuse its pinned snapshot without side effects; ordinary
`resolve` and `admit_request` pin internally. A retained snapshot describes its
own generation even after registry changes. Reading that plan grants no
permission and does not promise that a later execution will use stale code.
Managed launch requests accept no environment map, including an empty one.
Nonsecret environment and driver options come from the selected host policy;
credentials are projected separately by the broker. The lower carrier and
placement contracts remain separate execution primitives.

## Host binding

The `process_host` requirement links `bee.harness:carrier_host_ref.host_ref`.
Launch start resolves that process host before admission and refuses an unlinked
or missing host. The bundled host defaults to `bee:workers`; another assembly
can supply its own host. This reference grants no permission: the host-selected
spawn policy must independently allow the carrier and selected host.

The entry policies still bind `bee:carrier_policy` and
`bee:launch_spawn_policy`. Independent installation must supply those reviewed
policies; host binding alone is not Hub or Hive installation acceptance.
