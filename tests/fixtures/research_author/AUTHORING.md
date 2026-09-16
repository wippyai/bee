# Performance research artifact

Create a real Bee app and an encoder candidate using the admitted MCP tools.
You may read the harness's own saved tool-output files when it directs you there.
All edits go into your caller-owned Governance workspace, then freeze for review.
You have no registry publication, approval or activation capability.

`workspace` requests use `operation`, `workspace_id`, and for mutations
`expected_revision` plus `idempotency_key`. Create at revision 0. Each successful
put advances the revision. Write `entries.json`, then freeze at its new revision.
Keep the returned digest and report it through `thread_message`.

`entries.json` is a JSON list of complete registry entries. Use inline Lua source,
not file URLs. Example library shape:

```json
{"id":"bee.research.demo:canonical","kind":"library.lua","data":{"source":"..."}}
```

Native registry entries use `id`, `kind`, optional `meta`, and required `data`.
Put `source`, `method`, `modules`, `imports` and other configuration inside
`data`; top-level YAML shorthand is not the registry API and is refused.
For this process app:

```json
{"id":"bee.research.demo:app","kind":"process.lua","data":{"source":"...","method":"main","modules":["tty","process","channel","time","funcs","json","uuid"],"imports":{"client":"bee.application:client","appearance":"bee.desktop:appearance"}},"meta":{"type":"bee.application","application":{"api_version":1,"title":"Performance Research","icon":"R","lifetime":"view","revision":"1","instance_policy":"multiple","group":"Tools","role":"research","resume_schema":"research.v1","restart_policy":"manual"}}}
```

The application/model/view topics show the actual Timeline source and API calls.
Reuse their lifecycle, appearance and resize conventions. Keep the
research app small; it needs one thread selected by its first launch argument,
defaulting to `research-performance`, and the measurements in that thread.
Do not reference Timeline's private model/view or grant your own security policy.
Declare every native module and library import you actually use.

Measurements are JSON objects inside a thread message's `body.content.text`:

- `schema`: `bee.research.measurement@1`
- `benchmark`: `canonical-json@1`
- `label`: `baseline` or `candidate`
- `source_sha256`: exact measured source digest
- `units`: `ns/op`
- `samples`: array of positive finite numbers (seven samples)
- `iterations`, `corpus_size`, `checksum`: positive integers
- `correct`: boolean; `outcome`: `passed` or `invalid`
- optional `correctness_error`: text

Only accept message records with `body.content.text`; bound the text before
decoding. Require the exact schema, benchmark, units, labels and field types:
seven positive finite samples, positive integer counters, a lowercase 64-hex
source digest, and consistent correctness/outcome. Reject malformed values
rather than coercing them. Bound optional error text.

Decode and bound incoming values before rendering. Show actual samples or their
median as a bar comparison, units, sample count, source identity and correctness.
Show an empty state until measurements arrive. Never insert example measurements.
Duplicate thread delivery must not duplicate a measurement. A saved cursor alone
cannot restore already acknowledged measurements. Persist the bounded two-slot
projection with its applied cursor. Prefer `bee.threads.service:read_after`
(`thread_id`, `cursor`, `limit`) and the read-only `bee.threads.delivery:watch`
for this dashboard: a stale checkpoint then safely replays records instead of
skipping records acknowledged by a separate subscription. Checkpoint send is
not a durable commit receipt. Reset malformed checkpoints as a whole; validate
slot sequences against the saved cursor. Do not grow an unbounded set of every
observed sequence. Keep input and resize responsive.

The encoder's native baseline fails integer 9007199254740992: `%g` receives a
Lua integer wrapper and emits `%!g(lua.LInteger=09007199254740992)`. Plain Lua
does not reproduce that runtime formatting behavior. A candidate must pass the
provided exact-output corpus on Bee's native runtime, including invalid values.
Ordinary unescaped strings are common in the fixed timing corpus. Investigate
performance without weakening validation or changing canonical bytes. Do not
claim that your candidate passed until the host executes it after review.
