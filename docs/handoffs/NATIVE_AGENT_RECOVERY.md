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

The native placement store admits one unfinished attempt for each retained
owner/session home. A second attempt is refused while the predecessor is
intended, live, uncertain, or merely exited with cleanup still pending or
uncertain. Reuse begins only after the existing cleanup path has proved the
required scope gone and recorded cleanup complete. This prevents concurrent
writes to retained provider files; it neither deletes them nor claims to prove
PTY identity. Repeating an already admitted request still replays that attempt.

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
the new attempt needs fresh admission. The carrier plan now implements this
resolver for window profiles with `previous_attempt_id` and an empty brief.
It requires an ended predecessor and native exit plus completed cleanup.
Ambiguous occurrences provide no candidate ID; conflicting eligible IDs or
invalid pages refuse continuation. Structured continuation still requires a
successful completed turn. Launch admission now accepts the original launch
request ID, predecessor attempt and thread in its typed `continuation` field.
It requires the saved plan digest, derives the original session identity from
that request and workspace, checks existing owner state, and
obtains fresh grants for the new attempt. The app's saved-state consumer remains
unimplemented, so this is not public cold-restart recovery.

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

Two remaining execution boundaries were inspected on runtime
`291f5c6b708c80afe5da07f3223767573b4d183f`. `attach_terminal` consumes an
unstarted exec process; its returned terminal session exposes only send, close,
done and status. The consumed process no longer exposes its PID, while the
proxy starts it asynchronously. Completion waits for the leader and PTY output;
it does not prove that a descendant with redirected output has left the group.
Bee's window adapter consequently has no recorded group identity for its
existing cleanup operation. Reuse must keep refusing incomplete cleanup until
the native terminal lifecycle provides the required identity or cleanup proof.

Retained configuration is currently byte-identical replay only. Exact-runtime
inspection confirms the Lua FS surface lacks atomic rename/replacement and
non-following opens; remove followed by exclusive creation is not a safe refresh.
Claude 2.1.269 offers a possible driver-owned alternative through inline
`--mcp-config`, `--settings`, `--strict-mcp-config` and explicit settings sources.
An offline parse check is not integrated-driver or provider acceptance. Codex
0.154.0 offers configuration overrides but no verified alternate hook-file
location. These are investigation results, not new runtime requirements or
callable Bee driver options.
