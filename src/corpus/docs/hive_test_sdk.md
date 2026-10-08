# A project test SDK across Hive nodes

A Hive application owns its public service and operation names. Its source
application calls an admitted copy on another node through `bee.hive:hive`.
The destination executes the operation as that installed application, inside
its own approved scope. Nodes authenticate the sending process; request fields
cannot supply a user, actor, workspace authority or caller identity.

## Start with the proven manifest

Read the overlay guide section `hive_sdk`:

```json
{"operation":"guide","section":"hive_sdk"}
```

That section includes the complete `entries.json` for overlay `test_sdk`, with
namespace `app.test_sdk`. Copy its JSON list into the overlay before freezing.
The shared manifest defines:

- `app.test_sdk:app`, the admitted application;
- `app.test_sdk:trait`, an `agent.trait` that teaches the local and peer tools;
- `app.test_sdk:run`, the `test_sdk_run` agent tool and exposed `test-sdk.run`;
- `app.test_sdk:peer`, the `test_sdk_peer` agent tool whose app code calls its copy;
- `app.test_sdk:configuration_test`, an associated, exposed application test;
- four `ns.requirement` entries requesting `agent.tools`, bounded `hive.call`,
  and separate `hive.expose` grants for the worker and test.

The guide and two-node fixture use `bee.gov.traits:hive_sdk_example` to produce
the same nine entries. The guide suite freezes that exact example and sends it
through production destination preflight, including all four capability
requirements. It asserts readiness and preparation of destination-local
approval. The e2e fixture installs copies on two independent nodes, runs the
source application's peer tool and verifies the returned worker PID belongs
to the destination node.

Replace `runner-node`, `destination-workspace` and `author-node` in the example
with actual node and workspace identities approved by the person. The incoming
audience is the authenticated sending **node**, not an app-supplied user or PID.
`hive.call` grants list exact nodes, workspaces, application addresses, services
and operations; they do not admit wildcards. Each destination approves its own
exposure and runtime authority. An open audience authorizes the peer node, not
one source application. Bee's existing application base permits process
messages. The `hive.call` capability bounds calls through its host facade; it
is not a firewall for raw messages to known PIDs. Receiver exposure and legacy
service owner authorization remain authoritative.

The executable example implements project configurations in Lua. For `ci`,
it multiplies each input by three; `{1,2,3}` yields 18 on the peer. For
`development`, the multiplier is one. Replace that computation with your
project's checks. To access a checkout or run a host program, separately
request the required `workspace.files.read` and `process.exec` capabilities,
and use their granted host facades. A Hive grant adds no file, database,
execution or credential authority.

## Publish and install the copies

Author and freeze `entries.json` through the overlay tool. Request local
delivery, inspect the destination's preflight diagnostics and wait for the
person's approval in Needs you. To share that version, publish its immutable
artifact through the approved publication workflow. At another node, use the
Library to stage the verified publication, review its local preflight and
approve installation there. Source publication alone installs nothing.

An operation has explicit `application_ref`, `hive_service` and
`hive_operation` metadata with a name, revision, input/output schemas and
`effect`. It is discovered through those declarations and installed ownership.
It is callable only while both admission and its exposure grant remain live,
its audience admits the authenticated peer node, and the exposure scope grants
`hive.expose.<mode>` on the exact operation. `open` still requires these checks.
`policy` remains fail-closed until trusted subject mappings exist. Package
operations without an installed overlay remain fail-closed; the runtime rejects
an overlay taking an entry already owned by another overlay.

## Call the peer from application code

The example's peer function imports `hive = bee.hive:hive` and calls:

```lua
local result, err = hive.call({
    node = "runner-node",
    workspace_id = "destination-workspace",
    application = "app.test_sdk:app",
    service = "test-sdk",
    operation = "run",
    arguments = {configuration = "ci", inputs = {1, 2, 3}},
    timeout = "10s",
})
if err then error(err) end
```

A uniquely granted destination workspace may be omitted. The receiver
validates input, invokes the function inside its admitted application scope,
validates output and sends a correlated reply. The host facade accepts replies
only from the resolved destination supervisor and enforces one deadline for
lookup and waiting. Arbitrary legacy service operations are outside this facade.

If the copies have different definition IDs, use the immutable source address:

```lua
application = {
    source_node = "author-node",
    source_workspace = "test_sdk",
    component = "app.test_sdk",
}
```

Grant that address as `author-node/test_sdk/app.test_sdk` in the `applications`
parameter. The destination resolves it through its live governed admission and
host-selected activation profile. An approved alias is another option; an
artifact cannot approve its own alias. Versions do not form part of the address.

## Let an agent discover tools and run tests

Omitting `node` preserves local behavior and direct application tool aliases.
To inspect a peer's tools, call MCP `app_tools` with:

```json
{"node":"runner-node"}
```

The list includes only live `agent.tools` functions also exposed to this
sending node, with their input/output schemas. Invoke a listed tool explicitly:

```json
{"operation":"call","node":"runner-node","tool":"test_sdk_run","arguments":{"configuration":"ci","inputs":[1,2,3]}}
```

Use MCP `tests` on the same node for the associated, exposed suite:

```json
{"operation":"list","node":"runner-node","application":"app.test_sdk:app"}
{"operation":"run","node":"runner-node","application":"app.test_sdk:app","idempotency_key":"ci-suite-1"}
{"operation":"status","node":"runner-node","run_id":"<run_id returned by run>"}
```

The run is stored at that node and uses Bee's existing application test runner.
Its result includes the node, progress and final cases. Status belongs to the
authenticated peer node that started the run and rechecks live exposure;
revoking admission or exposure removes access. The app cannot read the run store.

## Retry mutations and update versions

Declare `effect: read` for a pure operation. Omission defaults to `mutation`,
which requires a bounded `idempotency_key`. Keep the request and key identical
when retrying. A durable destination receipt binds the key to the authenticated
peer node, workspace, application, service and operation. Completed retries
replay their result; changed arguments or operation contracts conflict. Pending
or interrupted receipts report **outcome unknown** and never redispatch.
Receipts are bounded and are not automatically evicted to permit duplicate
execution. A timeout stops waiting; it does not undo effects.

A new version is a new freeze and verified immutable publication. Stage and
review it independently at each destination, then request local activation.
Governance may reuse installed approval when authority does not widen and
no pending migrations remain. That reuse does not follow publications
automatically. `follow_source` consent and reconciliation are unavailable.
Receipt, source selection and active installation remain distinct.
