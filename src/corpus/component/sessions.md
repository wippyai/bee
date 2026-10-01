# Bee sessions

`bee.sessions` owns the public session contracts, executor selection, readiness
location and work scheduling. Threads owns the durable session journal and
transactional work, claim, turn and result records; Sessions never writes its
tables. Executors are selected by the host and operate through the fenced
worker contract.

A launch definition may select `session_profile_id` for structured executor
turns and `session_credentials` for their explicit broker projections. Sessions admission pins that driver profile while native manual windows
retain the definition's window profile. Catalog readiness measures the same
structured route that `open` admits. The real owner and catalog bindings are
defaults; the kit starts the pull scheduler against the Threads journal.

Provider login checks use the home selected by each profile; file existence
is an observation and the provider owns authentication.

Session reads and list pagination include home-workspace sessions plus workspaces explicitly admitted by `bee.threads.workspace`. Cross-workspace mutations require separate exact host grants: `bee.sessions.workspace.open`, `bee.sessions.workspace.send`, `bee.sessions.workspace.cancel`, and `bee.sessions.workspace.close`. Visibility alone grants no mutation authority. List filters accept workspace, definition, lifecycle and activity.

Snapshots expose `presentation` and the canonical `thread_ref`, driver/provider, definition, workspace
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
