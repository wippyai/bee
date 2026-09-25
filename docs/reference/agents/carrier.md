# Carrier contract

The carrier turns one placement attempt's byte streams into durable thread
records. It owns the driver protocol and logical turn state for that attempt;
the thread owner persists records and checkpoints, and placement owns the
executor, private directories and cleanup. Read [threads](../threads.md),
[placement](../../../modules/placement/src/README.md) and [approvals](../approvals.md) with this
contract.

A harness profile selects a driver, execution environment, options and MCP
scope. Host authorization is the ceiling for profile selection and runtime
context. Provider credentials, workspace, thread and delegated grants are
resolved for each run; profile data never embeds live tokens. Docker placement
and public remote launch remain proposals. The managed native profiles use the
implemented local placement and carrier path.

## Terms and provenance

| Term | Contract |
|---|---|
| Carrier | One process per attempt that owns driver protocol and turn state; it owns no executor or SQL store. |
| Provenance | Stream and framing position supplied by the carrier, never by a driver. |
| Checkpoint | Thread-owned state after which runner output may be acknowledged. |
| Carrier epoch | A takeover fence; a previous carrier is rejected after a new epoch is committed. |
| Control record | An owner-written input or placement observation, never a driver observation. |

Each normalized stream event carries `bee.carrier.provenance@1`:
`stream_id`, source first/last chunk sequence, `envelope_index` and
`event_index`. The thread owner derives an event key from the attempt,
stream and envelope/event positions and stores the mapping atomically with the
record and checkpoint. Replaying a chunk is idempotent; the same provenance
with different content is `CONFLICT`. Control records have no stream
provenance.

## Checkpoint and output

The runner retains output until the carrier acknowledges it. A carrier
acknowledges only after one thread transaction commits all records derived from
that output and `bee.carrier.checkpoint@1`. The checkpoint contains:

- consumed chunk sequences for `stdout` and `stderr`;
- framing carry bytes, the next envelope index and bounded normalizer state;
- binding/profile references and their measured digests; and
- the current placement attachment generation and any event cursor.

The checkpoint is at most 64 KiB and carries at most 16 KiB of a partial
frame. A larger partial frame is held instead: the carrier commits the complete
frames around it but acknowledges the runner only up to the chunk before it, so
the runner keeps those chunks and a replacement carrier re-reads them, while
event keys absorb the replayed records. A frame is therefore limited to the
chunks a runner holds unacknowledged (16 chunks of at most 16 KiB). If one
provider status frame exceeds that window, the carrier records an
`oversized_frame` notice, checkpoints that it is draining through the next
newline and resumes at the following frame. This handles provider `Write`
results that echo hundreds of kilobytes of input while preserving the later
terminal result. If the omitted frame was the terminal result, the turn still
settles `uncertain` because no result envelope was observed. A frame
split across chunks resumes from carry bytes. A chunk with multiple
events commits in consumed-prefix order. A crash before acknowledgement
replays already committed output and event keys absorb the replay.

Output state and process cleanup are separate facts. The runner can retain
unacknowledged output after child exit for the placement retention interval.
If the drain deadline closes a stream, the stream is `truncated`; if a runner
is lost while output is open, recovery reports `unobserved`. A lost tail never
establishes a successful turn. A durable terminal envelope establishes the
protocol outcome even when output is incomplete; without one the turn is
`uncertain`.

## Attempt lifecycle

The owner uses this order:

1. `admit_action` validates the host-selected launch plan and preallocates the
   attempt ID.
2. `prepare_attempt` records `attempt.prepared` with binding/profile
   measurements, placement binding and placement attempt ID.
3. Placement records its `prepare` intent.
4. `request_turn` records `turn.request` on the prepared attempt before the
   initial prompt, including a prompt supplied as a launch argument.
5. Placement starts the runner.
6. `start_attempt` records `attempt.started` from placement's execution
   identity and changes the attempt to `running`.
7. Buffered output is committed through checkpointed carrier transactions.

Starting an attempt that is not `prepared` is `INVALID_STATE`. If placement
starts and a thread commit fails, recovery reconciles that same attempt; it
does not launch another child. Settlement observes process exit, drains
remaining output within the selected bounds, and then decides a missing
terminal envelope as `uncertain`. Stdout ending without a result envelope is
such a missing envelope: the driver's end-of-stream terminal waits for the exit
and the drain, so stderr the child wrote before exiting is still recorded. A
child that ended after its placement was asked to stop it (its owner
cancelling the run) and left no result envelope settles `cancelled`: the
placement's exit report carries `stopped`. A carrier that resumes after the
runner is gone reconstructs the exit from the placement record, which does not
keep that mark, so such an attempt settles `uncertain`. The attempt receipt is committed once after
turn settlement. Later cleanup is a placement observation, not a second
receipt.

## Input and replacement

Before stdin dispatch, the carrier commits `bee.carrier.write@1` with a stable
`write_id`, attempt/turn identity, input digest and attachment generation,
phase `intended`, and stores it in `pending_writes`. A runner acknowledgement
changes it to `accepted`; accepted means bytes reached the runner, not that the
harness processed them. A replacement asks the surviving runner for every
pending write after attaching. `accepted` is recorded, `unknown` proves the
bytes did not reach the child and permits first dispatch, and no runner leaves
the write `uncertain`.

`claim` commits a new carrier epoch. `commit`, `request_turn`, `end_turn` and
`receipt` require that epoch and expected thread revision; stale epochs or
revisions return `CONFLICT`. A replacement first fences the old carrier at the
thread owner and continues from the checkpoint as the claim left it, since the
old carrier commits until it is fenced; then it attaches to placement with the
new generation. Placement
updates the runner and waits for its acknowledgement. Until that attach, output
may still be routed to the old address but the old carrier cannot commit or
acknowledge it. After attach, the runner rejects input and acknowledgements
from the old generation. A catalog or binding digest change during an active
attempt is rejected on resolve; an attempt does not silently adopt new bytes.

Required cleanup, exit observation and signal capability come from the
host-selected launch policy. A profile may request stronger requirements, but
the caller and driver cannot weaken policy. A prepared attempt keeps its pinned
policy if the registry changes. Process state (`intended`, `starting`,
`running`, `stopping`, `exited`, `uncertain`) and cleanup state (`pending`,
`complete`, `uncertain`) are separate. Signal evidence or an empty/failed
process-table response is not proof of exit or process-group absence.

Placement capabilities are distinct: `direct_process` controls the launched
PID, `process_group` controls the created group, and `contained_tree` requires
a stronger boundary. A descendant that creates a new session can escape a
process group.

## Thread carrier operations

The local `bee.threads:carrier` contract exposes:

| Operation | Required behavior |
|---|---|
| `claim` | Commit a new epoch for a live attempt; replay by idempotency key. |
| `commit` | Under the epoch and expected revision, append typed stream/control records and the next checkpoint in one transaction. |
| `checkpoint` | Read the stored checkpoint, revision, epoch and the placement binding/attempt recorded by preparation. |

The preparation fields come from `attempt.prepared` and cannot be replaced by
carrier checkpoint input. A missing historical binding remains missing; a
reader does not substitute a current registry digest. Carrier lifecycle support
is part of the threads migration ledger, including the carrier schema change;
applied migration text and checksums remain immutable.

## Placement, configuration and stdin

A launch request names the owner/incarnation, action and attempt, exact driver
binding and profile measurements, host launch policy, configuration digest,
resource grants, nonsecret environment and optional retained session resource.
Driver arguments and files are placement output: placement validates, freezes
them in the intent and reuses them on an identical retry. Callers cannot
supply a private `delivery` object. The driver configuration method runs under
an explicitly empty callee scope, and placement constructs the owner's private
home and safely relative generated files. Paths, credentials and MCP/hook
entries are selected by host policy and driver binding, not by a request body.

The placement runner measures its absolute executable immediately before exec
with `bee.executable-measurement@1` and refuses a changed file. A production
permission exchange requires the measured native executable selected by its
acceptance record; fixture policies may use a fixture boundary. The measurement
does not close the runtime's small measure-to-exec window.

A launch declaring `session_end: stdin_close` writes its initial input once and
closes stdin once the turn is decided. Placement records `stdin.closed` or
`stdin.uncertain`; this is separate from input acceptance and process exit.
The runner refuses later writes. Closing stdin while a permission prompt is
pending is a denial, not a completion. Stop and cleanup retain their own
authority and evidence.

Generated provider configuration is additive and bounded. Drivers return
validated argument literals and relative files; placement materializes them
inside the private attempt/session home with exclusive creation. A retained
session is reused only when host policy names its writable session resource,
the prior native exit and cleanup are complete, and existing approved files
match exactly. The launch owner derives the session identity; callers cannot
choose a session grant or provider resume ID. Provider conversation recovery
and public Agent checkpoint/restore are separate application boundaries.

Provider-specific configuration remains behind the driver boundary. Claude adds
admitted MCP and hook settings without replacing unrelated settings. Codex
uses protected generated configuration and refuses to overwrite an existing
protected file. Muse composes a fresh settings file in its retained private
home, preserving unrelated provider, MCP and hook settings while inserting only
Bee's admitted entries. Grok structurally inserts Bee's scoped MCP subtree and
refuses a pre-existing Bee entry. Agy receives its selected instructions under
its supported customization root. Host policy, including any inherited home or
`CODEX_HOME`/`CLAUDE_CONFIG_DIR` reference, is required separately; callers
cannot choose `HOME` or copy credential files into a private home.

## Conditional permission and hook records

When host policy enables a permission adapter, the carrier records a permission
intent and its deterministic approval key in the same checkpoint transaction,
then follows the approval and write rules in [approvals](../approvals.md).
Authority incarnation, plan measurements, placement grants and proposal digest
are revalidated before consumption or recovery dispatch. A wake notification or
approval projection only prompts a fresh owner read; it never authorizes a
write. Shipped profiles leave this exchange disabled unless the host has an
accepted adapter and measured fixture/native executable.

`bee.harness.carrier:hook_records.batch` decodes bounded claimed hooks into
canonical thread observations and acknowledgment IDs. It rejects malformed or
sparse batches and duplicate IDs. An empty batch is idle. Hook observations do
not establish a turn result when no turn ID exists.
