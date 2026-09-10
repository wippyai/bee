# Historical foundation review and extension proposals

This page preserves an earlier review and proposals; its status tables and test
paths are not the current implementation inventory. Test Status was removed and
must not be restored from this plan. Timeline is the current read-only thread
application, and durable thread authority/subscriptions are implemented. Use
[foundation status](FOUNDATION_STATUS.md), [the build sequence](BUILD_SEQUENCE.md)
and [the global build handoff](handoffs/GLOBAL_BUILD.md) for current evidence and
remaining gates. Driver, publication and self-edit proposals below require their
own implementation and acceptance; they are not callable APIs.

Status: current local foundation reviewed through `ad8857f`. The original review
was against `ac339ed`; proposed extension contracts below remain unimplemented
unless the current-state table explicitly says otherwise. See [Threads](THREADS.md)
for the local journal, isolated subscriber proof and standalone Test Status worker.
Bee can launch installed external programs fullscreen through registered command
handlers; this does not implement agent drivers or MCP.

## What exists, and what is missing

| Area | Current state | Needed next boundary |
|---|---|---|
| Desktop | Separate workspace, session, broker and replaceable presenter | Keep domain operations out of input/render loops |
| Application client | Typed launch, readiness and checkpoint helper | Not an agent driver, tool catalog or external API |
| Persistence | Local envelope, checked migrations, stable workspace ID, opt-in app recovery and a separate local journal | Named filesystem/project resources and independently persisted client layout |
| Authority | Actor-process sender checks, protected admission, scoped TTY | Durable participant membership and external session identity |
| Threads/subscriptions | Production journal and polling Test Status view; isolated bounded subscriber proof | Production subscriptions, durable consumer cursors and dynamic membership |
| Agent drivers/MCP | Archived POC only | External transport adapter over owned contracts; drivers later |
| Publication | Direct app registry/overlay writes denied | Candidate validation, authorized activation and durable receipts |
| Live installation | Not implemented | Admission/catalog refresh, dependency/migration/upgrade orchestration |
| Documentation | Repository Markdown | Later package the same pages as discoverable registry documentation |

## Verified local checkpoint and next work

`make check` passed after the fullscreen-handler change, covering typed Lua,
source/pack UI, window recovery, authority denial, responsive shutdown, the
subscriber fixture and Test Status. The executable acceptance also passed all
three provider aliases with literal arguments, fullscreen placement and F12.
The relevant checks live in `tests/threads.py`, `tests/thread_storage.py`,
`tests/test_status.py`, `tests/console.py`, `tests/recovery.py` and
`tests/native_binary.py`; a green local check does not prove remote operation.

The [client/host extraction](CLIENT_HOST_SPLIT.md) now supplies a TTY-free host,
explicit controller grants and independently persisted local clients. Source
`bee` uses that topology; full local migration and failure-path acceptance pass.
Two local clients and retained terminals have source/pack acceptance.
Mixed-workspace composition, remote attachments and the Hive profile remain
unimplemented. Prove the same contracts between two actual runtimes before
claiming remote operation. Runtime naming/Raft work remains separately owned.

The local foundation does not require implementing the full proposed thread
contract below. AI drivers, local models, MCP, Hub installation and self-edit
activation remain separate future work. The Workspace Manager and compact shell
switcher are planned presentation surfaces over workspace contracts, not new
workspace owners or an implicit reason to enable networking.

The broker reads protected bindings at startup and sends its initial catalog.
It reads a descriptor on open, but that is not atomic admission/catalog refresh
or code-version pinning. F12 replaces the presenter, not the broker. Therefore
raw registry mutation must not be described as a supported live installation.

## Moving daily work into Bee and recording it

Keep the repository demo tied to verified behavior. The current GIF records the
real local desktop, Settings, Terminal and Process Manager. It is not an agent
integration or self-edit demonstration.

1. **Use the terminal foundation.** Run an installed harness through `bee codex`,
   `bee claude` or `bee agy`; prove arguments, working directory, input, resize,
   close and presenter recovery. This launch slice is implemented. It does not
   yet give the harness Bee tools or durable harness-session recovery.
2. **Connect workspace operations.** After the owner/attachment boundary is
   settled, expose explicitly authorized operations through an external adapter.
   Thread observations and app operations retain their owners and typed contracts.
   Prove sender admission, denied access and reconnect before moving orchestration
   into Bee. MCP and harness hooks remain unimplemented.
3. **Edit one application from inside Bee.** Introduce the publication owner,
   source/draft ownership, expected revision, validation and activation receipts.
   Preserve local edits and a known-good boot; test conflicting edits, denied
   publication and interrupted activation. A review decision applies to the exact
   validated revision. Self-edit authority is separately granted, never inherited
   merely by opening an agent terminal.
4. **Record the actual self-edit loop.** Show the agent working inside Bee,
   the proposed diff, validation results, review, activation and the changed app.
   Demonstrate the real refresh/restart behavior, including what state survives.
   Record recovery from a rejected or failed candidate separately. Do not animate
   an unimplemented success path or suggest native code updates are live Lua edits.

Hub acquisition is not a prerequisite for the first local edit. Runtime overlays
are an activation mechanism with their own restrictions, not the durable source
of drafts. Broader self-edit coverage follows only after the single-app flow is
accepted. This sequence is a plan, not permission to bypass publication checks.

## Code and organization critique

### Legacy driver shapes to retain

Reference-only review on 2026-09-07 inspected the external legacy tree:
`driver-claude/src/driver.lua`, its `_index.yaml`,
`_archive/poc/lineage/src/harness/{catalog,kit}.lua`, the Codex driver there,
and `os-gateway/src/{hook,mcp}.lua`. None is a production dependency or evidence
that its provider-specific flags still work in current harness versions.

The useful shape is a registry-discovered native driver contract, independent
window/session execution owners, and a gateway bound to the launched action.
The legacy `prepare`, `command` and `parse` methods separate launch preparation
from provider output parsing; hook observations and MCP calls meet in the thread.
Keep that separation while replacing untyped values and shell-command strings
with bounded typed launch data and literal argument vectors.

The intended zero-setup path remains `bee codex [brief]` (likewise other admitted
handlers). Its application handler selects an admitted driver binding. The run
owner creates or joins the authorized thread, records the driver revision and
harness session reference, prepares scoped hook/MCP configuration, then launches
the native program. The gateway must be ready before the harness starts; failure
must report an incomplete launch, not quietly run an apparently integrated agent
without its tools. The visible terminal is one view of that execution.

Keep `workspace_id`, `thread_id`, run identity, app/view identity and the harness's
own conversation/session ID distinct. A driver declares interactive, resumed-turn
and structured-output capabilities separately. Preserve original hook names and
source event identity alongside normalized events; absent hooks are explicit.
Interactive terminal input is not automatically a safe background message queue.

MCP exposes the same authorized subsystem operations that local apps consume.
The launch owner binds credentials to the admitted run and resource scope; a
thread ID or URL parameter alone does not grant access. Driver configuration
does not enable bypass flags or edit the user's global harness configuration by
default. Harness configuration/authentication and resume behavior need acceptance
against supported provider versions before this replaces today's Terminal aliases.
Self-edit tools still route through the separately granted publication owner.

The next implementation should retain the legacy contract shape, not its hardcoded
home paths, fixed tool inventory or shell-specific command assembly. Native and
remote launches use the same run contract; the destination owner establishes the
actor and allowed execution scope after admission. This remains proposed driver
work, sequenced after the local host/attachment boundary.

The import graph, pure scene reducer, typed boundary decoders, independent apps,
negative permission checks and source/pack acceptance provide a useful base.
The workspace and broker still carry substantial orchestration in their entry
functions. Extract checkpoint routing and restore coordination when those concerns
change, using explicit state/input/output contracts; avoid a broad rewrite while
adding the thread subsystem. New domain code belongs in its own owner.

Current public helper types and private protocol types have overlapping launch
validation. Keep conformance coverage across that seam; do not make apps import
private core decoders merely to eliminate duplication. Operational limits are
bounds, not model-token budgets or per-actor quotas. Before unattended hooks, add
bounded concurrency, retry and queue policies to the execution owner.

The earlier docs incorrectly said persistence was absent and described unshipped
checkpoint sequences, workspace UUIDs and pinned revisions. The agent guide and
workspace-state page now describe the actual implementation. Historical studies
remain labeled references. There is no shipped agent-facing callable API yet.

## Self-sufficient foundation

Bee's primary work has no Kickside dependency or compatibility gate. The current
priority is Settings/UI and a small Bee-owned thread/subscriber proof. Kickside
components remain optional future integrations. Their architecture is a reference,
not a required host or an implementation dependency.

## Next: durable threads shared by participants

A thread is a durable resource carrying ordered events. It is not synonymous with
a chat, agent, terminal, process or window. Apps, external agents, visualizations,
connectors and hooks can participate through the same authorized contract.
A thread view is optional and can close without deleting the resource or stopping
its consumers. The desktop's transient window commands remain process messages.

For historical comparison only, the inspected Kickside reference is `~/kickside/main` at
`6c994a67c7a833b78f278c0443f08abf92670e39`:

- `app/src/app/docs/kickside-development/03-threads-events-projections.md`
- `core/core/src/threads/contract.lua` and `threads/persist/writer.lua`
- `core/core/src/threads/notify.lua`, `core/core/src/projections/`
- `core/component/src/_index.yaml` and `core/core/src/_index.yaml`

Kickside addresses a component's thread by the component ID. Its writer gates
access through the component authority, owns transactions and sequencing, and
supports external dedupe identities. Notifications wake readers; the durable log
remains authoritative. Projection execution carries an actor identity. Bee can retain
these useful separation principles without importing the implementation. No
Kickside dependency closure has been admitted into Bee.

### First implementation gate

Build an isolated Bee-owned fixture on Wippy and local SQLite. Prove authenticated
participants, ordered append, dedupe, denied access, replay, restart and bounded
subscription delivery. Demonstrate a real test-status projection. Keep it outside
production until the protocol and lifecycle are reviewed. No models, MCP, Hub or
Kickside dependency is required for this first proof.

### Minimum communication contract

These are semantic requirements; exact APIs follow the standalone prototype proof.

| Operation | Required behavior |
|---|---|
| Create/open/list | Stable resource identity, participant visibility and explicit rights |
| Append | Commit before acknowledgement, per-thread ordering, bounded typed body, authenticated producer |
| Retry append | Stable dedupe key; define and test conflicting payload behavior |
| Read after cursor | Bounded pages with continuation; no global ordering promise |
| Wait after cursor | Match bounded type/correlation filters, deadline/cancellation; cannot miss an event between read and registration |
| Subscribe/resume | Consumer-owned cursor; replay after reconnect; bounded wakeups with catch-up on overflow |
| Revoke | Recheck access on reads, waits and dispatch; cancel denied subscriptions |

Retain the platform's event ID, sequence, event type and trace/correlation
vocabulary. Content can describe a request, result or metric; an event's role or
claimed author is never an authorization credential. A request and its reply
correlate through durable data, not a live PID. Timeout means no result observed
by the deadline, not cancellation of the other participant's work.

For the prototype, short bounded waits plus cursor replay work over MCP even if
a client lacks server-push support. In-process subscriptions can use wakeups, but
both paths read the same log. MCP authentication binds a participant and scope;
caller-supplied actor IDs cannot select authority. Disconnecting an MCP session
does not delete the thread. Transport sessions and durable participants differ.

Initially retain events without automatic compaction. Bound append/page sizes and
consumer queues; surface storage exhaustion explicitly. Before retention is added,
define cursor-expired behavior and snapshot recovery. Do not silently skip events.

### Small useful prototype

1. One local project resource and an authorized thread. Filesystem access remains
   an explicit grant, separate from permission to participate in the thread.
2. One external-agent MCP connection can read, append and wait on that thread.
   No internal LLM runner or provider-specific harness is required.
3. One standalone Thread Inspector app renders real events, progress and replies;
   its checkpoint stores the selected resource/cursor, not a duplicate journal.
4. A second participant replies. Restart Bee and reconnect both participants:
   history remains, cursors resume, retries do not duplicate accepted events.
5. A bounded subscriber builds a useful projection. Test duplicate delivery,
   worker crash and revoked access before enabling autonomous side effects.

This is the first place to move day-to-day agent coordination into Bee. It does
not yet replace the external agent's filesystem tools, harness or execution model.
A durable consumer cursor is distinct from the app's visual browsing cursor.

## Hooks, connections and publication after that proof

Harness hook adapters and application producers append through the same thread
owner. Bind the adapter to an authenticated source; retain its original hook
name, stable source-event identity, session/run reference and event schema version.
Do not infer a successful tool operation merely because a generic hook fired.
Preserve source timestamps as metadata; committed sequence determines local order.
Adapters differ by harness capability, so lack of a hook must be explicit.

Parent/child thread relationships describe organization, not inherited permission
or automatic event forwarding. A project can contain run threads and those runs
can contain worker threads. Validate parent existence and prevent cycles; reading
a parent must not reveal unauthorized child content. Cross-thread causes use
explicit event references and correlation. A summary subscriber may publish an
aggregate only to an audience authorized to receive its source information.

Hook handling separates observation from effects. A subscriber maintains its own
cursor and can rebuild a test-status projection after restart. A trigger that
runs code needs an independently admitted execution identity and a durable work
receipt keyed to the source event. Duplicate hook delivery must not create a new
logical request. Self-generated events need explicit filtering/causation guards
and bounded fan-out to avoid trigger loops. Cancellation, timeout and retry are
separate outcomes; a timed-out external effect can still have happened.

A visualization folds events. A hook may cause external effects and needs its own
admitted execution identity, idempotency, bounded attempts and failure reporting.
Assume at-least-once consumption; do not promise exactly-once GitHub or shell
operations. Use an owned durable job/outbox seam when recording an event and
scheduling work must be atomic. Projections must not hold the desktop input loop.

A GitHub connection can be a Kickside component with host-bound credentials and
resource permissions. A native setup/inspector view may be enough; not every
component needs its own desktop app. Existing browser UI requires a web host and
does not become terminal UI through an overlay. A connector imports issue events
with stable external identities; an independently authorized subscriber proposes
or executes work. Issue text is data, never permission to execute or publish.

Self-modification and Hub installs share a publication owner, outside experimental
code. Start with one local candidate: inspect source, stage against a revision,
validate/test, review capability changes, activate and record a recovery receipt.
Threads can carry its requests/status, but the publication owner checks authority
again. Native core updates retain their build/restart boundary; user experiments
use the authorized registry lane.

Runtime `system/registry/overlay.go` provides ephemeral owner/generation-scoped
entries, rejects collisions with durable IDs and directive-owned kinds, and does
not advance registry history. Therefore an overlay cannot simply replace every
bundled core ID or install a dependency directive. Saved drafts need durable
source and activation records; durable installation needs the publication lane.
Keeper's `keeper/src/keeper/hub/service.lua` is the plan/publication/migration
reference. No cross-database atomic rollback is implied by a registry receipt.

Deliver the standalone thread/test-status proof first, then MCP and a real inspector; then add
subscriber execution, local publication/catalog refresh, and Hub acquisition.
Provider-specific agent drivers and richer project dashboards consume these
contracts later. Keep each subsystem independently testable and installable.

## Checkout and packaged self-update

Proposed ownership rule: choose one authoring source per application revision.
In checkout mode, files are authoritative; stage a source diff against known file
hashes and registry revision, validate it, then activate the resulting candidate.
A file watcher may report drift, but must not silently authorize activation. On
concurrent edits, stop with a conflict; do not overwrite the agent's or user's
newer files. Multi-file staging needs a manifest/receipt and crash recovery, not
a claim that several file renames plus a database commit are one transaction.

In packaged mode, the base pack is immutable. User edits are durable workspace
source drafts with an explicit export/import path. Live registry overlays are a
materialization, not a second editable source of truth. Track source hash,
base/expected registry revision, overlay owner/generation, validation evidence,
activation status and recovery target separately. Core replacement may require
a coordinated restart; F12 is only the presenter's replacement mechanism.

Before unattended publication, prove conflicting edits, failed validation,
interrupted activation and restoration of a known-good boot. Preserve source
edits when activation fails. Restoring code does not undo arbitrary database
migrations or external side effects. Keep native binary updates in the native
release path and initially limit user overlays to supported experimental entries.

## Core gate before either subsystem

The preceding foundation commit passed `make check`, including source/pack PTYs,
negative permissions, lifecycle failures and durable recovery. That evidence does
not establish protection against arbitrary OS-user code or readiness for live
package replacement. Carry the following gates into the first extension change:

- Implemented for host/client structural control: a rejected send reports
  its topic and native cause, ends the affected local owner and preserves
  recovery when structural control fails. Source/pack injection covers bind,
  restore, accepted shutdown and checkpoint receipts. Ordinary open/close and quit
  preparation failures preserve running apps and permit explicit retry.
  Appearance requests keep their correlated error path.
  Remote reconnect and disconnected-client behavior still need the attachment
  contract; local fail-fast behavior is not a remote availability guarantee.
- Keep append/draft persistence outside the desktop envelope and outside the
  presenter's input loop. Storage failure must remain visible and preserve the
  last committed state.
- Prove admission refresh as one accepted revision before calling anything a
  live install. Do not mix a new descriptor with stale policy bindings.
- Specify source ownership and revision conflicts before any bidirectional sync.
- Keep service/consumer lifetimes separate from the current view-owned app model.

These are explicit remaining design/verification gates, not claims of completed
hardening. The next implementation can be threads or local publication after the
relevant gates are met; full Hub acquisition is not a prerequisite for either.
