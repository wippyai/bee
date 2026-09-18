# Local approvals acceptance

The state of durable approvals on one node as of 2026-09-09: the owner
(`bee.approvals`), the harness permission exchange through the carrier, and
the local inbox application (`bee.inbox:app`). Each requirement from
[APPROVALS.md](../APPROVALS.md) and the review rounds is mapped to the proof
that covers it; what is excluded is listed at the end. Cross-node projection,
remote Terminal admission and managed-launch activation are not accepted
here.

## Proof to requirement

| Requirement | Proof | Where |
|---|---|---|
| Request bound to a canonical proposal digest under a host approver policy; replay on key, conflict on a changed request | binds a request to its proposal digest | `tests/lua/approvals/service_test.lua` |
| Two approvers race, one decision, every other outcome honest | two eligible approvers race | `service_test.lua`; two viewers race through the inbox model | `tests/lua/inbox/surface_test.lua` |
| Owner-enforced expiry; only the requester withdraws; consumption bound to one effect | expiry, withdrawal, consumption | `service_test.lua`; expiry while viewing | `surface_test.lua` |
| Unauthorized readers and approvers refused; bounded inbox | inbox shows approvers their policy's requests and nothing to anyone else | `service_test.lua`; outsider refused inbox and details | `surface_test.lua`; unlisted actor under the admitted scope | `tests/lua/inbox/admission_test.lua` |
| Changed action parameters authorize nothing | changed input refused at consumption, decision unchanged, new approval for the change; revised operation is another proposal; inbox shows the approved proposal | `tests/lua/inbox/changed_proposal_test.lua`; changed executable measurement or plan refused before dispatch, decision kept | `tests/lua/harness/permission_carrier_test.lua` |
| Restart after decision commit before delivery; repeated delivery once | crash between thread commit and outbox acknowledgement | `service_test.lua`; decision through a stopped worker, restarted authority and reopened inbox | `tests/lua/inbox/recovery_test.lua` |
| Disconnected viewers: no cursor past an unacknowledged page, nothing repeated | lost page and replayed pages | `recovery_test.lua` |
| Revoked execution authority before execution | consume refused without the consume grant, decision unchanged | `recovery_test.lua` |
| Authority restart fences consumption; revalidation under the current incarnation | stale authority fenced | `service_test.lua`; authority restart between revalidation and consumption | `permission_carrier_test.lua`; headless owner restart | `recovery_test.lua` |
| Headless owner recovers requests, decisions and pending delivery with no inbox open | headless owner restart | `recovery_test.lua` |
| Thread projection exactly once through the narrow ingress | projects requests and decisions through the worker exactly once | `service_test.lua`, `tests/lua/threads/approvals_test.lua` |
| Harness permission exchange: intent, approval, consumption, one write, acknowledgment, every crash boundary, takeover, runner loss, late decision | fixture matrix | `permission_carrier_test.lua`; real executable matrix | `tests/lua/harness/claude_control_test.lua` |
| Inbox: explicit decisions at the viewed revision and digest after the shell's confirmation; conflicts show the committed outcome; unknown answers recovered by reading; hostile text bounded | model, frame, surface | `tests/lua/inbox/model_test.lua`, `view_test.lua`, `surface_test.lua` |
| Inbox scope: store denied, only the owner's four methods, eligibility follows the actor | admitted-scope probe | `admission_test.lua` |
| Inbox boots under the broker as the local viewer and closes deciding nothing | broker smoke | `tests/inbox_app.py` |

## Boundaries stated

- Every local desktop application acts as the client's actor (`bee.local`);
  admission grants calls, never an identity. Separate inbox instances are not
  separate approvers; eligibility is the host's approver policy naming the
  actor. Multiple authenticated desktop viewers are not covered.
- The owner's methods open the approvals store on an application's behalf;
  `bee:workspace_storage_boundary` therefore does not list that store, and
  the application binding holds no store access. `tests/architecture.py`
  asserts that shape.
- The contract has no decision-revocation transition: revocation is proven
  as revoked execution authority, with the decision's history unchanged.
- An approval binds the proposal digest; the carrier's plan digest covers
  the launch policy, binding, profile, launch, permission adapter and
  acceptance, configuration and executable measurement, and a recovered
  carrier re-measures before any dispatch. Directly exercised by fault
  injection: a changed input, a revised operation, a changed launch policy
  value and a changed executable. Protected by that shared digest path but
  not separately fault-injected: binding and profile measurements, the
  adapter and acceptance digests, the configuration and the launch
  arguments. Digest coverage is evidence of the mechanism, not a separate
  end-to-end proof for each of those fields.
- `exchange_refusal` on a plan permits recovery and the recording of the
  refusal only: a recovered carrier authenticates its attempt and acquires
  its carrier epoch as before, keeps the durable plan it recovered, closes
  the exchange with the refusal and settles. It never permits fresh
  admission, replacement of the durable plan, or dispatch under the
  rejected measurements.

## Excluded

- Cross-node inbox projection and combined inboxes across owners.
- Remote Terminal admission through an approved scope (supervisor seam).
- Managed-launch production enablement (pinned-runtime acceptance, see
  `MANAGED_LAUNCH_ACCEPTANCE.md`).
- Per-viewer actors for desktop applications.
- Remembered policies, multi-approver rules and trigger graphs.

## Commands

```
make test                                  # pinned runtime, all suites
python3 tests/inbox_app.py                 # the inbox under the broker
```
