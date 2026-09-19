# Subscriptions and owner-qualified send

Step 5 of [the build sequence](BUILD_SEQUENCE.md): the contract for a
consumer's subscription session and for a message sent to another node's
thread. Astra's round 24 boundaries are binding; the transport-independent
pieces are built and proven, and nothing here forwards across nodes yet.
Production cross-node capabilities stay `false` until two-runtime proofs
cover commit-before-reply loss, replacement, duplicate delivery and stale
acknowledgment.

## Owner-qualified references

A thread reference across nodes is the Hive owner reference
`{node_id, service_id = "bee.threads", resource_ref = <thread_id>}`. The
destination owner authenticates and commits; a lookup failure is a refusal,
never a fallback to a local thread of the same name.

## Send

| Request field | Meaning |
|---|---|
| `thread_id` | the destination thread on the owner node |
| `caller_node_id`, `idempotency_key` | the request identity, stable across forwarding and retries |
| `payload_digest` | sha256 of the canonical message body, computed by the sender |
| `message` | the message body as the thread records it |
| `context` | optional causation and correlation, as for `record` |

The destination owner runs `send` as the local actor destination
admission established for the forwarded principal, a member the thread
owner admitted explicitly. The seam rules Astra set in round 25:

| Field | Authority |
|---|---|
| Principal | The destination verifies the assertion and maps `(trusted issuer, subject)` to a local actor through the host's `bee.hive.supervisor:principal_mappings` (`bee.hive.supervisor:thread_admission`), the actor derived from the pair so no table edit retargets it; the principal's own scope must grant `hive.invoke` on the operation; `owner_ref.resource_ref` binds the thread the payload addresses; no actor id is accepted from the payload. Identity stays stable across supervisor restarts; incarnation fences assertions and sessions rather than minting a member per boot. Linking identities across issuers needs explicit owner policy. |
| Caller node | Derived from authenticated supervisor ingress; the payload value must match. It names transport origin, not the principal. |
| Scope | Destination host policy selects a bounded scope; thread membership and operation permissions still apply. |
| Context | Correlation and provenance only; it supplies no membership and elevates nothing. |

The request identity is `(thread_id, principal, caller_node_id,
idempotency_key)`: the command's actor is the principal and its key is
`send/<caller_node_id>/<idempotency_key>`, so two subjects on one node
never collide or read each other's results. The canonical request digest
covers every caller-controlled field, context included. The same identity
with the same request replays the committed record, a different request
under it is `CONFLICT`, a digest that does not match the body is
`INVALID_ARGUMENT`, and a non-member is `DENIED`. The reply carries
`record_id`, `sequence`, `caller_node_id` and `payload_digest`.

`send_status {thread_id, caller_node_id, idempotency_key}` answers the
same principal, under current read authorization, with the committed
record or `{committed = false}`. `committed = false` means no matching
commit exists at that read; an earlier request may still be in flight, so
it is not proof of non-execution. An ambiguous timeout is resolved by
status or by replaying the identical request, which destination
deduplication keeps safe, never by a fresh send under a new key.

## Subscription session

The thread owner retains cursor and page-acknowledgment authority through
`subscribe`, `page`, `ack_page`, `resume` and `unsubscribe`, with the owner-authorized `close_subscription` and `forget_subscription` for abandoned subscriptions (see [delivery](THREAD_DELIVERY.md)). The consumer
holds a session (`bee.threads.delivery:session`) with these transitions:

| From | Event | To | Rule |
|---|---|---|---|
| attached | transport loss | detached | nothing durable changes; the outstanding page stays outstanding at the owner |
| detached | reconnect, same owner incarnation and lease generation | attached | continue; the owner's cursor is taken, not the consumer's memory |
| detached | reconnect, newer owner incarnation or lease generation | resume_required | `resume` installs a new lease and fences every earlier page |
| detached | reconnect, subscription closed or replaced | closed or reset_required | subscribe anew |
| any | reconnect with an older generation, or the same generation with a cursor behind the session's | unchanged | a stale summary under the owner's order (incarnation, then lease generation) changes nothing, rolls no cursor back and triggers no replacement |
| any | reconnect with another `owner_authority` | reset_required | incarnations compare only within one durable owner authority (`bee_thread_owner.authority_id`, minted once per store); a replaced node or a reset store is another authority and requires reset and re-admission, never a numeric comparison |
| resume_required | resume reply | attached | only a reply newer than the held lease is installed |
| attached | page under another lease generation | attached | dropped as stale traffic |
| attached | page while one is outstanding | attached | refused until the outstanding page is acknowledged |
| attached | `ack_page` reply | attached | the only way the cursor moves; names `page_id` and its exact `scanned_through` |

A transport reconnect never acknowledges a page or advances progress.

## Proof

`tests/lua/threads/send_test.lua` covers replay, conflict, digest mismatch,
a second node under the same key, denial and status; `session_test.lua`
covers the transitions above; the existing subscription suite covers
one outstanding page, exact acknowledgment, filters as identities and
resume fencing. Forwarding over the supervisor seam and the two-runtime
proofs are not built.
