# Native Agent conversation recovery — next integration unit

Proposal, not a shipped recovery contract. The existing app checkpoint/restore
protocol remains the shell boundary; the structured carrier already retains
provider resume references. Launch definitions can now name one host-selected
`session_resource`; the Agent binding allows obtaining its own grant for that
resource. The interactive Agent app still declares no resume schema and does
not recover provider conversations.

An interactive Agent must retain both the provider conversation ID and its
session files. Use the existing placement session_ref/home resource and the
existing app resume_schema/checkpoint_result protocol. Save during operation,
not only on close; only the broker's successful checkpoint result establishes
that the app's resume record committed.

The app checkpoint identifies its admitted thread/action/attempt and retained
session resource. It is opaque app data, never stored authority. The owner must
verify those references and current profile/resource grants before recovering
the provider reference from the attempt's durable data. Native PIDs, viewport
mounts, tokens and credential bytes are not resume data.

Recovery must obtain a fresh host-selected execution scope. A checkpoint cannot
request a service actor or recover an earlier, stronger grant. Higher-authority
services keep their permissions inside their own boundary and authorize each
user or agent request against the exact resource. Changed or removed grants
must refuse recovery without altering the saved conversation or replaying input.

Hook observations can capture the provider's bounded session ID under the
admitted binding. They cannot establish readiness or logical success by naming
a SessionStart or Stop event. Preserve commit uncertainty across gateway cleanup
before using the observations as recovery evidence.

The existing `bee.threads.service:read_after` operation can recover that ID
from committed observations; no second provider-session store is required.
Use its action filter and bounded pages, advancing by `scanned_through`.
An eventual resume consumer must check the exact predecessor attempt and its
recorded gateway binding, decode the `bee.harness.hook` payload, and reject
ambiguous or conflicting session IDs. Current thread membership still governs
the read. Resolving an old binding's observations grants no use of that binding;
the new attempt needs fresh admission. This resolver is not yet implemented.

Interactive close normally produces a cancelled/uncertain attempt, unlike a
structured successful turn. Do not fake a successful terminal outcome to pass
the structured continuation helper. An explicit interactive resume may reopen
the recorded conversation without resending its original brief or retrying any
uncertain input/effect. Current provider/profile and retained-home compatibility
must be checked; incompatible or missing session files leave recovery unavailable
without deleting the acknowledged checkpoint.

Acceptance must cover a committed provider identity surviving node restart,
reattachment without a duplicate process while the app is still alive, ordinary
close versus node shutdown, changed/revoked profile or resource, lost checkpoint
acknowledgement, stale-hook replies, no automatic prompt replay, and two Agent
instances retaining separate conversations. Keep the existing manual/automatic
restart-policy distinction; no separate persistence manager is needed.
