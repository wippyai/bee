# Bee approvals

The approval owner for one node. A request binds an exact proposal, its
canonical digest, the requesting operation owner and a host-selected approver
policy; a decision settles the pending revision by compare-and-set for that
digest; the requester consumes an approved decision under one effect identity
before acting. Every change commits its history row, its inbox change and,
when the request projects onto a thread, its outbox row in the same
transaction. The worker delivers outbox rows through the narrow thread
ingress `bee.threads.binding:append` under a stable event id, and
acknowledges a row only after the ingress replies; a lost acknowledgement
repeats the delivery and the thread replays the same record.

A transition record states the outcome but owes nobody anything, and only a
message commit creates the recipient obligation the delivery layer carries. So
every terminal change of a thread-bound request enqueues a second outbox row
beside its transition, under `<approval_id>:<revision>:notice`: a
`notification` addressed to the requester naming the outcome and the approval.
A denial, an expiry and a withdrawal are announced as an approval is, because
what leaves an agent waiting is the silence rather than the answer. The notice
is a side effect of the decision and never a condition of it: a thread that
refuses it is retried, and an exhausted row stays visible with its last error
while the decision it announces stands.

States run `pending` to `decided`, `expired` or `withdrawn`; the thread
projection records them as `approved`/`denied`, `expired` and `cancelled`.
Expiry is enforced by the owner when a decision or withdrawal arrives and by
the worker on every pass. Delivery retries and retention are separate from
request lifetime: an exhausted delivery stays visible and a manager returns it
to the queue; settled requests are forgotten after the retention window
together with their deduplication receipts.

The authority service starts `bee.approvals.service:authority`, which registers
the stable owner name `bee.approvals.authority` before any request is served;
a restart is a new incarnation. An effect owner presents the incarnation it observed; an
observation of an older authority, or a decision made under one, returns
`REVALIDATE` naming the current incarnation. The effect owner re-checks the
decision in its own domain and calls `revalidate`, which records the
validation under the current incarnation; only then does `consume` proceed.
Another restart invalidates that validation again. The
delivery worker holds its own lease name and never touches the incarnation.
A request that projects onto a thread is bound when it is made: the requester
must be an active owner or participant, an attempt proposal must name an
attempt the thread prepared under its action, and the binding is persisted so
delivery never depends on later membership. Consumption belongs to the effect
owner holding `bee.approvals.consume`, bound to the exact proposal digest and
one effect key. Retention forgets a request only after its lifetime plus the
retention window, with every delivery acknowledged; an idempotency key older
than that horizon creates a fresh request.

The host-authorized Hub installation worker reads its bounded queue through
`bee.approvals.binding:installation_effects`, which returns approved installation
requests whose effect result is not complete. After Hub returns an applied or
terminal result, the requesting attempt records its bounded status outcome through
`bee.approvals.binding:complete_installation_effect`. The operation checks the
requester, workspace consume authority, proposal digest and consumed effect key;
an identical completion replays and a different result conflicts. A worker
restart can therefore submit an already-consumed request again until the Hub
outcome is recorded, without reading the approvals table from the gateway store.
Hub retains the complete receipt, including migration details; the approval
owner stores only the bounded state and message needed for status.

The host-authorized Hub publication worker reads its bounded queue through
`bee.approvals.binding:publication_effects`, which returns approved publication
requests whose effect result is not complete, and records its bounded outcome
through `bee.approvals.binding:complete_publication_effect` under the same
requester, digest and effect-key checks. A committed decision wakes the
publication worker, so an approved publication uploads without any status
poll.

Approver policies are host-owned under `bee.security.approvals:approver_policies`:
each names its approvers and the longest request or approval-window lifetime it allows. An
approver needs both the `bee.approvals.decide` action on the workspace and a
place in the policy. Workspace membership alone exposes nothing. Approvals are
node-local: `decide` and `withdraw` are never Hive-exposed, so a mapped remote
principal reads the feed and a request but cannot decide one, and the host
ceiling names only the feed, read and replica operations.

| Slice | Responsibility |
|---|---|
| root `bee.approvals` | Contract, dependencies and host-selected requirements |
| `binding/` | Callable approval operations, including the host-authorized installation effect queue and completion, and the Hive policy operations |
| `persist/` | Approval request, history, inbox, incarnation and thread-projection outbox storage |
| `migrations/` | Immutable approval schema ledger |
| `service/` | Owner domain operations, authority and outbox worker processes |
| `types/` | Window-grant decoder, exact scope measurement and capped duration choices |

Approval views expose `requesting_session` when the authenticated requester is a SessionRef. The read-only `bee.approvals.binding:attention_count` accepts `{workspace_id}` and returns `{ok=true,value={count=N}}` for pending, unexpired requests. It requires the exact `bee.approvals.attention` grant for that workspace and provides neither request details nor decision authority.

The Approvals owner exposes runtime approval leases through `bee.approvals.binding:runtime_lease` (also `local.runtime_lease`). Its operations are `grant`, `check`, `use`, `revoke`, `list`; requests carry `operation`, `lease_ref?`, `workspace_id?`, `tool?`, `input_digest?`, `effect_key?`. An ordinary permission approval with operation proposal ref `bee.approvals:runtime-lease` carries `{subject, workspace_id, tool, input_digest, expires_ms, max_uses}`. The digest is lowercase SHA-256; expiry is within 30 days and uses are 1..10000. Grant consumes that exact approved proposal, revalidating its owner incarnation after a restart. Approval migration 5 stores leases and per-effect receipts in the Approvals ledger.

Check/use require consume authority and the exact subject/workspace. Use additionally checks tool/input digest, expiry, revocation and the use bound; the same effect key replays only the same exact operation. Persisted runtime authority survives an owner restart. Subject or workspace manager may revoke; list exposes only the caller's records in one workspace. Saved profile references cannot transfer authority. The shared permission exchange uses matching references before requesting another decision and rechecks the same receipt before dispatch/recovery; Deny still wins.

The host-selected counts-only `bee.approvals.binding:node_summary` accepts an
empty object and requires `bee.approvals.summary` on `node`. It returns
`{ok=true,value={pending_approvals=N}}` for pending, unexpired requests owned by
this native node. It exposes no request contents or decision authority.
Applications reach Hive-wide counts through the approved Hive telemetry status
contract.

Person approval windows settle ordinary permission requests through the existing
`decide` and `decide_batch` operations. `window_ttl_ms` is a positive duration
within the current policy's `max_ttl_ms`; denial, question responses and invalid
or excessive durations cannot create a window. The batch-level duration applies
to every item atomically. Migration 6 (`approval_windows`, M5) appends the grant
table and request settlement references; migrations 1–5 remain unchanged.

Each grant belongs to the request's authoritative native node, exact workspace,
requester, policy and measured proposal scope. Ordinary scopes include the
entire canonical proposal. A validated managed-permission payload retains the
attempt, action, plan, adapter reference/digest, tool and exact input digest;
only `permission_request_id` and `correlation_id` identify the individual
exchange and are excluded from window scope. Extra payload fields require a
full-proposal match. Every new matching permission request settles through the
same history, inbox and thread outbox transaction, with the grant's signer and
an `allowed_by_grant` reference. Effect consumption and incarnation revalidation
remain required. A changed scope, issuer policy removal, reduced policy ceiling,
expiry or revocation prevents new automatic settlements.

The source approval ID is the grant ID. A grant records its issuer actor and
admitted application definition, creation time, expiry and revocation time. The
source request remains retained while its window is active. Restart preserves
the grants and records each new automatic approval under the new incarnation.
`grant_window` accepts `operation=list`, `workspace_id`, optional `after_id` and
returns up to 64 active grants, `more` and `next_id`; `operation=revoke` accepts
`grant_id` and optional matching `workspace_id`. Both require workspace decision
authority, and list/revoke are restricted to the issuing actor or the same
admitted application definition. Grant administration has no Hive exposure;
remote feed readers see settlements on the authoritative node without acquiring
its decision authority.

Expired windows are pruned after the owner's retention horizon once no retained
settlement references them; an active window keeps its source request retained.
