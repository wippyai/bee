# Native Agent conversation recovery

The source Agent app now declares a resume schema and consumes the existing app
checkpoint/restore protocol. It persists the five continuation identity fields
and optional saved-profile identity/revision, authenticates the broker's checkpoint acknowledgement, and constructs a
fresh continuation request on restore. Source acceptance now proves graceful
continuation, interrupted-window recovery, cancellation during recovery, and
whole-node restart with a fixture Claude executable. Controlled node SIGKILL
also passes when the independently inspected native process is gone. Real-provider
cold recovery passes for Agy, Codex and Grok; Claude and surviving orphan
process trees remain unverified. The installed
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
recorded gateway binding, decode the `bee.harness.hook` payload, and refuse
recovery when no session ID is found or claims conflict. Occurrence ambiguity
remains relevant to event identity, but does not erase a validated provider
session claim. Current thread membership still governs
the read. Resolving an old binding's observations grants no use of that binding;
the new attempt needs fresh admission. The carrier plan now implements this
resolver for window profiles with `previous_attempt_id` and an empty brief.
It requires an ended predecessor and native exit plus completed cleanup.
Missing provider IDs across all eligible observations, conflicting claims or
invalid pages refuse continuation. Structured continuation still requires a
successful completed turn. Launch admission now accepts the original launch
request ID, predecessor attempt and thread in its typed `continuation` field.
It requires the saved plan digest, derives the original session identity from
that request and workspace, checks existing owner state, and
obtains fresh grants for the new attempt. The app presents a responsive
“Restoring Agent” view before asynchronous recovery. Close, resize and appearance
remain usable; cancellation prevents a later recovery result from starting a
native process. Admission refusal never launches a replacement.

### Changed-plan review — verified source, not installed

Automatic continuation keeps the saved admission digest and placement digest
fences. An authorized caller can deliberately review the current plan and call
the same admission operation with its exact `expected_plan_digest` and
`continuation.reauthorize = true`. This does not skip current-plan resolution or
grant checks. A stale digest still refuses admission before recovery effects.
The Agent resolves before admission and keeps a changed plan paused until Enter.
The installed-to-new Claude fixture passes: no replacement attempt or harness
report before confirmation, then the original application, thread, conversation
and HOME with a fresh attempt and gateway. Unchanged same-build recovery also
passes automatically. The combined full regression remains pending; this is not
yet an installed workflow or real-provider recovery proof.

Reviewed continuation may use a changed implementation of the same committed
placement binding. It does not require or invent an old placement digest, and
it never rewrites the historical preparation. The placement owner must still
report the exact predecessor, owner, action and retained session; exit and
complete cleanup are required before replacement. Driver/profile closure pins
and the committed hook conversation must still agree. Switching placement or
driver is not a retained-home transfer operation. Structured turns do not use
this review path. The replacement receives current grants, gateway configuration
and a newly measured plan.

The app's admission digest and the carrier's executable/configuration plan
digest describe different values. They are not interchangeable. Reconciliation
uses the old carrier checkpoint's own digest; review fences the new admission
plan selected by the caller.

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
files. Codex/Agy host-generated provider/hook/trust files now use atomic publication
in a retained home through the runtime PR #744 patch. Placement rechecks its
starting runner before each file and refuses configuration overlapping login
state. Publication uncertainty retains the session holder and predecessor
checkpoint. See [the filesystem contract](RETAINED_CONFIGURATION_FS.md).
Configuration delivery does not establish native process-group cleanup. The
fixture Claude continuation proof does not establish real-provider recovery.

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

`make native-agy-recovery-live-check BEE_BINARY=... AGY_BIN=...
AGY_LOGIN_FILE=...` runs an installed Agy provider twice through the same public
managed window. It reads a random token on the first turn, stops and restarts Bee,
deletes the source file, then requires exact tool-free recall through the
provider's recorded conversation. It also proves the same application, thread
and private HOME, a retired predecessor, a fresh attempt and gateway binding,
consistent first-turn tool/Stop hooks, no fabricated Bee turn success, unchanged
source login and no project provider writes. The test copies only the explicit
login file into disposable state and removes that state on every outcome.

`make native-claude-recovery-live-check BEE_BINARY=... CLAUDE_BIN=...
CLAUDE_LOGIN_FILE=...` is the equivalent checked real-Claude gate. Its first turn
must call the bound `thread_read` MCP tool and use Claude's Read tool on a random
fixture; the fixture is deleted before owner restart and the resumed turn must
recall it without tools. The target also fences application, thread, HOME,
attempt, gateway, hook, prompt-replay, process and source-login identity. It
removes ambient provider credential variables and every disposable credential
copy on all outcomes. Installed Claude 2.1.270 currently reaches this managed
launch but the copied machine OAuth is refused before a turn completes; a direct
ordinary-HOME probe reports unavailable account credit. This is an unqualified
provider row, not recovery evidence. The provider version also differs from the
current 2.1.265 manifest metadata and must be reconciled before promotion.

`make native-codex-recovery-live-check BEE_BINARY=... CODEX_BIN=...
CODEX_LOGIN_FILE=... CODEX_CONFIG_FILE=...` runs the equivalent real-Codex
gate. The first turn must call bound `thread_read` and complete a command read of
a random fixture. After deletion and owner restart, `codex exec resume` must
recall the exact token without tools or prompt replay. The gate checks stable
provider conversation, application, thread, project, HOME and CODEX_HOME; fresh
attempt and gateway identities; paired MCP hooks; unchanged source login/global
configuration and project tree; explicit provider exit status; and final native
process cleanup. It removes ambient provider credential variables and deletes
all disposable credential-bearing state. Installed Codex 0.154.0 passes this
gate against exact-source standalone `64679b3f`; the driver now declares 0.154.0
and the full row must rerun after the released runtime cut.

`make native-grok-recovery-live-check BEE_BINARY=... GROK_BIN=...
GROK_LOGIN_FILE=... GROK_CONFIG_FILE=...` runs installed Grok twice through the
same managed-window path. The first result must end with the random source token,
share its conversation ID with the committed hooks, and complete the scoped Bee
`thread_read`; after source deletion and owner restart, the resumed result must
be exactly that token with no tool hooks or prompt replay. It also proves all
five configured first-turn hooks, stable project/HOME/application/thread/action,
fresh attempt/native/gateway identity, retired predecessor, unchanged source
login and global configuration, no project configuration writes, explicit exit
status and final process cleanup. Ambient XAI credentials are removed before Bee
starts. Installed Grok 1.0.30 passes against exact-source standalone `64679b3f`;
the driver now declares 1.0.30 and the row must rerun after the runtime cut.

Agy's corrected MCP delivery declares private JSON credential fields. Placement
fills those after minting the admitted binding; the persisted template retains
only field paths and environment names. Source now republishes these admitted
configuration files with fresh binding credentials in the retained home; login
and conversation bytes are not configuration targets. The live recovery target
now provides the actual provider continuation proof. It does not prove recovery
of an interactive Agy TUI or an arbitrary surviving orphan process tree.

See [the verified filesystem boundary](RETAINED_CONFIGURATION_FS.md).
Lua already exposes file sync;
`os.Root` follows in-root symlinks, and `lstat` followed by rename is not enough
to guarantee session-parent identity across the operation.

## September 13 — real Agy cold continuation candidate

The combined source candidate now treats hook occurrence deduplication separately
from its validated provider conversation claim. All eligible claims must agree;
predecessor ownership, driver/profile identity, retained session, binding and
process cleanup checks still apply. Ambiguous occurrences do not establish turn
success or become deduplicated events.

A real Agy print-mode harness inside a managed Agent window now passes cold
continuation: the first turn reads a random fixture token, Bee stops and restarts
against the same state, the source token file is deleted, and a new turn recalls the exact token without
replaying the original task. The fresh attempt and binding commit a Stop hook
with no PreToolUse or PostToolUse observations. Conversation, HOME, app and thread identities stay
the same; the replacement attempt and gateway binding are fresh. The previous
candidate failed to restore with these session-bearing ambiguous hooks. The
fixture uses a private login copy and deletes its temporary state after the run.
This proves actual provider conversation continuity, not interactive Agy TUI
rendering or arbitrary orphan-tree recovery.

The same candidate passes offline fresh boot/restart/reconnect, native executable
acceptance and the existing Claude fixture restart gate. Its 851 unit cases pass;
full combined source/pack acceptance passes and global `7d9182cb` is installed. See the
current journal and global-build handoff for installed revision status.

The earlier actual Codex TUI probe stopped at an account usage-limit refusal.
The checked cold-recovery gate described above now supersedes that limitation
with two completed real turns; no Bee production workaround or login change was
needed.
