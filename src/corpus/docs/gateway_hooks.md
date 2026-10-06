# Gateway hooks

Gateway hooks carry bounded lifecycle observations from a managed harness to its
bound thread. For an
interactive Session, the authenticated turn boundary also pulls queued Work and
returns its prompt and owner-set sender as additional context. Stop records that
interactive Work as completed; StopFailure records failure. Managed executor
turns retain their driver-terminal and placement-exit settlement path. An admitted
interactive PermissionRequest can also wait for an Allow or Deny from Needs you.
The existing approvals owner records the decision; hook metadata grants no authority.

The hook HTTP handlers are `bee.gateway.api:*`; queue, claim, acknowledgment,
rejection, and sealing calls are `bee.gateway.binding:*`. The host owns the
listener and routes and selects the policies that permit each call.

## Endpoints and credentials

Claude-compatible hooks use POST /hook/{action}. Codex-compatible hooks use
POST /hook/{action}/mcp with one hook tool. GET /hook/{action}/{event_id}
returns the known state of one submission.

The gateway issues a separate hook credential alongside an admitted tool
credential. A tool credential cannot use a hook endpoint, and a hook credential
cannot call an MCP tool. The endpoints check the binding, action, Host, bearer,
payload bounds and selected event before accepting an observation.

An accepted HTTP submission returns its event ID and, when interactive Work is
ready, a context-only `hookSpecificOutput`. MCP returns the same context as JSON
text content; otherwise it carries empty text content. An admitted PermissionRequest
returns `hookSpecificOutput.decision.behavior` (`allow` or `deny`) through the
driver's declared HTTP or MCP hook transport. Refusals are status
responses or JSON-RPC errors. The gateway derives SessionRef, workspace and attachment from
the authenticated binding; payload fields cannot choose the receiving identity.

## Permission answers

`bee.harness.permission:exchange` owns detection-to-decision progression for
carrier streams, external executor turns and interactive hooks, using
`bee.harness.permission:adapter` as the single request decoder. The host must
select an adapter, executable-bound acceptance record and approver policy.
Saved preferences may select `bee.permission_answers`: `provider` leaves the
provider in charge, `ask` waits for Needs you, and `deny` answers denied directly.
Ask and deny require a host-accepted transport; unsupported routes reject them.
Carrier requests bind an existing prepared attempt. Session turns use the
approval owner's operation proposal, pinned to the native attempt, session,
plan and permission input digest; their canonical turn journal supplies the
execution checkpoint. The requester must be a participant in the bound thread.
Allow is consumed against the exact proposal before dispatch. Denial, expiry,
withdrawal and timeout never consume an effect or grant consent. Permission
intent, decision and response progress are checkpointed with thread observations.
Hook delivery is recorded as prepared with acknowledgment unproven.

CLI descriptors declare `capabilities.permission_answers` for `window`,
`first_turn` and `resume`. Claude uses stream-json control requests for headless
turns and PermissionRequest HTTP hooks for windows. Codex windows use its
PermissionRequest MCP hooks. Bee's `codex exec --json` route has no approval
response channel; app-server JSON-RPC approvals require a different driver mode.
Agy, Grok, Muse and OpenCode keep provider approval behavior in Bee's current
modes; their descriptors state the unavailable answer channel.  No deny is
translated into a permission bypass.

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



Managed hook events remain observations during shutdown and never replace the
executor terminal result.

## Provider configuration

The launch policy selects the closed hook event set. Drivers write only the
provider configuration required for that selected set and deliver the hook
credential through the runner's selected environment. Configuration never
contains credential bytes. Provider capability and event support are part of
the driver contract; unsupported hooks are not advertised.
