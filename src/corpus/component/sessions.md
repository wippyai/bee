# bee.threads.sessions

Managed agent sessions. The contracts, owner bindings, catalog and client
library live in `bee.threads.sessions`; Threads owns every durable record (the
session journal, work, turns, results) and Sessions never writes its tables.
The Threads journal is the host-selected binding named by
`bee.threads.sessions.env:threads_journal_ref`
(`meta.type: bee.sessions.threads_journal_ref`).

Every session runs the agent's own program in a terminal: admission pins the
definition's window plan and `open` presents it through `bee.harness.binding:present`.
A person opens the terminal from Sessions. A message sent to the session is
queued as Work in Threads and delivered into the terminal at the agent's next
turn boundary (UserPromptSubmit and Stop hooks, `hook_boundary`); the Stop hook
settles the turn with the agent's final message. A process exit proved by
placement suspends the session and marks unfinished Work uncertain.

| Entry | Responsibility |
|---|---|
| `bee.threads.sessions:contract` | Methods `open`, `run`, `send`, `await`, `join`, `get`, `list`, `history`, `cancel`, `close` |
| `bee.threads.sessions:catalog` | Method `list`: admitted definitions and saved profiles with executor readiness |
| `bee.threads.sessions.binding:owner_binding` | Default binding of `contract` (`meta.type: bee.sessions.owner_binding`) |
| `bee.threads.sessions.binding:catalog_binding` | Default binding of `catalog` (`meta.type: bee.sessions.catalog_binding`) |
| `bee.threads.sessions.client:sessions` | The application client library |
| `bee.threads.sessions.types:protocol` | Request, reply and fault decoding |

The owner binding also holds the window-session functions the Agent app uses:
`attach`, `restore`, `launch_prompt`, `idle_check`, `hook_boundary`, and
`attention_count`, a read-only display binding returning `{count}` of blocked
and stalled sessions in the caller's workspace (it scans at most 16 pages and
refuses another workspace).

## Operations

- `open{spec = {definition, profile?, workdir?, workspace?}, operation_key}` admits a launch definition (and optional saved profile `{id, revision}`) and returns `{session, operation, snapshot}`. `workdir` is `{root_ref, path}` with the path inside the root.
- `run` opens a session and queues its first work in one operation.
- `send{session, input, output?, operation_key}` queues work and returns its receipt. The agent replies in text, so `output` is `bee:Text@1` or absent. A session whose lifecycle is not `active` or `suspended` refuses work.
- `await`, `join`, `get`, `list`, `history`, `cancel`, `close` as described under the client below.
- A snapshot carries lifecycle (`opening`, `active`, `suspended`, `closing`, `closed`), activity (`idle`, `working`, `blocked`, `stalled`), `activity_evidence` for a quiet stall, the thread ref, workspace, driver, definition, the effective profile with its digest and the last result summary.

Refs are qualified strings: `bs:` session, `bw:` work, `bo:` operation, `bj:` join. They are the only addresses. Every mutation requires an explicit `operation_key`; reusing a key with different arguments conflicts. Handles send `expected_incarnation`; a mismatch fails `STALE`.

`list` and reads cover the caller's workspace plus workspaces the host admits. Mutating another workspace needs the exact host grant `bee.sessions.workspace.open`; visibility alone grants no mutation. `bee.sessions.attach` is the grant window-session `attach`, `restore`, `launch_prompt` and `detach` check against the definition. Cancellation commits the authorized request in Threads and then stops the placement with proved exit.

## Application client

`bee.threads.sessions.client:sessions` calls the contracts through their default bindings as the calling process's own actor. It grants nothing; the host admits the caller and the owner authorizes every operation. Each function returns `value, Fault?`; a Fault is `{code, message, retry, operation_key?, ...}` with `retry` one of `never`, `same_key`, `refresh`, `reconcile`. Replies are decoded against closed schemas; a deviation is a Fault.

```lua
local sessions = require("sessions") -- imports: sessions: bee.threads.sessions.client:sessions
local s = sessions.open{definition = "research:worker", operation_key = "open/worker"}
local w = s:send{input = "Check the baseline", operation_key = "send/baseline"}
local a = w:await{timeout_ms = 30000}
local closing = s:close{operation_key = "close/worker"}
local c = sessions.call{definition = "research:quick", input = "Summarize the repository", operation_key = "call/summary"}
```

- `open{definition, profile?, workdir?, workspace?, operation_key}` returns a Session; `call{... input, output?, timeout_ms?, operation_key}` opens one and sends its first work, then awaits it once, returning `{work, observation}`.
- `send`, `cancel{work, reason?, operation_key}` and `close{session, operation_key}` also exist on the handles; cancel and close return an Operation whose `await` reports the stop, or an uncertain evidence branch.
- `await{subject, timeout_ms?}`, `work:await` and `operation:await` wait up to `timeout_ms` (default 30000, at most 60000) and return the observation (`ready`, `pending`, `blocked` or `uncertain`). The timeout bounds observation, never execution.
- `join{works, policy?, quorum?, timeout_ms?, operation_key}` takes 1 to 64 works; `policy` is `all_success` (default), `all_settled`, `first_success` or `quorum`. It returns every child's observation in input order.
- `get(ref)`, `work(ref)`, `list{filter?, cursor?}` (filter fields `lifecycle`, `activity`, `workspace`, `definition`), `session:history{cursor?, limit?}`, `catalog{kind?, definition_ref?, query?, sort?, include_unavailable?, cursor?}`.
- `work:state()` carries `sender`, the owner-set authenticated sender of the work; callers never supply one.

Requests are validated before dispatch (`INVALID`): bounded text and refs, JSON inputs of at most 64 KiB and depth 16.

The catalog marks each definition or profile `ready`, `missing`, `unconfigured`, `incompatible` or `unknown` by measuring its route through the host-selected driver locator; provider login checks observe file existence, and the provider owns authentication. Person-facing catalogs filter the `presentation:start_menu` feature; programmatic routes stay addressable.

## Agents across bees

Every contract operation and catalog `list` accepts optional `node`. Omission
keeps local behavior. The Lua client binds a peer with
`sessions.client{node = "bee-peer"}`; per-call `node` is also available on
options. Returned Session, Work and Operation handles keep their selected bee.
The ten existing MCP `session_*` tools accept the same optional field.

The receiving bee requires the person's allowance for the authenticated Hive
peer in its receiving workspace. Sessions → Allowances grants list only,
message and await, or open new sessions, for a chosen duration or permanently.
Revocation takes effect at receiver authorization. A first refused operation
creates one Needs you question there; background discovery creates no question.
Approvals owns these permissions as central windows, including permanent
consent, expiry and revocation. Sessions keeps no independent grant store.
An agent cannot manage these allowances. Hive membership alone grants no access.

| Scope | Allowed operations |
|---|---|
| List only | `list`, `get`, `history`, catalog `list` |
| Message and await | List operations plus `send`, `await`, `join` |
| Open new sessions | Message operations plus `open`, `run`, `cancel`, `close` |

Sessions groups allowed peers by bee. Opening a peer's agent shows its history
and state. The composer stays read-only under list-only consent. The receiving
workspace's session permissions, current allowance and operation exposure are
checked again when a queued Hive call dispatches.

```lua
local peer = sessions.client{node = "bee-peer"}
local page, fault = peer:list()
if not page then error(tostring(fault)) end
local agent = assert(peer:get(page.items[1].session))
local work = assert(agent:send{input = "Check the baseline", operation_key = "review/123"})
local observation = assert(work:await{timeout_ms = 10000})
```

Use a distinct, persistent operation key for each mutation. A peer agent's
source session is supplied by the host and remains bound to the authenticated
sending bee; request payloads cannot choose another bee. The receiving Threads
transaction commits work together with a canonical inbox request, retaining
source node, source thread and source action. Settlement commits a reply whose
`in_reply_to` names that request record. Await uses the stored node-qualified
WorkRef and can be resumed by a new process. The existing pump's outcome
classification preserves uncertain transport outcomes. A lost mutation reply
is `UNKNOWN_OUTCOME` with `retry = same_key`; resend identical input and key.
`pending` is an observation timeout. Transport deadlines end waiting while the
receiving bee may still commit the mutation. Hive bounds a remote dispatch to
30 seconds; a longer requested observation can therefore have a transport
failure and be observed again on the same bee.

Read `docs/hive_sessions` and the overlay guide section `hive_sessions` for the
application facade, MCP examples and the two-node proof.
