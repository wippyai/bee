# Bee approvals

The approval owner for one node. A request binds an exact proposal, its
canonical digest, the requesting operation owner and a host-selected approver
policy; a decision settles the pending revision by compare-and-set for that
digest; the requester consumes an approved decision under one effect identity
before acting. Every change commits its history row, its inbox change and,
when the request projects onto a thread, its outbox row in the same
transaction. The worker delivers outbox rows through the narrow thread
ingress `bee.threads.approvals:append` under a stable event id, and
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

Approver policies are host-owned under `bee:approver_policies`:
each names its approvers and the longest lifetime a request may ask for. An
approver needs both the `bee.approvals.decide` action on the workspace and a
place in the policy. Workspace membership alone exposes nothing.

| Slice | Responsibility |
|---|---|
| root `bee.approvals` | Contract, stable local binding, linked host references, default database and the owner domain library |
| `binding/` | Callable approval operations, including the Hive policy operations |
| `persist/` | Durable thread-projection outbox |
| `registry/` | Linked database and host-policy readers |
| `migrations/` | Immutable approval schema ledger |
| `service/` | Authority and outbox worker processes |
