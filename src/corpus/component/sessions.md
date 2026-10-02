# Bee sessions

`bee.sessions` owns the public session contracts, executor selection, readiness
location and work scheduling. Threads owns the durable session journal and
transactional work, claim, turn and result records; Sessions never writes its
tables. Executors are selected by the host and operate through the fenced
worker contract.

`bee.sessions.binding` implements admission, catalog and control operations
directly from its owner source; it also owns readiness observations and the
Threads journal adapter. `bee.sessions.service` owns the pull scheduler and turn
workers. `bee.sessions.executor` resolves host-selected executors and driver
methods in the selected driver's binding namespace. Sessions has no persistence,
migration or tool namespace: Threads owns its durable records and migrations.

A launch definition may select `session_profile_id` for structured executor
turns and `session_credentials` for their explicit broker projections. Sessions admission pins that driver profile while native manual windows
retain the definition's window profile. Person-facing catalogs filter the `presentation:start_menu` feature; programmatic routes remain addressable. Catalog readiness measures the same
structured route that `open` admits. The real owner and catalog bindings are
defaults; the kit starts the pull scheduler against the Threads journal.

Provider login checks use the home selected by each profile; file existence
is an observation and the provider owns authentication.

Session reads and list pagination include home-workspace sessions plus workspaces explicitly admitted by `bee.threads.workspace`. Cross-workspace mutations require separate exact host grants: `bee.sessions.workspace.open`, `bee.sessions.workspace.send`, `bee.sessions.workspace.cancel`, and `bee.sessions.workspace.close`. Visibility alone grants no mutation authority. List filters accept workspace, definition, lifecycle and activity.

`open` accepts `budgets = {turn?: Budget, session?: Budget}` and `supervision = {quiet_period_ms?, on_stall?: "report"|"cancel_work"}`. `Budget` has positive `provider_steps`, `tool_calls`, `tokens`, `wall_time_ms` and `cost_usd` fields. Limits are opt-in. Turn limits combine with each Work's `budgets.turn` using the tighter value. Session counters survive restart and include settled turns; replayed observations do not spend twice. Session wall time starts with the first accepted turn and includes idle time. Descriptors declare provider-step units and accounting coverage. Token limits require declared trustworthy accounting; cost limits and window budgets currently reject as unsupported. Token limits can overshoot within one provider step before usage is reported. Exceeding a limit settles `budget_exceeded` only after placement proves exit. The quiet period defaults to 60000 ms; report leaves stalled work running, while cancel_work requests a placement stop. Known approval waits pause stall cancellation.

An accepted turn becomes `stalled` when its thread has no new live observation for the session's quiet period. `activity_evidence` identifies the turn, last progress time, quiet period and elapsed quiet time. `get` and `list` derive this view from the stored progress timestamp; `on_stall="report"` leaves stalled work running; `cancel_work` asks placement to prove a stop.

Managed open/call and MCP open/run accept an optional canonical `placement` override. Both the definition and host policy must admit that override; Docker template selection and native machine-home access retain their existing ceilings. The override persists in the Threads route and the scheduler reuses it for every turn. Window placement overrides require a saved profile.

Snapshots expose the optional `saved_profile` reference `{id, revision}` used at admission.
Snapshots carry the resolved `effective_profile`, including presentation, budgets and supervision, and its canonical SHA-256 `profile_digest`. They expose `presentation` and the canonical `thread_ref`, driver/provider, definition, workspace
and last result summary. `history{session,cursor?}` pages immutable Work inputs;
clients observe results with `get` or `await`. SDK open/call and MCP open/run accept
an optional canonical `workspace`; opening outside the current workspace requires
the exact host open grant. Setup associates the definition's retained resources
and credentials before creating the Session.

The scheduler runs independent Sessions concurrently through asynchronous turn
workers, with at most one worker per Session. Its journal adapter decodes Work
receipts, reservations, fenced turns and scan pages into scheduler records;
the executor registry decodes execution results before returning them to the
scheduler. Executor errors become durable
uncertainty and do not trigger a blind retry.

Open accepts `presentation = "headless" | "window"`, defaulting to `headless`.
Headless sessions retain the pull executor and live conversation view. Window
sessions select the admitted interactive profile and start the existing native
PTY and hook runtime under a retained session viewport owner. The Sessions app
uses M in the catalog to choose window presentation; Enter opens headless.
The snapshot's presentation field selects the terminal viewer when reopening
an existing SessionRef.

The host opens a viewer on a live controlling display when it grants session
presentation. Without a controlling person, the terminal remains detached.
The viewer holds a recipient-bound observation/input/resize mount. Closing it
revokes that mount and leaves the session and CLI running. Sessions list Open
and `--session SessionRef` navigation reattach to the retained terminal and its
history. Work reaches the driver through authenticated UserPromptSubmit hooks,
with owner-set sender identity; Stop/StopFailure settles the turn. No Work is
written to the PTY as keyboard input. Closing the session seals intake, stops
its admitted placement, and settles remaining Work only after proved exit.
Cancel uses the same evidence-backed placement stop path.

Native interactive admission attaches a Session to its workspace thread.
Its hook route fences stale attachment hooks and bypasses the pull scheduler.
A proved process exit suspends an active session and preserves unfinished Work
as uncertain. Native crash/reattach acceptance remains outstanding.
Gateway workspace catalog views project the public Sessions list.

Cancellation first commits the authenticated caller’s authorized request in Threads, then restores the persisted workspace-bound execution owner for placement stop and reconciliation. Placement retains its owner checks; callers cannot supply the execution identity.

Owner admission reads only the host-declared nonsecret executable and configuration-directory variables through the shared harness environment policy, including callers entering through MCP. Provider credential reads remain broker operations.

The read-only `bee.sessions.binding:attention_count` display binding returns
`{count}` for blocked and stalled sessions in the authenticated caller's
workspace. It refuses a different workspace and bounds scanning to 16 pages;
it creates no approval and grants no authority. Desktop Needs you adds this
count to pending approvals and opens Sessions when only sessions need attention.

The scheduler service exposes the host-selected
`bee.sessions.binding:lifecycle` owner callback for Hub component transitions.
Its admission fence comes from Hub's existing durable operation receipt, not a
second state store. `open`, `run`, `send` and `attach` refuse while fenced; reads,
cancellation and close remain available. Quiesce waits for active pull turns,
then checks the Threads journal for unresolved reserved/accepted work or
uncertainty. Interactive sessions must close through their existing proved-exit
path before a component transition. A full bounded scan cannot prove absence and refuses the drain.
Queued work and all session data remain in Threads. Missing scheduler readiness
or an uncertain obligation leaves the Hub receipt recoverable. Ready identifies
the exact scheduler boot definition after the existing supervisor restarts it.
The worker registers only after its lifecycle inbox is initialized; the owner
waits for registration before requesting that acknowledgement. Missing
interactive drain evidence refuses the transition.
Other process hosts and interactive placements have no component drain protocol
here and keep their existing ownership and stop paths.

## Application client

`bee.sessions.client:sessions` calls the `bee.sessions:contract` and
`bee.sessions:catalog` owner contracts through their default bindings, as the
calling process's own actor. It grants nothing; the host admits the caller and
the owner authorizes every operation. Each function returns `value, Fault?`;
a Fault is `{code, message, retry, operation_key?, operation?, current_revision?,
evidence?, retry_after_ms?}` and `retry` is `never`, `same_key`, `refresh` or
`reconcile`. Owner replies are decoded against the closed owner schemas and any
deviation is a Fault, never a partial value.

Decode values through `bee.sessions.types:protocol`; applications import the client directly.

```lua
local sessions = require("sessions") -- imports: sessions: bee.sessions.client:sessions
local c = sessions.call{definition = "research:quick", input = "Summarize the repository", operation_key = "call/summary", timeout_ms = 30000}
-- c.work is the Work handle; c.observation.tag is ready, pending, blocked or uncertain.
local s = sessions.open{definition = "research:worker", budgets = {turn = {provider_steps = 12, tokens = 20000}},
    supervision = {quiet_period_ms = 45000, on_stall = "report"}, operation_key = "open/worker"}
local w = s:send{input = "Check the baseline", budgets = {turn = {tokens = 5000}}, operation_key = "send/baseline"}
local a = w:await{timeout_ms = 30000}
local closing = s:close{operation_key = "close/worker"}
```

- `call{definition, input, operation_key, output?, profile?, workdir?, budgets?, supervision?, timeout_ms?}` opens a session with its first work in one owner operation and awaits it once. It returns `{work, observation}` on every observation branch. An unsuccessful settlement is a `ready` observation whose `result.outcome` is not `succeeded`.
- `open{definition, profile?, workdir?, budgets?, supervision?, operation_key}` returns a Session. `send{session?, input, output?, budgets?, operation_key}` (or `session:send`) returns a Work whose `receipt` proves intake only. Work is queued; nothing runs inside the call.
- `budgets = {turn?: Budget, session?: Budget}` is opt-in on open. Send accepts `budgets.turn` and tightens the session turn defaults. Session totals are durable; token intake uses descriptor-declared accounting and may overshoot within a provider step. Cost and window limits currently reject as unsupported. Exceeding a budget returns `outcome = "budget_exceeded"` with `BUDGET_EXCEEDED` and placement exit evidence.
- `cancel{work, operation_key}` and `close{session, operation_key}` return an Operation whose `await` reports `stopped`/`already_terminal` or `closed`, or an uncertain evidence branch.
- `await{subject}`, `work:await` and `operation:await` observe one work or operation; `timeout_ms` is at most 60000 and bounds observation, never execution. `session:await(work)` also checks that the work belongs to the session.
- `join{works, operation_key, policy?, quorum?, timeout_ms?}` takes 1 to 64 distinct works, returns one `JoinAwait` with every child's observation in input order, and validates `quorum` against the set.
- `get(session_ref)` and `work(work_ref)` rehydrate a Session or Work from a ref; `work:state()` reads the `WorkState`, which carries `sender`, the owner-set authenticated sender of the work (a SessionRef when the caller is a session, else the principal). Callers never supply a sender. Refs (`bs:`, `bw:`, `bo:`, `bj:` qualified strings) are the only addresses; `:ref()` returns one.
- Handles capture the session incarnation and send it as `expected_incarnation`; a session reset makes them fail with `STALE` rather than act on the new incarnation.
- `list{filter?, cursor?}` filters by `workspace`, `definition`, `lifecycle` and `activity` (`idle`, `working`, `blocked`, `stalled`); session snapshots include quiet-period evidence when stalled. `supervision.quiet_period_ms` on open selects the period, defaulting to 60000. Stalled reports inactivity; `supervision.on_stall="cancel_work"` requests a stop with placement evidence. `catalog{kind?, definition_ref?, query?, sort?, include_unavailable?, cursor?}` returns the owner's candidates.

Requests are validated before dispatch (`INVALID`): bounded text and refs, JSON inputs of at most 64 KiB and depth 16.

### Operation keys

Every mutation requires an explicit `operation_key`. The SDK cannot derive a
durable identity from the current application broker or client, so applications
must persist their own key before dispatch and reuse it after an uncertain
reply. Reusing a key with different arguments is a conflict.

Session snapshots expose `thread_ref`, `workspace`, driver/provider, definition and the latest settled result summary. `session:history{cursor?, limit?}` pages immutable Work inputs and refs in sequence order; rehydrate each Work to observe its current result.

`sessions.open` and `sessions.call` accept optional `presentation = "headless" |
"window"`. Headless is the default. Window opens an interactive session with a
retained native terminal and a detachable viewer when the host grants
presentation to a controlling person. Its snapshot exposes `presentation` so
Sessions navigation selects that terminal. Work still uses `send` and reaches
interactive sessions through their driver hooks at the next turn boundary.
Closing a viewer leaves the session running; `close` or `cancel` stops its
placement with exit evidence.
