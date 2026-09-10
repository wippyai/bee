# Status surface handoff

The owner projection, typed reader and shell wiring (bar badge, window title,
collapsed summary) are implemented in source. Focused owner/session/render
tests pass. The isolated candidate clears strict lint and ordinary source/pack
desktop acceptance; the release pin still needs typed listeners and the corrected
Future channel declaration. Lua ingress is no longer a dependency. Host thread
association/restart acceptance passes. Bound-thread physical F12/reconnect
status acceptance now passes in source and packed runs. See [the current
gates](STATUS_RUNTIME_GATE.md).
This document names the exact boundary, the typed contract, the
authorization and lifecycle rules, and the acceptance checks so that wiring
needs no guesswork.

## What is built

**Owner side, `bee.threads.projection`.** A `status` projection folded from
committed records, independent of the recap, sharing the projection engine
(`bee.threads.projection:engine`) so each keeps its own schema, cursor and
revision. Operations on the `bee.threads:projection` contract:

| Operation | Meaning |
|---|---|
| `status_read` | The stored checkpoint with the caller's own relationship derived, plus `revision`, `through_sequence`, `head_sequence`, `owner_authority`, `owner_incarnation`. |
| `status_update` | Fold new committed records into the projection, bounded (8 rounds of 64), revision-checked. Advances the projection; someone must call it or the projection never moves. |
| `status_rebuild` | Owner only: drop and fold from the first record; equals the incremental fold. |

`status_read` returns `value.status`: `activity` (`idle`/`running`/`waiting`/
`uncertain`), `waiting_on_you` and `waiting_message_ids` (the caller's own
unanswered requests), `open_requests`, `pending_approvals`, `running_actions`,
`uncertain_actions`, `open_actions`, `last_outcome`. Rules that hold in the
fold and the derivation: recorded state only, never process liveness
(`running` is a started attempt with no recorded end); uncertainty is per
action and clears only when that action's own lifecycle resolves;
`waiting_on_you` reflects the caller's remaining unanswered obligation, never
mere presence in the original recipient list; one viewer's relationship is
never persisted as thread-wide status; a pending approval is counted without
any claim about who may decide it.

**Client side, `bee.application:status_reader`.** A typed reader that drives
the projection and hands the shell presentation values, performing no I/O of
its own: it emits intents (`update_intent`, `read_intent`, `watch_intent`)
that the owning session calls, and applies the replies. It is a pure state
machine; its owner performs the I/O and holds the change-wait future.

## The typed value the shell renders

`status_reader.value(reader)` returns:

| Field | Meaning |
|---|---|
| `thread_id` | the bound thread, or nil when unbound |
| `generation`, `owner_authority`, `owner_incarnation` | the binding and owner identity; the session rejects a session-update carrying a stale generation or a superseded owner, and never displays them |
| `availability` | `unbound` (no thread), `loading` (bound, no read yet), `ready`, `stale` (projection behind the head), `unavailable` (owner unreachable or refused) |
| `detail` | the fault text when unavailable or stale |
| `status` | the derived status above, or nil before the first read |
| `revision`, `through_sequence`, `head_sequence` | the projection position |
| `stale` | `through_sequence < head_sequence` |

`unbound` is the state before any thread is bound; it is distinct from a
`ready` value whose `status.activity` is `idle`, which means a bound thread
with no work in progress.

The presenter renders these values and calls no thread operation. Text is
already bounded by the reader.

## Lifecycle and authorization rules for the session owner

- Drive one refresh as: `update_intent` then `read_intent`; arm
  `watch_intent` after. Feed each reply to the matching `apply_*` with the
  intent's `generation`.
- `status_reader.needs_refresh(reader)` is true when the projection is behind
  the head (a bounded update stopped short) or a change-wait woke. On it,
  schedule one more bounded refresh; never loop until caught up.
- The change-wait (`bee.threads.delivery:watch`) is register-then-recheck at
  the owner and watches past the last observed head, so it wakes only when the
  thread moves beyond what the reader has seen. It is a wakeup hint only: it
  carries no cursor, advances nothing and authorizes nothing; its reply is
  only a reason to refresh. Coalesce wakeups into one pending refresh, and
  scheduling the next bounded refresh yields and respects the session's
  retry/backoff limits.
- `bind(reader, thread_id)` on a thread switch bumps the generation and
  fences every reply from the previous binding. A reply under a stale
  generation is dropped.
- A changed `owner_authority` in any reply is a replacement owner: the reader
  advances its generation to retire every outstanding intent, resets its
  projection view and reads from scratch, never continues. A delayed reply
  from the previous authority, carrying the old generation, is fenced and can
  never switch the reader back. Incarnation, revision and sequence compare
  only within one authority; a reply with a revision behind what the reader
  holds under the same authority is stale and moves nothing.
- `lost(reader)` on transport silence, and any failed reply, show
  `unavailable` with the last known status retained; a lagging or unreachable
  owner is never shown as `idle`.
- `unbind(reader)` clears the view; the owner cancels the outstanding
  change-wait. Cancel the watch whenever the binding ends.
- Authorization stays with the thread owner. The `funcs.call` grants below let
  the session reach the operations; they do not establish membership, which
  the owner checks on every call, so a session reaches only threads its actor
  may read. `status_update` writes a derived checkpoint solely through the
  bounded, revision-checked owner operation; the reader has no direct storage
  access and no arbitrary checkpoint-write authority. The session actor needs
  `funcs.call` on `bee.threads.projection:status_read`, `:status_update` and
  `bee.threads.delivery:watch`, and never claim, ack, subscribe, record or any
  write; the reader issues none.

## Acceptance, all passing on the pinned runtime

`tests/lua/status_reader/model_test.lua` (pure): the update/read/stale
refresh cycle, generation fencing across a thread switch and unbind,
replacement-owner reset and stale-reply rejection, unavailable-not-idle with
the last status retained, change-wait coalescing.
`tests/lua/status_reader/surface_test.lua` (real owner): bind, advance,
derive each viewer's own waiting relationship (a recipient waits, the sender
does not), the change-wait returning at once when the head is ahead, a new
record reflected on the next refresh, and zero delivery marks written.
`tests/lua/threads/status_test.lua`: the fold, per-caller derivation, the
two-action per-action uncertainty proof, rebuild equals the incremental fold,
the owner-only rebuild.

## What remains for the shell lane

Wire a session-owned reader per visible thread into the bar button, window
title and collapsed recap, mapping `availability` and `status` to the glyph
and text vocabulary. Keep the reader in the session owner and its I/O
client-owned and asynchronous: the shared session event loop must never block
on a `watch` or projection call, but feed typed session updates from
completions, rejecting any that carry a stale generation or a superseded
owner. Binding teardown cancels the outstanding watch and fences any
completion that still arrives. The presenter only renders. An owner-authorized close or forget path for a
durable subscription an app abandons, and the abandoned-subscription bound,
remain thread-owner lifecycle follow-ups, separate from this surface.

## Reader corrections before shell wiring (2026-09-09)

The reader now rejects a successful reply with absent/unknown activity instead
of synthesizing a ready idle status. An older update cannot lower the observed
head; owner replacement resets the head before accepting the new owner's sequence.
Both failures were reproduced with the Wippy model suite before fixing them;
all eight model cases pass afterward. Full `make check` currently stops at the
three supervisor ingress lint errors on the pinned runtime. Shell binding,
asynchronous session I/O and presenter integration were outstanding at that
checkpoint; their current implementation is described below.

## Asynchronous adapter (2026-09-09)

`bee.session:status` now owns one actual function future at a time around the
reader. Its host supplies the executor under the existing viewer principal.
`advance` starts at most one operation per owner loop turn, `complete` consumes
only the matching ready future, and bind/close cancel outstanding work. Failed
admission backs off for five seconds; a 35-second operation deadline retires a
stalled future. A successful update after an unavailable read proceeds to read
rather than getting stuck retrying updates. No actor or scope is selected here.

The adapter has Wippy tests using real owner calls and futures, including recovery,
scheduling boundaries and retired-watch fencing. The session actor now calls it
through its reader collection, with client inventory publication and renderer
consumption implemented below. Focused
execution tests pass, but strict lint also rejects the adapter's typed response
channel; the earlier claim that only ingress errors remained was incorrect.

### Runtime type requirement

The runtime `runtime/lua/modules/funcs/types.go` declares both
`funcs.Future.response()` and `channel()` as returning `typ.Any`. Bee needs the
actual channel type to retain a completion channel in a typed pending record and
include it in the session's event-loop selection. The channel module already
exports `channel.Channel<T>` and typed receive cases. The runtime owner should
declare the future methods' actual channel return type, with the correct element
and optionality, and prove a typed future response can be stored and selected in
strict Lua. No runtime source was changed by the Bee lane. Do not replace event
selection with polling, casts or a parallel completion relay to hide this gap.

Current `make lint` has four errors: three in supervisor ingress and one at the
adapter's `future:response()` assignment. This adapter remains an unintegrated
implementation until that gate and session acceptance pass.

### Reviewed binding route

An optional bounded thread reference belongs to the host-authorized application
open request and immutable broker instance. It must participate in request
identity and survive inventory publication and application recovery. A reference
grants no thread membership. Reconnecting clients rebuild associations from fresh
host inventory, never from saved client layout or app-owned arguments.

The client supplies an authenticated complete tab/instance binding snapshot to
its session. The session validates it against the committed desktop, cancels
removed readers, and owns one reader per visible bound thread across presenter
replacement. Only the session receives exact call permissions for status read,
status update and read-only watch; the thread owner checks membership on every
call. Current local sessions inherit `bee.local`; future distinct identities must
preserve this owner check. Presenter updates contain presentation values only.
This route is reviewed design, not implemented binding behavior.

The pure `bee.session:bindings` boundary is now implemented independently of
actor wiring. It decodes at most 16 distinct tab associations, rejects extra
fields, and copies bounded references. Complete owner snapshots have a monotonic
revision scoped to the client/session lifetime. Applying a newer snapshot drops
associations that do not match the current workspace/tab/instance; layout changes
must prune existing associations too. Dropped values are not held for future
layout additions. The client must resend a newer complete snapshot after a
committed layout acknowledgment when inventory arrived before the corresponding
tab. Sender authentication remains the session actor's responsibility before
decoding. No listener or permissions are installed by this pure library.

Focused Wippy execution passes 16 cases across the reader model, asynchronous
adapter and binding boundary. The binding libraries add no strict lint errors.
After preserving the failing logs, `make lint LINT_FLAGS=--cache-reset` cleared
the five broker viewport type mismatches. The refreshed check covers 298 entries
and reports only the four runtime-dependent errors listed above. Full physical
shell acceptance is still outstanding.

A second ordering regression is now covered: reading the same projection
revision with an older observed head cannot lower the reader's known head or
clear its stale state. The regression failed with expected 60, got 40 before
the fix. Owner replacement still resets the head before accepting the new
authority's sequence, so heads from different owners are not compared.

`bee.session:statuses` owns the bounded collection around these two helpers:
one reader per distinct thread referenced by committed tabs, including minimized
tabs whose status remains visible in the bar. A new complete binding snapshot or
layout pruning closes readers whose last binding disappeared. Repeated snapshots
and removing one of several tabs preserve the existing reader. Closing the
collection is terminal and cancels its readers. The owner supplies the executor;
the collection selects no actor or scope and starts no event loop. Session actor
wiring must authenticate snapshots, drive each reader's asynchronous operation,
publish values and close the collection on every exit path. Presenter replacement
must not close it.

The session actor now listens to `bee.desktop.bindings`, authenticating the
actual sender against its bootstrap owner before decoding. Its loop selects
future response channels alongside desktop commands and one deadline timer,
stopping that timer after selection. Cleanup cancels the collection on normal
and exceptional exits. `bee:session_status_policy` grants only the three exact
function calls and is attached only to the session entry; membership remains
the thread owner's decision. Scene and acknowledgment envelopes carry tab status
values. An actual session test now reads an existing thread under its member
principal, rebinds to another owner's thread without membership, observes
unavailable, and proves shutdown completes without an error result. The test
supplies only `bee:session_policy` to the spawned session, matching production;
the session entry attaches the exact status-call policy itself.
The earlier nonexistent-thread case also passed. Foreign-sender denial remains
covered by focused protocol tests. Client reconnect and physical rendering are
covered by the bound-thread desktop acceptance below.
The client now publishes complete binding snapshots from admitted host inventory
intersected with committed tab/instance identities. Saved client targets alone
cannot create an association. Inventory changes and adopted desktop revisions
both trigger reconciliation; a fingerprint avoids resending identical snapshots.
Layout revision participates so a snapshot discarded before a layout change can
be replaced after that change. Retired tabs are excluded immediately. F12 does
not replace the client or session and therefore does not reset these readers.
Client consumption and presenter transport are now implemented. The session
increments a separate status revision; the client accepts newer status snapshots
even when its desktop layout is unchanged. `bee.application:status_surface`
decodes bounded identity and availability values into glyph/text/theme-role
badges. A normalized client-to-presenter decoder copies at most 16 entries and
rejects control characters. The presenter accepts newer status revisions and
filters badges against current tab/instance identities before rendering. Badge
drawing is now implemented in the taskbar, title and collapsed summary. The
renderer preserves stored titles, mode markers and hit geometry, including
minimized/fullscreen/collapsed tabs. Themes currently have no dedicated
warning/success/danger fields, so badges use their existing accent/text/muted
palette; glyph and text carry the distinction independently of color. Combined
focused owner/protocol/session/presentation/render tests pass 68 cases.

`thread-status-probe` is a physical source/pack acceptance fixture. It creates
a real owner record addressed to its explicit actor, opens `bee.console:app`
with a host-authorized `thread_id`, and saves only the returned view and
instance identities in the client store. The admitted host inventory supplies
the thread association. The visible `Waiting on you` badge survives F12 and a
fresh client reconnect; F12 waits for a test-only new-presenter PID marker,
retained shell output, and the badge in one frame before it sends the proof
command. A real committed reply then changes the visible badge to `Idle`.
Late old-owner reply fencing remains model-test coverage.

Host association review and focused Wippy execution now cover request/reply
decoding, inventory title preservation, checkpoint selection, recovery and the
status suites together: 53 cases pass. This does not replace broker-level retry
and singleton execution proofs or cold-restart acceptance for the new field.

Those host proofs are now staged in the existing
`tests/fixtures/workspace_hosts/supervisor.lua` acceptance fixture: a Settings
open carries an explicit thread reference, its checkpoint retains it, a changed
retry conflicts, a new singleton open cannot rebind it, and both the stored
record and restored reply must retain it after stopping/restarting the owner.
`make workspace-hosts-check` passes these assertions from source and pack on
the isolated typed-listener candidate documented in `STATUS_RUNTIME_GATE.md`.
The released runtime pin remains unchanged.

Terminal badges require an owner receipt: only an idle projection with zero
open actions may render its recorded receipt outcome as succeeded, failed,
cancelled or uncertain. A successful turn alone never becomes an action-success
check. Unavailable and stale availability still take precedence and retain
explicit uncertainty text. A focused regression covers turn success, receipt
success and an additional open action suppressing the completion badge.
