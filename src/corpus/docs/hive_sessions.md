# Agents and applications across bees

The person chooses when agents on one bee may see or message agents on another.
Allowances belong to the receiving bee and workspace. Each bee approves its
peers independently; joining a hive creates no agent allowance.

In Sessions, press A for Allowances. Select a bee identity, a scope and a
duration (one hour, 24 hours, seven days or permanent), then apply. The same
form answers a first request in Needs you. The question binds the bee and
workspace; its decision checks the recorded revision and proposal digest.
Sessions displays active grants and their expiration, and provides Revoke.
Every allowance is a central Approvals window on the receiving bee. Sessions
stores no grant rows or expiry rules. The receiver reads the central active
windows; expiry and revocation in Approvals remove access immediately.
Permanent consent is an explicitly permitted central window until revoked.
The protected Sessions consent adapter records the person or Needs you
request as decision evidence and creates the exact peer/workspace/scope
permission in Approvals.

Revocation withdraws a still-pending question. A denied or revoked allowance
does not create repeated background prompts.

List-only consent permits session state, history and the catalog. Message and
await consent additionally permits sending work and observing/joining its
reply. Open consent also permits launching and controlling sessions. Every
operation remains inside the receiving workspace's session authority and
admitted definitions. The receiving supervisor authenticates the peer and
rechecks its live allowance and exact exposed operation at dispatch.

## Agent tools

Existing names stay the same. Omit `node` for local sessions, or choose a peer:

```json
{"node":"bee-peer"}
```

Pass that object to `session_list` or `session_catalog`. To send and observe:

```json
{"node":"bee-peer","session":"<session ref from that bee>","input":"Check the baseline","operation_key":"review/123"}
{"node":"bee-peer","subject":"<work ref from session_send>","timeout_ms":10000}
```

These are the inputs to `session_send` and `session_await`. Keep the exact refs
and node. A missing allowance refuses the call and files one question at the
receiver. Continue only after the person allows the requested scope there.

## Application code

Import `sessions: bee.threads.sessions.client:sessions` and use
`sessions.client{node = "bee-peer"}`. Contract clients can supply `node` on all
Sessions operations and catalog `list`. The host routes them through the same
`bee.hive:hive` facade apps already use:

```lua
local reply, err, code = hive.call{
    node = "bee-peer",
    application = "bee.harness.app:app",
    service = "sessions",
    operation = "list",
    arguments = {},
    timeout = "10s",
}
```

A caller needs the existing session grant's outbound permission. That
permission reaches the facade; the destination's allowance authorizes access
there. For mutations, `idempotency_key` equals the operation's `operation_key`.
Operations and discovery aliases come from registry metadata. Applications
need no registry or supervisor lookup permission.

Sessions declares its contracts as host-owned Hive policy exposures. The host
supplies a source agent's own session identity, and the receiver binds it to
its authenticated bee. Each source agent has a separate destination operation
identity. Arbitrary installed applications continue to use their own bounded
`hive.call` capability and exact exposure grants, as in `docs/hive_test_sdk`.

## Durable replies and proof

Threads commits a peer request and its WorkRef together. Its canonical inbox
records keep the source node/thread/action, request record and correlated
reply record. `in_reply_to` identifies the request; a replay of the same
mutation key returns the same work. Await reads the original bee's durable
work result through Hive. Its `pending`, `blocked`, `uncertain` and `ready`
branches keep their existing meaning. A transport timeout is outcome unknown
for a mutation, and permits only identical-key recovery.

`tests/e2e/hive.sh` retains the existing two-node SDK and display proof and
adds a Sessions proof. A fixture agent on alpha first receives denial when it
lists beta. After beta grants message consent, alpha lists beta's agent, sends
work, replays its receipt, and awaits the deterministic fixture driver's
reply. The nodes use an isolated fixture home and explicit fixture paths;
the proof uses no real model.
