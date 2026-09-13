# Native Agent conversation recovery

The source Agent app now declares a resume schema and consumes the existing app
checkpoint/restore protocol. It persists the five continuation identity fields
and optional saved-profile identity/revision, authenticates the broker's checkpoint acknowledgement, and constructs a
fresh continuation request on restore. Source acceptance now proves graceful
continuation, interrupted-window recovery, cancellation during recovery, and
whole-node restart with a fixture Claude executable. Controlled node SIGKILL
also passes when the independently inspected native process is gone. Real-provider
cold recovery and surviving orphan process trees remain unverified. The installed
revision is tracked separately in [global build](GLOBAL_BUILD.md).

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
obtains fresh grants for the new attempt. The app presents a responsive
“Restoring Agent” view before asynchronous recovery. Close, resize and appearance
remain usable; cancellation prevents a later recovery result from starting a
native process. Admission refusal never launches a replacement.

An interrupted attempt first requires observed native exit. Recovery advances
the carrier epoch, commits the rebound checkpoint, seals gateway intake and
reconciles recoverable hook deliveries before settling the old attempt as
uncertain. It creates no successful turn and replays no task prompt. Gateway
HTTP 202 means durable intake, not thread commitment: revocation terminally
rejects unclaimed rows with a durable reason; already-claimed rows remain
recoverable under epoch fences. An unresolved drain refuses replacement.

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

The checked runtime PR #743 patch adds optional typed `TerminalSession:pid()`
over runtime `291f5c6b708c80afe5da07f3223767573b4d183f`. Startup is asynchronous;
the window waits within its admitted start budget and records Linux process-group
identity, start ticks and boot ID before publishing running. The PR remains
unmerged. Terminal completion alone does not prove that descendants with redirected
output have left the group. Placement independently proves the required group
absent before recording cleanup complete; missing or uncertain proof refuses reuse.

Driver configuration delivery now separates fresh argument literals from protected
files. Placement measures the host inputs, renders using its actual home path
and freezes the output with the attempt. Claude uses inline MCP/settings JSON,
so a new attempt can select fresh endpoint data without replacing conversation
files. Codex still uses protected provider/hook/trust files and refuses changed
content in a retained home. The selected Lua FS surface lacks atomic replacement
and non-following opens; no remove-and-recreate workaround is introduced.
Configuration delivery does not establish native process-group cleanup. The
fixture Claude continuation proof does not establish Codex retained-file
replacement or real-provider recovery.

The app queues its new checkpoint only after native startup and the thread's
start receipt succeed. A plan, preparation or startup refusal therefore does not
replace the previous checkpoint. It consumes the authenticated result in its
normal input/hook loop; no checkpoint wait blocks terminal input or close.
A refused or unconfirmed save adds “Save unconfirmed” to the title while the
running Agent remains usable. The broker continues owning the last acknowledged
resume record. The app rejects an unsupported resume schema before admission.

## Acceptance

`make window-recovery-check` covers actor interruption, responsive cancellation
and durable rejection of an unclaimed accepted hook. `make native-agent-recovery-check
BEE_BINARY=...` uses the public Agent picker and the actual saved workspace
checkpoint across node restart. `make native-agent-crash-recovery-check
BEE_BINARY=...` sends SIGKILL through the captured node pidfd, inspects the old
native identity before restart and requires continuation; safe refusal does not
count as a passing continuation. Neither test deletes databases or cleans up an
orphan before observing the recovery outcome. Both use fixture providers and
verify retained HOME, conversation/app/view identity, fresh attempt and binding,
and absence of fabricated success or prompt replay.

Agy's corrected MCP delivery declares private JSON credential fields. Placement
fills those after minting the admitted binding; the persisted template retains
only field paths and environment names. Retained content still requires exact
replay, so changed binding credentials do not authorize overwriting a retained
configuration. Agy cold recovery remains unavailable until safe configuration
replacement is implemented and verified.

See [the verified filesystem boundary](RETAINED_CONFIGURATION_FS.md) before
implementing retained configuration replacement. Lua already exposes file sync;
`os.Root` follows in-root symlinks, and `lstat` followed by rename is not enough
to guarantee session-parent identity across the operation.
