# Gateway hooks

Gateway hooks carry bounded lifecycle observations from a managed harness to its
bound thread. They are not a control channel: a hook cannot approve work, alter
prompt execution, settle a turn, extend an attempt or create authority.

## Endpoints and credentials

Claude-compatible hooks use POST /hook/{action}. Codex-compatible hooks use
POST /hook/{action}/mcp with one hook tool. GET /hook/{action}/{event_id}
returns the known state of one submission.

The gateway issues a separate hook credential alongside an admitted tool
credential. A tool credential cannot use a hook endpoint, and a hook credential
cannot call an MCP tool. The endpoints check the binding, action, Host, bearer,
payload bounds and selected event before accepting an observation.

An accepted HTTP submission returns an empty success response and an event ID.
An accepted MCP submission returns a small text result naming that ID. Refusals
are status responses or JSON-RPC errors. No response carries a decision,
continuation flag, prompt content or control instruction.

## Durable intake

The gateway stores an accepted observation as queued. Queued means the gateway
accepted it; it does not mean the observation is in the thread. The status
endpoint reports queued, committed, rejected or unknown after its retention
horizon.

Each binding has a bounded queue. An identical replay resolves to the original
occurrence; a replay with changed normalized content conflicts. The stored
record contains an event identity, selected identifiers and enumerated fields.
Unbounded source content is not stored. Content-bearing fields contribute only a
size and digest used for replay detection.

## Carrier lifecycle

The carrier claims queued rows using its current epoch, writes each as a
bee.harness.hook observation through its ordinary thread commit path, and then
acknowledges the committed rows. A claim can be redelivered after a lost reply.
A replacement carrier may take over a lower-epoch claim. The thread record's
event key makes a retried commit idempotent.

Sealing ends intake while preserving accepted rows for bounded draining.
Revocation invalidates credentials and rejects only unclaimed rows; claimed rows
remain available for reconciliation because a thread commit may already have
succeeded before its acknowledgement was lost. At normal settlement the carrier
seals, drains within its configured budget, rejects unclaimed work and revokes
the binding. Expiry, listener replacement and fenced carrier loss follow the
same rule.

Hook events remain observations even during shutdown. They never replace the
carrier's terminal result or its explicit close and drain rules.

## Provider configuration

The launch policy selects the closed hook event set. Drivers write only the
provider configuration required for that selected set and deliver the hook
credential through the runner's selected environment. Configuration never
contains credential bytes. Provider capability and event support are part of
the driver contract; unsupported hooks are not advertised.

Run the focused checks with:

    make gateway-check
    make managed-launch-fixture-check
