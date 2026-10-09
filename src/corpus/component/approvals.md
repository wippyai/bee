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

States run `pending` to `decided`, `expired`, `withdrawn`, `superseded` or `invalidated`; the thread
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
delivery worker (`bee.approvals.service:worker`) never touches the incarnation.
A request that projects onto a thread is bound when it is made: the requester
must be an active owner or participant, an attempt proposal must name an
attempt the thread prepared under its action, and the binding is persisted so
delivery never depends on later membership. Consumption belongs to the effect
owner holding `bee.approvals.consume`, bound to the exact proposal digest and
one effect key. Retention forgets a request only after its lifetime plus the
retention window, with every delivery acknowledged; an idempotency key older
than that horizon creates a fresh request.

Contract `2` stores separate Request, Decision, Grant and Effect records.
The public surface and event names are defined in [the approval lifecycle
contract](../docs/approvals.md#public-contract). Every request has a durable
requester notification obligation, including requests without a thread.

Effect consumers register `meta.type: bee.approvals.effect-consumer` with
`destination`, `operation_ref` and `worker_name`. The authority discovers these
registrations through registry metadata. `effect_queue` reads terminal,
uncompleted effects for one destination; `phase=ready|ended|all` selects its
work. `effect` records claims, starts, completions and reconciliation. A
completion acknowledges the consumer's durable terminal events in the same
transaction. Missing receivers keep their events for restart and catch-up.

Gateway installation (`gateway.installation`), publication
(`gateway.publication`) and governed activation (`gov.activation`) are domain
adapters. They keep Hub/governance receipts and validate bindings, exact
artifacts and live destination state before acting. Denial, expiry, withdrawal,
supersession and invalidation cancel waiting effects. Admitted effects remain
queued until their receipt is reconciled; identical receipts replay and changed
receipts conflict. The request's decision deadline is independent of effect
admission. Once the effect is admitted, later deadline expiry does not revoke
its receipt or authorize another effect.

Approver policies are host-owned under `bee.security.approvals:approver_policies`:
each names its approvers and the longest request or approval-window lifetime it allows. An
approver needs both the `bee.approvals.decide` action on the workspace and a
place in the policy. Workspace membership alone exposes nothing. The
operations `feed_snapshot`, `feed_read_after`, `read`, `decide` and `withdraw`
declare Hive operations under `hive: policy`; the host ceiling decides what a
mapped remote principal may call. Grant administration (`grant_window`) has no
Hive operation.

| Namespace | Responsibility |
|---|---|
| `bee.approvals` | Public contract (`bee.approvals:contract`) |
| `bee.approvals.binding` | Callable approval operations, the local contract binding `bee.approvals.binding:local` and the domain library `bee.approvals.binding:service` |
| `bee.approvals.persist` | Request, decision, grant, effect, history, inbox, incarnation and durable event/thread outbox storage |
| `bee.approvals.migrations` | Approval schema migrations |
| `bee.approvals.env` | Host-linked approver-policy reference and its reader |
| `bee.approvals.types` | Runtime lease proposal and ceiling decoder (`runtime_lease`), window-grant decoder and capped duration choices (`windows`) |
| `bee.approvals.service` | Authority and outbox worker processes and their services |
| `bee.approvals.inbox.app` | The Approvals inbox application, the approver named by the stock approver policies |

Approval views expose `requesting_session` when the authenticated requester is a SessionRef. The read-only `bee.approvals.binding:attention_count` accepts `{workspace_id}` and returns `{ok=true,value={count=N}}` for pending, unexpired requests. It requires the exact `bee.approvals.attention` grant for that workspace and provides neither request details nor decision authority.

The Approvals owner exposes runtime approval leases through `bee.approvals.binding:runtime_lease` (also `local.runtime_lease`). Its operations are `grant`, `check`, `use`, `revoke`, `list`; requests carry `operation`, `lease_ref?`, `workspace_id?`, `tool?`, `input_digest?`, `effect_key?`. An ordinary permission approval with operation proposal ref `bee.approvals:runtime-lease` carries `{subject, workspace_id, tool, input_digest, expires_ms, max_uses}`. The digest is lowercase SHA-256; expiry is within 30 days and uses are 1..10000. Grant consumes that exact approved proposal, revalidating its owner incarnation after a restart. Leases and per-effect receipts persist in the Approvals database.

Check/use require consume authority and the exact subject/workspace. Use additionally checks tool/input digest, expiry, revocation and the use bound; the same effect key replays only the same exact operation. Persisted runtime authority survives an owner restart. Subject or workspace manager may revoke; list exposes only the caller's records in one workspace. Saved profile references cannot transfer authority. The shared permission exchange uses matching references before requesting another decision and rechecks the same receipt before dispatch/recovery; Deny still wins.

The host-selected counts-only `bee.approvals.binding:node_summary` accepts an
empty object and requires `bee.approvals.summary` on `node`. It returns
`{ok=true,value={pending_approvals=N}}` for pending, unexpired requests owned by
this native node. It exposes no request contents or decision authority.

Person approval windows settle ordinary permission requests through `decide`
and `decide_batch`. `window_ttl_ms` is a positive duration
within the current policy's `max_ttl_ms`; denial, question responses and invalid
or excessive durations cannot create a window. The batch-level duration applies
to every item atomically.

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
admitted application definition. 

Expired windows are pruned after the owner's retention horizon once no retained
settlement references them; an active window keeps its source request retained.

`decide` also accepts `window_permanent = true` for a permission without a
response, mutually exclusive with `window_ttl_ms`. The host approver policy
must explicitly set `allow_permanent: true`; omission denies it. This uses the
existing central window store and `grant_window` list/revoke API, with a
non-expiring horizon (`windows.PERMANENT_UNTIL_MS`, 9999-12-31T23:59:59Z).
Sessions uses these central windows for exact peer/workspace/scope consent.
Its protected consent adapter records the person's approval evidence; the
receiving Hive dispatcher reads central active windows for every dispatch.
